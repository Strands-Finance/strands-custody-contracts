# strands-custody-contracts

Custodial ERC20 token for the Strands platform.

## Overview

`StrandsCustodyToken` is an OpenZeppelin `ERC20Burnable` token with a privileged
custodial burn path gated by `AccessControl`. Users retain the standard ERC20
behavior — they can burn their own balance with `burn`, or allow a third party
to burn on their behalf via `approve` + `burnFrom`. In addition, any address
holding `CUSTODIAN_ROLE` may call `custodyBurn(from, amount)` to destroy tokens
from any holder **without prior allowance**. This is the on-chain hook that lets
Strands keep total supply consistent with an off-chain ledger when claims are
redeemed.

Holder-to-holder transfers are **default-deny**: a holder can only `transfer` /
`transferFrom` to destinations the admin has approved for that specific holder
via `setDestinationAllowed`. Mint and burn paths (`mint`, `burn`, `burnFrom`,
`custodyBurn`) are exempt from this restriction. Batch helpers for managing that
allowlist — including one-transaction subaccount linking — come from
[`StrandsAllowlistBatch`](./src/StrandsAllowlistBatch.sol); see
[Subaccount transfers](#subaccount-transfers).

## Token

| Field | Value |
| --- | --- |
| Name | `Strands Custody Token` |
| Symbol | `SCT` |
| Decimals | Set at deploy time via the `decimals_` constructor argument (e.g. USDC = 6, BTC = 8, ETH = 18) |
| Initial supply | `0` (mint via `MINTER_ROLE`) |

## Roles

| Role | Powers |
| --- | --- |
| `DEFAULT_ADMIN_ROLE` | Grant / revoke any role; manage the per-holder transfer destination allowlist (`setDestinationAllowed` and every [batch helper](#batch-helpers)) |
| `MINTER_ROLE` | Call `mint(to, amount)` |
| `CUSTODIAN_ROLE` | Call `custodyBurn(from, amount)` — bypasses allowance |

The constructor grants `DEFAULT_ADMIN_ROLE` to the `admin` argument. The admin
then grants `MINTER_ROLE` and `CUSTODIAN_ROLE` to whichever addresses (ideally
multisigs / timelocks) should hold them.

## API

```solidity
function mint(address to, uint256 amount) external;          // MINTER_ROLE
function custodyBurn(address from, uint256 amount) external; // CUSTODIAN_ROLE
function setDestinationAllowed(address holder, address destination, bool allowed) external; // DEFAULT_ADMIN_ROLE
function allowedDestination(address holder, address destination) external view returns (bool);

event CustodyBurn(address indexed custodian, address indexed from, uint256 amount);
event DestinationAllowedSet(address indexed holder, address indexed destination, bool allowed);

error TransferDestinationNotAllowed(address holder, address destination);
```

Standard ERC20, ERC20Burnable and AccessControl surfaces are inherited, with
one behavioral change: `transfer` and `transferFrom` revert with
`TransferDestinationNotAllowed` unless `allowedDestination[holder][destination]`
is true (keyed by the token owner, not the spender).

### Batch helpers

Each allowlist entry is one directed edge, so a bidirectional link costs two
writes. [`StrandsAllowlistBatch`](./src/StrandsAllowlistBatch.sol) — inherited by
the token, not deployed separately — collapses those into a single transaction.
All writes are `DEFAULT_ADMIN_ROLE`; the views are open.

```solidity
struct Edge { address holder; address destination; }

function setDestinations(Edge[] calldata edges, bool allowed) external;
function setDestinationsMixed(Edge[] calldata edges, bool[] calldata allowed) external;
function setPairs(Edge[] calldata pairs, bool allowed) external;          // both directions — links a subaccount
function setDestinationsForHolder(address holder, address[] calldata destinations, bool allowed) external;
function setHoldersForDestination(address[] calldata holders, address destination, bool allowed) external;

function areAllowed(Edge[] calldata edges) external view returns (bool[] memory);
function isLinked(address user, address sub) external view returns (bool); // both directions open

error ArrayLengthMismatch(uint256 edgesLength, uint256 flagsLength);
```

Three behaviors worth knowing:

- **Writes are `DEFAULT_ADMIN_ROLE`, with no exceptions.** Every entrypoint
  checks the role before doing anything, so an unprivileged caller is rejected
  with the same `AccessControlUnauthorizedAccount` the single setter throws —
  even when the batch would have written nothing. Holding `MINTER_ROLE` or
  `CUSTODIAN_ROLE` is not a shortcut. The views are open by design, so
  integrations can preflight without privileges.

- **Batching is inherited, not a separate contract.** OZ's `onlyRole` checks
  `msg.sender`, never `tx.origin`, so a separately deployed helper would be the
  caller the token sees and would need `DEFAULT_ADMIN_ROLE` granted to it —
  making it a second token admin. Inherited, the batch entrypoints reach the
  role check by internal jump, so the admin signer remains `msg.sender` and no
  extra privilege exists anywhere.
- **Batch writes skip no-ops.** An edge already at the target value is not
  rewritten and emits nothing, so re-running a manifest is cheap and quiet. The
  single `setDestinationAllowed` deliberately still re-emits.

## Subaccount transfers

A "subaccount" — a smart contract wallet, or any second address a user
controls — is nothing special to the token. Enabling it is one linking
transaction.

**Get tokens to the user by minting, not transferring.** `_mint` reaches
`_update` with `from == address(0)`, so issuance bypasses the allowlist and
needs **zero edges**. Minting to a treasury and transferring out does not:
holders are not exempt from the allowlist *even when they hold a privileged
role*, so that path costs one edge per user, permanently. Redemption
(`burn` / `custodyBurn`) is likewise exempt, so the allowlist only ever has to
describe user ↔ subaccount routes.

```bash
# 1. Deploy — admin receives DEFAULT_ADMIN_ROLE
export ADMIN_ADDRESS=0xAdmin DECIMALS=18 DEPLOYER_PRIVATE_KEY=0x...
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --verify

# 2. Admin grants operating roles
cast send $TOKEN "grantRole(bytes32,address)" $(cast keccak "MINTER_ROLE") $MINTER \
  --rpc-url $RPC_URL --private-key $ADMIN_PK

# 3. Issue straight to the user — no allowlist entry needed
cast send $TOKEN "mint(address,uint256)" $USER 1000ether \
  --rpc-url $RPC_URL --private-key $MINTER_PK

# 4. Route is closed until linked (expect false)
cast call $TOKEN "isLinked(address,address)(bool)" $USER $SCW --rpc-url $RPC_URL

# 5. Link N subaccounts — both directions — in ONE transaction
cast send $TOKEN "setPairs((address,address)[],bool)" \
  "[($USER1,$SCW1),($USER2,$SCW2)]" true \
  --rpc-url $RPC_URL --private-key $ADMIN_PK

# 6. User funds the subaccount
cast send $TOKEN "transfer(address,uint256)" $SCW 100ether \
  --rpc-url $RPC_URL --private-key $USER_PK

# 7. Offboard — same call, allowed=false
cast send $TOKEN "setPairs((address,address)[],bool)" \
  "[($USER1,$SCW1)]" false \
  --rpc-url $RPC_URL --private-key $ADMIN_PK
```

`test/flow/SubaccountLifecycle.t.sol` executes exactly this sequence.

### Integration notes

- **The subaccount is itself a holder.** Linking opens `user ↔ sub` and nothing
  more. Any onward destination is a new edge keyed by the *subaccount*. Route
  through the user's main address (`setDestinationsForHolder` makes that one
  call) or edge count grows quadratically.
- **Zero-value transfers revert**, unlike a plain ERC20. Probe a route with
  `isLinked` / `areAllowed`, never `transfer(dest, 0)`.
- **Self-transfers revert** unless allowlisted, and linking does NOT open a
  self-route. `x -> x` is an ordinary edge that an admin must approve on
  purpose via `setDestinations`; a contract that self-transfers without that
  approval is meant to fail rather than be silently accommodated.
- **Counterfactual CREATE2 wallets can be linked before deployment**, but the
  address derives from `(factory, initCodeHash, salt)`; change any of those and
  the approval points at an address nobody controls. Re-derive before seeding.
- **Account-abstraction bundlers drop failing UserOps at simulation**, often
  with an opaque error. Preflight with `isLinked`. To decode a revert that does
  surface, match selector `0x4eacc49d`
  (`TransferDestinationNotAllowed`) — scanning the raw 4 bytes is more reliable
  than typed decoding, since 4337 and SCW frames wrap reverts.

## Security

`CUSTODIAN_ROLE` is a strong privilege — the holder can destroy any holder's
balance. In production:

- Hold `DEFAULT_ADMIN_ROLE` in a timelock-controlled multisig.
- Hold `CUSTODIAN_ROLE` in a multisig with operational signers only.
- Do not grant `CUSTODIAN_ROLE` to EOAs in production.

The transfer allowlist adds further considerations:

- Transfers are **default-deny** — a holder cannot move tokens at all until the
  admin approves at least one destination for them (self-transfers included).
  Deployment runbooks must seed the allowlist before enabling user flows.
- The admin effectively holds transfer-censorship power over every holder.
- **Never renounce the last `DEFAULT_ADMIN_ROLE` holder.** The role is its own
  role admin, so once the last holder is gone no party can bootstrap a new one.
  The allowlist freezes permanently: existing routes become irrevocable, no new
  route can ever be added, and unapproved balances are stranded. Burn paths keep
  working, so holders can still redeem. Keep at least two admin holders.

## Build & test

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
git clone --recurse-submodules <repo-url>
cd strands-custody-contracts
forge install            # only if you cloned without --recurse-submodules
forge build
forge test -vvv
```

## Deploy

```bash
export ADMIN_ADDRESS=0x...
export DEPLOYER_PRIVATE_KEY=0x...
forge script script/Deploy.s.sol \
  --rpc-url $RPC_URL \
  --broadcast \
  --verify
```

After deployment, the admin grants `MINTER_ROLE` and `CUSTODIAN_ROLE` to the
intended operator addresses with `grantRole`.

## .NET / Nethereum code generation

Pre-extracted artifacts in [`abi/`](./abi):

| File | Format | Use with |
| --- | --- | --- |
| `abi/StrandsCustodyToken.json` | Hardhat-style artifact (object with `_format`, `contractName`, `sourceName`, inline `abi`) | Strands `ContractInterfaceGenerator` and any tool that expects a Hardhat/Truffle artifact |
| `abi/StrandsCustodyToken.abi` | Raw ABI JSON array | Vanilla `Nethereum.Generator.Console` |
| `abi/StrandsCustodyToken.bin` | Creation bytecode hex (no `0x` prefix) | Vanilla `Nethereum.Generator.Console` (deployment support) |

### Strands ContractInterfaceGenerator

Drop `abi/StrandsCustodyToken.json` into the directory the generator scans
(e.g. `Sources/Strands/StrandsCustodyToken/StrandsCustodyToken.json`) and run
the CIG normally. If/when the contract is deployed, add a sibling
`StrandsCustodyToken-deployments.json` of shape `{"<chainId>": "0x<address>"}`
to have the deployment class generated too.

### Plain Nethereum.Generator.Console

```bash
dotnet tool install -g Nethereum.Generator.Console
Nethereum.Generator.Console generate from-abi \
  -abi abi/StrandsCustodyToken.abi \
  -bin abi/StrandsCustodyToken.bin \
  -o   ./StrandsCustody.Contracts \
  -ns  StrandsCustody.Contracts \
  -cn  StrandsCustodyToken
```

### Regenerating after a contract change

```bash
forge build
forge inspect StrandsCustodyToken abi --json > abi/StrandsCustodyToken.abi
forge inspect StrandsCustodyToken bytecode | sed 's/^0x//' > abi/StrandsCustodyToken.bin
python3 - <<'PY'
import json
abi = json.load(open("abi/StrandsCustodyToken.abi"))
json.dump({
    "_format": "hh-sol-artifact-1",
    "contractName": "StrandsCustodyToken",
    "sourceName":   "src/StrandsCustodyToken.sol",
    "abi": abi,
}, open("abi/StrandsCustodyToken.json", "w"), indent=2)
PY
```

## License

MIT
