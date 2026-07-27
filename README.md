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
`custodyBurn`) are exempt from this restriction.

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
| `DEFAULT_ADMIN_ROLE` | Grant / revoke any role; manage the per-holder transfer destination allowlist (`setDestinationAllowed`) |
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
- If `DEFAULT_ADMIN_ROLE` is fully renounced, the allowlist is frozen forever:
  unapproved balances become permanently non-transferable (burn paths keep
  working while the respective roles are held).

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
