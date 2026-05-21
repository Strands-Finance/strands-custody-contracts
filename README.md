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

## Token

| Field | Value |
| --- | --- |
| Name | `Strands Custody Token` |
| Symbol | `SCT` |
| Decimals | `18` |
| Initial supply | `0` (mint via `MINTER_ROLE`) |

## Roles

| Role | Powers |
| --- | --- |
| `DEFAULT_ADMIN_ROLE` | Grant / revoke any role |
| `MINTER_ROLE` | Call `mint(to, amount)` |
| `CUSTODIAN_ROLE` | Call `custodyBurn(from, amount)` — bypasses allowance |

The constructor grants `DEFAULT_ADMIN_ROLE` to the `admin` argument. The admin
then grants `MINTER_ROLE` and `CUSTODIAN_ROLE` to whichever addresses (ideally
multisigs / timelocks) should hold them.

## API

```solidity
function mint(address to, uint256 amount) external;          // MINTER_ROLE
function custodyBurn(address from, uint256 amount) external; // CUSTODIAN_ROLE

event CustodyBurn(address indexed custodian, address indexed from, uint256 amount);
```

Standard ERC20, ERC20Burnable and AccessControl surfaces are inherited unchanged.

## Security

`CUSTODIAN_ROLE` is a strong privilege — the holder can destroy any holder's
balance. In production:

- Hold `DEFAULT_ADMIN_ROLE` in a timelock-controlled multisig.
- Hold `CUSTODIAN_ROLE` in a multisig with operational signers only.
- Do not grant `CUSTODIAN_ROLE` to EOAs in production.

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

## Nethereum code generation (.NET)

Pre-extracted artifacts for [Nethereum.Generator](https://github.com/Nethereum/Nethereum.Generator.Console) live in [`abi/`](./abi):

- `abi/StrandsCustodyToken.abi` — raw ABI JSON array
- `abi/StrandsCustodyToken.bin` — creation bytecode (hex, no `0x` prefix)

Generate the C# service / DTOs:

```bash
dotnet tool install -g Nethereum.Generator.Console
Nethereum.Generator.Console generate from-abi \
  -abi abi/StrandsCustodyToken.abi \
  -bin abi/StrandsCustodyToken.bin \
  -o   ./StrandsCustody.Contracts \
  -ns  StrandsCustody.Contracts \
  -cn  StrandsCustodyToken
```

To regenerate the artifacts after a contract change:

```bash
forge build
forge inspect StrandsCustodyToken abi --json > abi/StrandsCustodyToken.abi
forge inspect StrandsCustodyToken bytecode | sed 's/^0x//' > abi/StrandsCustodyToken.bin
```

## License

MIT
