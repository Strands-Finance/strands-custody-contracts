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

Transfers are ordinary, unrestricted ERC20: any holder may `transfer` /
`transferFrom` to any address, exactly as with a stock token.

## Token

| Field | Value |
| --- | --- |
| Name | Set at deploy time via `name_`, e.g. `Strands Custody USDC (BitGo)` |
| Symbol | Set at deploy time via `symbol_`, e.g. `scUSDC` |
| Decimals | Set at deploy time via `decimals_` (e.g. USDC = 6, BTC = 8, ETH = 18) |
| Initial supply | `0` (mint via `MINTER_ROLE`) |

One token is deployed per (holder wallet, custodian, asset), so the name and
symbol identify **which asset at which custodian** — enough to tell a USDC token
from a WETH one on an explorer without a lookup, and deliberately not enough to
identify the holder. Every holder's USDC-at-BitGo token carries the same label.

All three fields are constructor-only and **immutable**: there is no setter, so a
token deployed with the wrong name can only be redeployed and re-minted into.
The constructor rejects an empty `name_` or `symbol_` for that reason.

## Roles

| Role | Powers |
| --- | --- |
| `DEFAULT_ADMIN_ROLE` | Grant / revoke any role. No power over balances. |
| `MINTER_ROLE` | Call `mint(to, amount)` |
| `CUSTODIAN_ROLE` | The entire burn surface: `custodyBurn(from, amount)` (no allowance needed), plus the inherited `burn` / `burnFrom` |

The constructor grants `DEFAULT_ADMIN_ROLE` to the `admin` argument. The admin
then grants `MINTER_ROLE` and `CUSTODIAN_ROLE` to whichever addresses (ideally
multisigs / timelocks) should hold them.

## API

```solidity
constructor(address admin, uint8 decimals_, string memory name_, string memory symbol_);

function mint(address to, uint256 amount) external;          // MINTER_ROLE
function custodyBurn(address from, uint256 amount) external; // CUSTODIAN_ROLE — no allowance needed
function burn(uint256 amount) public;                        // CUSTODIAN_ROLE (overridden)
function burnFrom(address from, uint256 amount) public;      // CUSTODIAN_ROLE (overridden), spends allowance

event CustodyBurn(address indexed custodian, address indexed from, uint256 amount);
```

Standard ERC20, ERC20Burnable and AccessControl surfaces are inherited, with one
behavioral change:

- `burn` and `burnFrom` are `CUSTODIAN_ROLE`-only and emit `CustodyBurn`. They
  keep their standard selectors, so an integration calling them still compiles
  — it will revert with `AccessControlUnauthorizedAccount` unless the caller is
  a custodian. `burnFrom` still spends the allowance, and the role check runs
  *before* it, so a rejected call leaves the allowance untouched.

`transfer`, `transferFrom` and `approve` are untouched.

## Operating the token

**Get tokens to a holder by minting, not transferring.** Minting to a treasury
and transferring out works, but it costs an extra transfer and puts the treasury
on the reconciler's `Transfer` log for no reason. Redemption is the mirror
image: custodian-driven, and the holder cannot initiate it.

```bash
# 1. Deploy — admin receives DEFAULT_ADMIN_ROLE
export ADMIN_ADDRESS=0xAdmin DECIMALS=6 DEPLOYER_PRIVATE_KEY=0x...
export TOKEN_NAME="Strands Custody USDC (BitGo)" TOKEN_SYMBOL="scUSDC"
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --verify

# 2. Admin grants operating roles
cast send $TOKEN "grantRole(bytes32,address)" $(cast keccak "MINTER_ROLE") $MINTER \
  --rpc-url $RPC_URL --private-key $ADMIN_PK
cast send $TOKEN "grantRole(bytes32,address)" $(cast keccak "CUSTODIAN_ROLE") $CUSTODIAN \
  --rpc-url $RPC_URL --private-key $ADMIN_PK

# 3. Issue straight to the holder
cast send $TOKEN "mint(address,uint256)" $HOLDER 1000ether \
  --rpc-url $RPC_URL --private-key $MINTER_PK

# 4. The holder moves their balance like any ERC20
cast send $TOKEN "transfer(address,uint256)" $DEST 100ether \
  --rpc-url $RPC_URL --private-key $HOLDER_PK

# 5. Redeem — custodian only; the holder cannot burn their own balance
cast send $TOKEN "custodyBurn(address,uint256)" $HOLDER 100ether \
  --rpc-url $RPC_URL --private-key $CUSTODIAN_PK
```

## Security

`CUSTODIAN_ROLE` is custodial: it can destroy any balance, and is the **only**
party who can, so it is a liveness dependency as well as a security one. There
is no self-service exit — if every custodian key is lost, no balance can ever be
redeemed.

`DEFAULT_ADMIN_ROLE` holds no power over balances. Its reach is the role graph:
it can grant itself `CUSTODIAN_ROLE` and then destroy supply, but that grant is
a separate transaction and lands on-chain as `RoleGranted`, so the escalation is
visible rather than standing.

In production:

- Hold `CUSTODIAN_ROLE` in a multisig with operational signers only, and keep at
  least two holders of it.
- Hold `DEFAULT_ADMIN_ROLE` in a timelock-controlled multisig. The timelock is
  what gives holders visibility of a `CUSTODIAN_ROLE` grant before it settles.
- Do not grant `DEFAULT_ADMIN_ROLE` or `CUSTODIAN_ROLE` to EOAs in production.
- **Never renounce the last `DEFAULT_ADMIN_ROLE` holder.** The role is its own
  role admin, so once the last holder is gone no party can bootstrap a new one
  and the role graph freezes permanently — no new minter, no new custodian.
  Balances still move (transfers need no privilege), but if the existing
  custodian keys are also lost, nothing can ever be redeemed again. Keep at
  least two holders of each role.
- Monitor `CustodyBurn`. Every path that destroys supply emits it, so it is the
  complete record of redemption.

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
export DECIMALS=6                                  # optional, defaults to 18
export TOKEN_NAME="Strands Custody USDC (BitGo)"   # optional, defaults to "Strands Custody Token"
export TOKEN_SYMBOL="scUSDC"                       # optional, defaults to "SCT"
forge script script/Deploy.s.sol \
  --rpc-url $RPC_URL \
  --broadcast \
  --verify
```

**Set `TOKEN_NAME` and `TOKEN_SYMBOL`.** They default to `Strands Custody Token` /
`SCT` — the pair every token carried before this contract took them as arguments —
so a deploy never fails or produces a nameless token for want of an environment
variable. But the label is permanent, and taking the default gives you a token
indistinguishable from every other one on an explorer, which is the whole thing
these arguments exist to fix.

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
