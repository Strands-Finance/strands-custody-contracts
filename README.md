# strands-custody-contracts

Custodial ERC20 token for the Strands platform.

## Overview

`StrandsCustodyToken` is an OpenZeppelin `ERC20Burnable` token gated by
`AccessControl`. A balance here is a **claim against an off-chain ledger**, so
destroying supply is `CUSTODIAN_ROLE`-only — and that covers the *entire* burn
surface. The inherited `burn` and `burnFrom` are gated exactly like
`custodyBurn(from, amount)`, which additionally needs no prior allowance. A
holder cannot redeem themselves, and cannot delegate that power to anyone else
via an ERC20 allowance. All three paths emit `CustodyBurn`, so a reconciler can
track every unit of destroyed supply from that one event.

Holder-to-holder transfers are **default-deny**: a holder can only `transfer` /
`transferFrom` to destinations the admin has approved for that specific holder
via `setDestinationAllowed`. Mint and burn paths are exempt from *that*
restriction — but only from that one; their role checks still apply. `setLink`
opens both directions between a pair of addresses at once; see
[Operating the allowlist](#operating-the-allowlist).

The admin can move any holder's balance to any address with `adminTransfer`,
which needs neither an approved destination nor an ERC20 allowance. It cannot
mint or burn — see [Security](#security).

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
| `DEFAULT_ADMIN_ROLE` | Grant / revoke any role; manage the per-holder transfer destination allowlist (`setDestinationAllowed`, `setLink`); **move any holder's balance to any address** via `adminTransfer`, with no approved destination and no allowance |
| `MINTER_ROLE` | Call `mint(to, amount)` |
| `CUSTODIAN_ROLE` | The entire burn surface: `custodyBurn(from, amount)` (no allowance needed), plus the inherited `burn` / `burnFrom` |

The constructor grants `DEFAULT_ADMIN_ROLE` to the `admin` argument. The admin
then grants `MINTER_ROLE` and `CUSTODIAN_ROLE` to whichever addresses (ideally
multisigs / timelocks) should hold them.

## API

```solidity
function mint(address to, uint256 amount) external;          // MINTER_ROLE
function custodyBurn(address from, uint256 amount) external; // CUSTODIAN_ROLE — no allowance needed
function burn(uint256 amount) public;                        // CUSTODIAN_ROLE (overridden)
function burnFrom(address from, uint256 amount) public;      // CUSTODIAN_ROLE (overridden), spends allowance
function setDestinationAllowed(address holder, address destination, bool allowed) external; // DEFAULT_ADMIN_ROLE
function setLink(address holder, address destination, bool allowed) external; // DEFAULT_ADMIN_ROLE — both directions
function adminTransfer(address from, address to, uint256 amount) external;   // DEFAULT_ADMIN_ROLE — no edge, no allowance
function allowedDestination(address holder, address destination) external view returns (bool);

event CustodyBurn(address indexed custodian, address indexed from, uint256 amount);
event DestinationAllowedSet(address indexed holder, address indexed destination, bool allowed);
event AdminTransfer(address indexed admin, address indexed from, address indexed to, uint256 amount);

error TransferDestinationNotAllowed(address holder, address destination);
```

Standard ERC20, ERC20Burnable and AccessControl surfaces are inherited, with three
behavioral changes:

1. `transfer` and `transferFrom` revert with `TransferDestinationNotAllowed`
   unless `allowedDestination[holder][destination]` is true (keyed by the token
   owner, not the spender).
2. `burn` and `burnFrom` are `CUSTODIAN_ROLE`-only and emit `CustodyBurn`. They
   keep their standard selectors, so an integration calling them still compiles
   — it will revert with `AccessControlUnauthorizedAccount` unless the caller is
   a custodian. `burnFrom` still spends the allowance, and the role check runs
   *before* it, so a rejected call leaves the allowance untouched.
3. `adminTransfer` moves a balance without the holder's participation — no
   approved destination, no allowance, no signature from the holder. It is a
   separate entrypoint rather than an exemption on `transfer`, so an admin
   calling `transfer` is still gated like anyone else.

### Linking

Each allowlist entry is one directed edge, so a bidirectional link costs two
writes. `setLink(holder, destination, allowed)` performs exactly those two and
nothing else. Both setters are `DEFAULT_ADMIN_ROLE`; reads are open.

```solidity
function setDestinationAllowed(address holder, address destination, bool allowed) external; // one edge
function setLink(address holder, address destination, bool allowed) external;               // both edges
function allowedDestination(address holder, address destination) external view returns (bool);
```

Three behaviors worth knowing:

- **`setLink` writes exactly two edges.** It is the shape the policy permits and
  it cannot express any other. Anything asymmetric — a self-edge, one leg of a
  link, a shared destination fanned across many holders — is a deliberate
  one-at-a-time decision for `setDestinationAllowed`.
- **Self-linking reverts.** `setLink(x, x, true)` fails with `"self-link"`
  rather than quietly opening a self-route. `x -> x` is an ordinary edge an
  admin must approve on purpose with `setDestinationAllowed`.
- **Writes are `DEFAULT_ADMIN_ROLE`, with no exceptions.** An unprivileged
  caller is rejected with the same `AccessControlUnauthorizedAccount` from
  either setter. Holding `MINTER_ROLE` or `CUSTODIAN_ROLE` is not a shortcut.
  Reads are open by design, so integrations can preflight without privileges.

There is no batch writer: linking N pairs is N transactions. Checking a link is
two `allowedDestination` reads, one per direction.

## Operating the allowlist

Every address is just a holder to the token — it has no notion of who or what
controls one. A pair of addresses is linked or it is not.

**Get tokens to a holder by minting, not transferring.** `_mint` reaches
`_update` with `from == address(0)`, so issuance bypasses the allowlist and
needs **zero edges**. Minting to a treasury and transferring out does not:
holders are not exempt from the allowlist *even when they hold a privileged
role*, so that path costs one edge per holder, permanently. Redemption is
likewise allowlist-exempt (though custodian-driven — the holder cannot initiate
it), so the allowlist only ever has to describe holder-to-holder routes.

The worked example below links two addresses controlled by the same person — a
main address and a smart contract wallet — because that is the motivating case,
but nothing in the contract knows or cares about that relationship.

```bash
# 1. Deploy — admin receives DEFAULT_ADMIN_ROLE
export ADMIN_ADDRESS=0xAdmin DECIMALS=18 DEPLOYER_PRIVATE_KEY=0x...
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --verify

# 2. Admin grants operating roles
cast send $TOKEN "grantRole(bytes32,address)" $(cast keccak "MINTER_ROLE") $MINTER \
  --rpc-url $RPC_URL --private-key $ADMIN_PK

# 3. Issue straight to the holder — no allowlist entry needed
cast send $TOKEN "mint(address,uint256)" $HOLDER 1000ether \
  --rpc-url $RPC_URL --private-key $MINTER_PK

# 4. Route is closed until linked (both expect false)
cast call $TOKEN "allowedDestination(address,address)(bool)" $HOLDER $DEST --rpc-url $RPC_URL
cast call $TOKEN "allowedDestination(address,address)(bool)" $DEST $HOLDER --rpc-url $RPC_URL

# 5. Link the pair — both directions — one call per pair
cast send $TOKEN "setLink(address,address,bool)" $HOLDER $DEST true \
  --rpc-url $RPC_URL --private-key $ADMIN_PK

# 6. Holder sends along the open route
cast send $TOKEN "transfer(address,uint256)" $DEST 100ether \
  --rpc-url $RPC_URL --private-key $HOLDER_PK

# 7. Offboard — same call, allowed=false
cast send $TOKEN "setLink(address,address,bool)" $HOLDER $DEST false \
  --rpc-url $RPC_URL --private-key $ADMIN_PK

# Out-of-band: the admin can move a balance anywhere, linked or not
cast send $TOKEN "adminTransfer(address,address,uint256)" $HOLDER $ANYWHERE 100ether \
  --rpc-url $RPC_URL --private-key $ADMIN_PK
```

`test/flow/SubaccountLifecycle.t.sol` executes exactly this sequence.

### Integration notes

- **Linking is not transitive.** `setLink(a, b)` and `setLink(a, c)` open
  `a ↔ b` and `a ↔ c` and nothing else, so `b -> c` stays closed however the
  three addresses are related off-chain. Traffic between `b` and `c` routes
  through `a`, which is what keeps the edge count linear rather than quadratic.
  `test/flow/SubaccountTransfers.t.sol` pins this shape for the wallet case.
- **Zero-value transfers revert**, unlike a plain ERC20. Probe a route with
  `allowedDestination(from, to)`, never `transfer(dest, 0)` — the allowlist
  blocks the probe too, so it reverts rather than answering.
- **Self-transfers revert** unless allowlisted, and linking does NOT open a
  self-route. `x -> x` is an ordinary edge that an admin must approve on
  purpose via `setDestinationAllowed`; a contract that self-transfers without
  that approval is meant to fail rather than be silently accommodated.
- **Counterfactual CREATE2 wallets can be linked before deployment**, but the
  address derives from `(factory, initCodeHash, salt)`; change any of those and
  the approval points at an address nobody controls. Re-derive before seeding.
- **Account-abstraction bundlers drop failing UserOps at simulation**, often
  with an opaque error. Preflight with `allowedDestination`. To decode a revert
  that does surface, match selector `0x4eacc49d`
  (`TransferDestinationNotAllowed`) — scanning the raw 4 bytes is more reliable
  than typed decoding, since 4337 and SCW frames wrap reverts.

## Security

**Both privileged roles are custodial.** `DEFAULT_ADMIN_ROLE` can take any
holder's balance and send it anywhere via `adminTransfer` — no allowance, no
approved destination, no participation by the holder. `CUSTODIAN_ROLE` can
destroy any balance, and is the **only** party who can, so it is a liveness
dependency as well as a security one. Together the two roles can seize and then
redeem any holder's tokens. Neither role can mint: `adminTransfer` moves supply
between addresses and never changes its total.

Treat `DEFAULT_ADMIN_ROLE` as a custodian in its own right, not merely as an
administrator. In production:

- Hold `DEFAULT_ADMIN_ROLE` in a timelock-controlled multisig. The timelock is
  what gives holders visibility of a seizure before it settles.
- Hold `CUSTODIAN_ROLE` in a multisig with operational signers only.
- Do not grant `DEFAULT_ADMIN_ROLE` or `CUSTODIAN_ROLE` to EOAs in production.
- Keep at least two holders of `CUSTODIAN_ROLE`. There is no self-service exit:
  if every custodian key is lost, no balance can ever be redeemed.
- Monitor `AdminTransfer`. It is the only signal that distinguishes an
  admin-initiated movement from an ordinary one — both emit the same ERC20
  `Transfer`, so a reconciler watching `Transfer` alone cannot tell them apart.

The transfer allowlist adds further considerations:

- Transfers are **default-deny** — a holder cannot move tokens at all until the
  admin approves at least one destination for them (self-transfers included).
  Deployment runbooks must seed the allowlist before enabling user flows.
- The admin effectively holds transfer-censorship power over every holder, and
  with `adminTransfer` can also redirect what it censors.
- **Never renounce the last `DEFAULT_ADMIN_ROLE` holder.** The role is its own
  role admin, so once the last holder is gone no party can bootstrap a new one.
  The allowlist freezes permanently: existing routes become irrevocable, no new
  route can ever be added, and unapproved balances are stranded — `adminTransfer`
  is lost with the role, so it is no help here. The custodian can still redeem —
  that is the only remaining exit, since a holder cannot burn their own balance.
  Lose the last admin *and* the custodian keys and balances are both immobile
  and unredeemable, permanently. Keep at least two holders of each role.
  `test/allowlist/AdminLifecycle.t.sol` pins this behaviour.

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
| `abi/StrandsCustodyToken.json` | Hardhat-style artifact (object with `_format`, `contractName`, `sourceName`, inline `abi` and `bytecode`) | Strands `ContractInterfaceGenerator` and any tool that expects a Hardhat/Truffle artifact |
| `abi/StrandsCustodyToken.abi` | Raw ABI JSON array | Vanilla `Nethereum.Generator.Console` |
| `abi/StrandsCustodyToken.bin` | Creation bytecode hex (no `0x` prefix) | Vanilla `Nethereum.Generator.Console` (deployment support) |

### Strands ContractInterfaceGenerator

Copy `abi/StrandsCustodyToken.json` into the directory the generator scans
(e.g. `Sources/Strands/StrandsCustodyToken/StrandsCustodyToken.json`) and run
the CIG normally. The artifact carries `bytecode` inline, so the copy is the
whole sync — the generator bakes that value into
`StrandsCustodyTokenDeploymentBase.BYTECODE`, and splicing the ABI and the
creation bytecode from separate files is how the two drift apart. If/when the
contract is deployed, add a sibling `StrandsCustodyToken-deployments.json` of
shape `{"<chainId>": "0x<address>"}` to have the deployment class generated too.

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
bytecode = open("abi/StrandsCustodyToken.bin").read().strip()
with open("abi/StrandsCustodyToken.json", "w") as f:
    json.dump({
        "_format": "hh-sol-artifact-1",
        "contractName": "StrandsCustodyToken",
        "sourceName":   "src/StrandsCustodyToken.sol",
        "abi": abi,
        "bytecode": "0x" + bytecode,
    }, f, indent=2)
    f.write("\n")
PY
```

Then copy `abi/StrandsCustodyToken.json` over the consumer's generator source and
re-run the generator — updating one without the other leaves the generated
`BYTECODE` constant deploying an older contract.

## License

MIT
