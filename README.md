# strands-custody-contracts

Custodial ERC20 token for the Strands platform.

## Overview

`StrandsCustodyToken` is an OpenZeppelin `ERC20Burnable` token gated by
`AccessControl`. A balance here is a **claim against an off-chain ledger**, so
destroying supply is privileged. A holder cannot redeem themselves, and cannot
delegate that power to anyone else via an ERC20 allowance.

Two invariants to rely on: **every burn emits `Burned`**, and **every burn is a
`MINTER_ROLE` holder**. One operating role owns supply in both directions:

| Entrypoint | Role | Direction | Supply-checked |
| --- | --- | --- | --- |
| `mint(to, amount)` | `MINTER_ROLE` | up | no |
| `guardMint(to, amount, estimatedSupply)` | `MINTER_ROLE` | up | yes |
| `guardBurn(from, amount, estimatedSupply)` | `MINTER_ROLE` | down | yes |
| `adminBurn(from, amount)` | `MINTER_ROLE` | down | no |
| `burn(amount)` | `MINTER_ROLE` | down | no |
| `burnFrom(from, amount)` | `MINTER_ROLE` | down | no |

The guarded pair is what the backend sends. Both take the caller's
`totalSupply()` reading and revert with `SupplyMismatch` unless the chain still
agrees, so a stale read cannot move supply in either direction. `adminBurn` is
the unguarded operator escape hatch, and `burn` / `burnFrom` are OZ's inherited
pair, gated to the same role rather than left silently reachable by holders. All
four burn paths emit `Burned`, so a reconciler tracks every unit of destroyed
supply from that one event.

The practical consequence: **`revokeRole(MINTER_ROLE, ...)` is the single lever
that stops minting AND burning.** There is no burn-only revoke. That is the
trade taken when `CUSTODIAN_ROLE` was removed — one operating key instead of
two, matching OpenZeppelin's model of narrow named roles for operations and
`DEFAULT_ADMIN_ROLE` for governance alone.

## Transfers are default-deny

Transfers are **not** ordinary ERC20. `transfer` and `transferFrom` are gated on
a **destination allowlist**, and every address starts closed:

| Member | Role | Purpose |
| --- | --- | --- |
| `allowedDestination(destination)` | anyone | Whether `destination` may receive |
| `setDestinationAllowed(destination, allowed)` | `DEFAULT_ADMIN_ROLE` | Open or close one destination |
| `DestinationAllowedSet(destination, allowed)` | — | Emitted on every write, including a no-op one |
| `TransferDestinationNotAllowed(destination)` | — | The refusal |

The list is keyed by **destination alone**. It is a set of permitted sinks, not
a graph of permitted routes: allowlisting `bob` lets every holder reach `bob`,
and lets `bob` reach nothing. `transferFrom` checks only `to` — never `from`,
never `msg.sender` — so the ERC20 allowance remains the whole story of *who may
act*, and the allowlist is the whole story of *where value may land*.

**A freshly deployed token cannot transfer anywhere.** That is the intended
posture, not an initialisation gap. Minting still works, so the deploy leaves a
usable token; the admin opens destinations afterwards, one call each.

Issuance and redemption are **exempt**. The guard lives in the `transfer` /
`transferFrom` overrides rather than in `_update`, so `_mint` and `_burn` do not
route through it — a balance can always be minted to, and redeemed from, an
address that appears nowhere in the list. A stranded balance is therefore still
redeemable. The cost of that placement: any future function that moves a balance
must go through `transfer` / `transferFrom` or re-state the guard, because OZ's
`_transfer` is not virtual and inherits nothing.

Two consequences worth planning around:

- **The guard runs first.** A refused call reports
  `TransferDestinationNotAllowed` even when the amount also exceeds the balance,
  and even when `to` is the zero address. On `transferFrom` it runs before
  `_spendAllowance`, so a refused call never reaches the spend at all.
- **Writer liveness is transfer liveness.** If `DEFAULT_ADMIN_ROLE` loses its
  last holder the list freezes at whatever it held in that block. Routes already
  open stay open forever; no new one can ever be added. Redemption survives that
  — it consults no list — but mobility does not.

The admin's power here is over **mobility, not value**: closing every
destination strands a balance where it is and cannot move it anywhere, least of
all to the admin. There is no `adminTransfer` escape hatch, and adding one would
undo that property.

## Deployment is two transactions

The constructor takes only the token's own metadata and grants
`DEFAULT_ADMIN_ROLE` to **the deployer**. Both roles are seated by a separate
`initialize(admin, minter)`, which is `onlyRole(DEFAULT_ADMIN_ROLE)` *and* runs
exactly once.

Both guards are load-bearing. The role check is what makes `initialize`
un-front-runnable — a CREATE deploy is visible the moment it lands, and with
only a one-shot guard the first stranger to call would own the token's mint and
burn authority. The one-shot guard is what stops an admin silently re-seating a
different minter later under a call named "initialize".

Between the two transactions the token is **inert** (nobody holds `MINTER_ROLE`,
so every privileged entrypoint reverts) and **recoverable** (the deployer still
holds admin and can finish the deploy). `initialize` revokes the deployer's own
admin unless it *is* the admin, so the role graph afterwards is exactly what the
arguments say.

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

Two roles, following OpenZeppelin's own division: `DEFAULT_ADMIN_ROLE` is
**governance** and `MINTER_ROLE` is the single **operating** capability.

| Role | Powers |
| --- | --- |
| `DEFAULT_ADMIN_ROLE` | Grant / revoke any role, and call `initialize` once. **No power over balances.** |
| `MINTER_ROLE` | Everything that moves supply: `mint`, `guardMint`, `guardBurn`, `adminBurn`, `burn`, `burnFrom` |

The constructor grants `DEFAULT_ADMIN_ROLE` to the deployer; `initialize` then
seats both roles at whichever addresses (ideally multisigs / timelocks) should
hold them, and hands admin on.

`MINTER_ROLE` reaches every burn path as well as every mint path — the name is
narrower than the capability. It is deliberate: `AccessControl` warns that
`DEFAULT_ADMIN_ROLE` is its own admin and should be secured accordingly, so
folding an operational burn onto it would force the governance key to stay hot.
Keeping burning on the operating role is what lets the admin key stay cold and
keeps every escalation visible as a `RoleGranted`.

## API

```solidity
constructor(uint8 decimals_, string memory name_, string memory symbol_);  // admin -> msg.sender

function initialize(address admin, address minter) external; // DEFAULT_ADMIN_ROLE, once

function mint(address to, uint256 amount) external;          // MINTER_ROLE
function guardMint(address to, uint256 amount, uint256 estimatedSupply) external;   // MINTER_ROLE
function guardBurn(address from, uint256 amount, uint256 estimatedSupply) external; // MINTER_ROLE
function adminBurn(address from, uint256 amount) external;   // MINTER_ROLE — no allowance needed
function burn(uint256 amount) public;                        // MINTER_ROLE (overridden)
function burnFrom(address from, uint256 amount) public;      // MINTER_ROLE (overridden), spends allowance

event Burned(address indexed burnedBy, address indexed from, uint256 amount);
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

Standard ERC20, ERC20Burnable and AccessControl surfaces are inherited, with two
behavioral changes:

- `burn` and `burnFrom` are `MINTER_ROLE`-only and emit `Burned`. They keep
  their standard selectors, so an integration calling them still compiles — it
  will revert with `AccessControlUnauthorizedAccount` unless the caller holds
  `MINTER_ROLE`. `burnFrom` still spends the allowance, and the role check runs
  *before* it, so a rejected call leaves the allowance untouched.
- `transfer` and `transferFrom` refuse any destination the admin has not opened,
  reverting with `TransferDestinationNotAllowed`. Same selectors, same
  signatures — an integration compiles unchanged and fails at runtime until the
  destination is allowlisted.

`approve` is untouched: an allowance may be granted to anyone, and says nothing
about whether a transfer using it will land.

## Operating the token

**Get tokens to a holder by minting, not transferring.** Minting to a treasury
and transferring out works, but it costs an extra transfer and puts the treasury
on the reconciler's `Transfer` log for no reason. Redemption is the mirror
image: minter-driven, and the holder cannot initiate it.

```bash
# 1. Deploy + initialize — the script does both in one broadcast, because a token left
#    uninitialized is inert and only the deployer key can finish it.
export ADMIN_ADDRESS=0xAdmin DECIMALS=6 DEPLOYER_PRIVATE_KEY=0x...
export TOKEN_NAME="Strands Custody USDC (BitGo)" TOKEN_SYMBOL="scUSDC"
export MINTER_ADDRESS=0xMinter                                 # defaults to $ADMIN_ADDRESS
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --verify

# 2. ...or, deploying by hand, seat the roles yourself. Run this from the DEPLOYER key —
#    it is the only address holding DEFAULT_ADMIN_ROLE until this call hands it over.
cast send $TOKEN "initialize(address,address)" $ADMIN $MINTER \
  --rpc-url $RPC_URL --private-key $DEPLOYER_PRIVATE_KEY

# 3. Issue straight to the holder
cast send $TOKEN "mint(address,uint256)" $HOLDER 1000ether \
  --rpc-url $RPC_URL --private-key $MINTER_PK

# 4. Open the destination. Until this lands, step 5 reverts with
#    TransferDestinationNotAllowed — the list starts empty and the deploy seeds nothing.
cast send $TOKEN "setDestinationAllowed(address,bool)" $DEST true \
  --rpc-url $RPC_URL --private-key $ADMIN_PK

# 5. Now the holder can move their balance
cast send $TOKEN "transfer(address,uint256)" $DEST 100ether \
  --rpc-url $RPC_URL --private-key $HOLDER_PK

# 6. Redeem — MINTER_ROLE only; the holder cannot burn their own balance. Prefer
#    guardBurn, which refuses the burn unless the chain's supply still matches the
#    reading the amount was decided against; adminBurn is the unguarded fallback.
cast send $TOKEN "guardBurn(address,uint256,uint256)" $HOLDER 100ether $SUPPLY_YOU_READ \
  --rpc-url $RPC_URL --private-key $MINTER_PK
cast send $TOKEN "adminBurn(address,uint256)" $HOLDER 100ether \
  --rpc-url $RPC_URL --private-key $MINTER_PK
```

## Security

`MINTER_ROLE` is a **supply-destruction role as well as an issuance one**. A
threat model that treats it as issuance-only is wrong: it reaches `adminBurn`,
`guardBurn`, `burn` and `burnFrom`, so a compromised minter key can destroy any
balance as easily as it can inflate one. The upside of that concentration is a
single, unambiguous kill switch — `revokeRole(MINTER_ROLE, ...)` stops both
directions in one transaction. The downside is that there is no way to stop
burning while minting continues, or the reverse.

There is no self-service exit. If every `MINTER_ROLE` key is lost, no balance can
ever be redeemed.

`DEFAULT_ADMIN_ROLE` holds no power over balances. Its reach is the role graph:
it can grant itself `MINTER_ROLE` and then move supply, but that grant is a
separate transaction and lands on-chain as `RoleGranted`, so the escalation is
visible rather than standing. This is the reason the burn surface was NOT folded
onto `DEFAULT_ADMIN_ROLE` when `CUSTODIAN_ROLE` was removed — doing so would
have deleted that announcement and forced the governance key to stay hot.

Between deploy and `initialize`, `DEFAULT_ADMIN_ROLE` sits on the **deployer
key**. Keep that window short and the key controlled: it is the one address that
can decide who the minter will be.

In production:

- Hold `MINTER_ROLE` in a multisig with operational signers only, and keep at
  least two holders of it. It is the only key that can redeem.
- Hold `DEFAULT_ADMIN_ROLE` in a timelock-controlled multisig, separate from the
  minter. The timelock is what gives holders visibility of a `MINTER_ROLE` grant
  before it settles. OpenZeppelin's `AccessControl` warns that this role is its
  own admin and needs extra precautions; treat it as governance only.
- Do not grant `DEFAULT_ADMIN_ROLE` or `MINTER_ROLE` to EOAs in production.
- **Never renounce the last `DEFAULT_ADMIN_ROLE` holder.** The role is its own
  role admin, so once the last holder is gone no party can bootstrap a new one
  and the role graph freezes permanently — no new minter, ever. **The transfer
  allowlist freezes with it:** balances move only along routes opened before
  that block, and no destination can ever be added again. If the list was empty,
  no transfer will ever succeed. And if the existing minter keys are also lost,
  nothing can ever be redeemed either. Keep at least two holders of each role.
- **Open destinations deliberately, and audit `DestinationAllowedSet`.** It is
  emitted on every write including a no-op, so the log is the complete record of
  what the admin asserted — there is no on-chain enumeration of the list, so
  that log is the only way to reconstruct it.
- Monitor `Burned`. All four paths that destroy supply emit it, so it is the
  complete record of redemption, and `burnedBy` always names a `MINTER_ROLE`
  holder.
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
`initialize(admin, minter)` — until it does, the token is inert.

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
