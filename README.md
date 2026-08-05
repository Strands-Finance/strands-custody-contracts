# strands-custody-contracts

Custodial ERC20 token for the Strands platform.

## Overview

`StrandsCustodyToken` is an OpenZeppelin `ERC20Burnable` token gated by
`AccessControl`. A balance here is a **claim against an off-chain ledger**, so
destroying supply is privileged. A holder cannot redeem themselves, and cannot
delegate that power to anyone else via an ERC20 allowance.

The invariant to rely on is **every burn emits `CustodyBurn`** — not that every
burn is a custodian. The burn surface is split across two roles:

| Entrypoint | Role | Supply-checked |
| --- | --- | --- |
| `custodyBurn(from, amount)` | `CUSTODIAN_ROLE` | no |
| `burn(amount)` | `CUSTODIAN_ROLE` | no |
| `burnFrom(from, amount)` | `CUSTODIAN_ROLE` | no |
| `guardBurn(from, amount, estimatedSupply)` | **`MINTER_ROLE`** | yes |

`guardBurn` is the deliberate exception. It is the backend's burn path, and it
is paired with `guardMint` rather than with the custodial entrypoints: both
take the caller's `totalSupply()` reading and revert with `SupplyMismatch`
unless the chain still agrees, so a stale read cannot move supply in either
direction. All four paths emit `CustodyBurn`, so a reconciler tracks every unit
of destroyed supply from that one event; its `burnedBy` field reports a minter
on the guarded path and a custodian on the other three.

The practical consequence: **revoking `CUSTODIAN_ROLE` does not stop every
burn.** Closing the whole surface takes revoking `MINTER_ROLE` too.

Transfers are ordinary, unrestricted ERC20: any holder may `transfer` /
`transferFrom` to any address, exactly as with a stock token.

## Deployment is two transactions

The constructor takes only the token's own metadata and grants
`DEFAULT_ADMIN_ROLE` to **the deployer**. Operating roles are seated by a
separate `initialize(admin, minter, custodian)`, which is
`onlyRole(DEFAULT_ADMIN_ROLE)` *and* runs exactly once.

Both guards are load-bearing. The role check is what makes `initialize`
un-front-runnable — a CREATE deploy is visible the moment it lands, and with
only a one-shot guard the first stranger to call would own the token's mint and
burn authority. The one-shot guard is what stops an admin silently re-seating a
different minter later under a call named "initialize".

Between the two transactions the token is **inert** (nobody holds `MINTER_ROLE`
or `CUSTODIAN_ROLE`, so every privileged entrypoint reverts) and **recoverable**
(the deployer still holds admin and can finish the deploy). `initialize` revokes
the deployer's own admin unless it *is* the admin, so the role graph afterwards
is exactly what the arguments say.

`initialize` is **not idempotent** — a second call reverts with
`InvalidInitialization()`. A caller with a retry path must read `hasRole` first
rather than re-calling.

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
| `DEFAULT_ADMIN_ROLE` | Grant / revoke any role, and call `initialize` once. No power over balances. |
| `MINTER_ROLE` | `mint(to, amount)`, `guardMint(to, amount, estimatedSupply)`, `guardBurn(from, amount, estimatedSupply)` |
| `CUSTODIAN_ROLE` | The unguarded burn surface: `custodyBurn(from, amount)` (no allowance needed), plus the inherited `burn` / `burnFrom` |

The constructor grants `DEFAULT_ADMIN_ROLE` to the deployer; `initialize` then
seats all three roles at whichever addresses (ideally multisigs / timelocks)
should hold them, and hands admin on.

`MINTER_ROLE` reaches a burn path. That is the one place the role names are not
self-describing, and it is deliberate — see the `guardBurn` note above.

## API

```solidity
constructor(uint8 decimals_, string memory name_, string memory symbol_);       // admin -> msg.sender

function initialize(address admin, address minter, address custodian) external; // DEFAULT_ADMIN_ROLE, once

function mint(address to, uint256 amount) external;          // MINTER_ROLE
function guardMint(address to, uint256 amount, uint256 estimatedSupply) external;   // MINTER_ROLE
function guardBurn(address from, uint256 amount, uint256 estimatedSupply) external; // MINTER_ROLE
function custodyBurn(address from, uint256 amount) external; // CUSTODIAN_ROLE — no allowance needed
function burn(uint256 amount) public;                        // CUSTODIAN_ROLE (overridden)
function burnFrom(address from, uint256 amount) public;      // CUSTODIAN_ROLE (overridden), spends allowance

event CustodyBurn(address indexed burnedBy, address indexed from, uint256 amount);
event Initialized(uint64 version);

error SupplyMismatch(uint256 actualSupply, uint256 estimatedSupply);
```

### `guardMint` — mint against a supply you have already read

`mint` issues whatever it is told to. `guardMint` issues it only if
`totalSupply()` still equals `estimatedSupply`, reverting with
`SupplyMismatch(actualSupply, estimatedSupply)` otherwise.

That matters to any caller that computes the amount *from* the supply. The
Strands backend mints the **delta** between a custodian's balance and what is
already circulating, so a supply read that was stale — a lagging RPC replica, a
race with a concurrent burn or mint, a repeated attempt after a crash — makes
the delta wrong by exactly the same margin, and nothing the caller can observe
would say so. Passing the read back in makes that assumption enforceable rather
than assumed.

`estimatedSupply` is the **pre-mint** supply, in raw base units — `decimals()`
is display metadata and never enters the comparison. A fresh deployment
therefore passes `0`, and `0` is an ordinary value rather than a "skip the
check" sentinel: it is honoured only when the supply really is zero. The revert
carries `actualSupply`, so the corrected estimate is in the revert data and a
caller can re-read and retry.

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
# 1. Deploy + initialize — the script does both in one broadcast, because a token left
#    uninitialized is inert and only the deployer key can finish it.
export ADMIN_ADDRESS=0xAdmin DECIMALS=6 DEPLOYER_PRIVATE_KEY=0x...
export TOKEN_NAME="Strands Custody USDC (BitGo)" TOKEN_SYMBOL="scUSDC"
export MINTER_ADDRESS=0xMinter CUSTODIAN_ADDRESS=0xCustodian   # both default to $ADMIN_ADDRESS
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --verify

# 2. ...or, deploying by hand, seat the roles yourself. Run this from the DEPLOYER key —
#    it is the only address holding DEFAULT_ADMIN_ROLE until this call hands it over.
cast send $TOKEN "initialize(address,address,address)" $ADMIN $MINTER $CUSTODIAN \
  --rpc-url $RPC_URL --private-key $DEPLOYER_PRIVATE_KEY

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

`CUSTODIAN_ROLE` is custodial: it can destroy any balance. `MINTER_ROLE` can
too, through `guardBurn` — so **both** are supply-destruction roles, and a
threat model that treats `MINTER_ROLE` as issuance-only is wrong. Splitting the
two across separate keys therefore hands the minter side a redemption path;
today the backend's single mint-authority EOA holds both.

There is no self-service exit. If every custodian *and* minter key is lost, no
balance can ever be redeemed.

`DEFAULT_ADMIN_ROLE` holds no power over balances. Its reach is the role graph:
it can grant itself `MINTER_ROLE` or `CUSTODIAN_ROLE` and then destroy supply,
but that grant is a separate transaction and lands on-chain as `RoleGranted`, so
the escalation is visible rather than standing.

Between deploy and `initialize`, `DEFAULT_ADMIN_ROLE` sits on the **deployer
key**. Keep that window short and the key controlled: it is the one address that
can decide who the minter and custodian will be.

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
  custodian and minter keys are also lost, nothing can ever be redeemed again.
  Keep at least two holders of each role.
- Monitor `CustodyBurn`. All four paths that destroy supply emit it, so it is
  the complete record of redemption. Do not filter on `burnedBy` being a
  custodian — `guardBurn` reports the minter.
- **Initialize in the same operation as the deploy.** An uninitialized token is
  harmless but unfinished, and the only key that can complete it is the one that
  deployed it.

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
export MINTER_ADDRESS=0x...                        # optional, defaults to $ADMIN_ADDRESS
export CUSTODIAN_ADDRESS=0x...                     # optional, defaults to $ADMIN_ADDRESS
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

The script deploys and initializes in one broadcast, so the token is live when
it returns. Deploying by hand instead means the deployer key must follow up with
`initialize(admin, minter, custodian)` — until it does, the token is inert.

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
