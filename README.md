# strands-custody-contracts

Custodial ERC20 token for the Strands platform.

## Overview

`StrandsDACAP` is an OpenZeppelin `ERC20Burnable` token gated by
`AccessControl`, deployed behind a **beacon proxy** (see
[Proxy and upgradeability](#proxy-and-upgradeability)). A balance here is a **claim against an off-chain ledger**, so
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

## Proxy and upgradeability

A token is never the `StrandsDACAP` contract itself. It is an OpenZeppelin
`BeaconProxy`, and that proxy's address is the token's address: the one that
holds balances, roles, metadata and the allowlist, and the one an integration
registers.

```
holder / integration ──► BeaconProxy (one per token: all the state)
                              │  "which code?"          delegatecall
                              ├──► UpgradeableBeacon ──► StrandsDACAP implementation
                              │    (one per chain)       (one per chain: code only)
```

One implementation and one beacon serve every token on a chain. Pointing the
beacon at a new implementation (`beacon.upgradeTo(newImplementation)`) changes
the logic of **every token at once**, at the same addresses, with every balance
intact — which is the point: a change to the token no longer means a burn and a
re-mint.

- **Upgrade authority is the beacon's owner, and only that.** It is not a role
  on the token: `DEFAULT_ADMIN_ROLE` cannot upgrade, and the token has no
  upgrade function. See [Security](#security) for what that owner can do.
  The beacon is to be owned by Derive; handing it over is
  `script/TransferBeaconOwnership.s.sol` (see
  [Hand the beacon to Derive](#hand-the-beacon-to-derive)).
- **The implementation is locked.** Its constructor disables initializers, so it
  can never be made to look like a token.
- **A new implementation may only append to `DACAPStorage`.** The token's own
  state lives in one ERC-7201 namespaced struct; reordering or removing a field
  silently reinterprets every token's storage, and `forge` will not catch it.
- Nothing in this repo performs an upgrade. `test/token/Proxy.t.sol` proves one
  keeps state.

## Deployment is one transaction

The proxy's deploy runs `initializeToken(decimals, name, symbol)` in the same
transaction. It fixes the token's metadata and grants **the deployer** both
`DEFAULT_ADMIN_ROLE` and `MINTER_ROLE` — what a constructor would do, had the
token no proxy in front of it. It is the token's only initializer, and the token
is live the moment the deploy returns: there is no second transaction, so there
is no window between "deployed" and "usable" for anyone to step into.

```
Deployer ─▶ new BeaconProxy(beacon, initializeToken(decimals, name, symbol))
              └─ delegatecall initializeToken      [Initializable version 0 → 1]
                   metadata fixed · admin = Deployer · minter = Deployer
```

**Always pass `initializeToken` as the proxy constructor's `data`.** A proxy
created with empty `data` belongs to whoever calls `initializeToken` first.

**Deploy straight from the key that should hold the roles.** The roles go to the
proxy's immediate creator, so a factory, a CREATE2 deployer or a batching
contract that creates the proxy receives both roles instead.

`initializeToken` cannot run again on a deployed token, for anyone — it reverts
`InvalidInitialization()`. Moving a role elsewhere afterwards (a cold admin, a
minter multisig) is ordinary `AccessControl`, sent by the deployer: `grantRole`
to the new holder, then `renounceRole` its own.

An initializer added by a later implementation is `reinitializer(2)`, and must
also be `onlyRole(DEFAULT_ADMIN_ROLE)`: a beacon upgrade runs no initializer, and
`reinitializer` alone does not check who calls it.

## Token

| Field | Value |
| --- | --- |
| Name | Set at deploy time via `name_`, e.g. `Strands.DACAP.BitGo.USDC` |
| Symbol | Set at deploy time via `symbol_`, the SAME string as the name, e.g. `Strands.DACAP.BitGo.USDC` |
| Decimals | Set at deploy time via `decimals_` (e.g. USDC = 6, BTC = 8, ETH = 18) |
| Initial supply | `0` (mint via `MINTER_ROLE`) |

Both follow `Strands.DACAP.<custodian>.<ASSET>`. One token is deployed per
(holder wallet, custodian, asset), so the label identifies **which asset at which
custodian** — enough to tell a USDC token from a WETH one on an explorer without a
lookup, and deliberately not enough to identify the holder. Every holder's
USDC-at-BitGo token carries the same label.

The symbol is not abbreviated to a short ticker. These tokens are claims against
an off-chain ledger rather than instruments anyone trades, so there is no venue
where a terse symbol earns its ambiguity — and a wallet rendering
`Strands.DACAP.BitGo.USDC` beside a balance says exactly what the balance is.

All three fields are set by `initializeToken` during the deploy and have **no
setter**, so a token deployed with the wrong name can only be redeployed and
re-minted into. `initializeToken` rejects an empty `name_` or `symbol_` for that
reason.

## Roles

Two roles, following OpenZeppelin's own division: `DEFAULT_ADMIN_ROLE` is
**governance** and `MINTER_ROLE` is the single **operating** capability.

| Role | Powers |
| --- | --- |
| `DEFAULT_ADMIN_ROLE` | Grant / revoke any role, and open transfer destinations. **No power over balances.** |
| `MINTER_ROLE` | Everything that moves supply: `mint`, `guardMint`, `guardBurn`, `adminBurn`, `burn`, `burnFrom` |

The deploy grants both roles to the deployer. Where they should end up elsewhere
(ideally multisigs / timelocks), the deployer grants them on and renounces its
own.

`MINTER_ROLE` reaches every burn path as well as every mint path — the name is
narrower than the capability. It is deliberate: `AccessControl` warns that
`DEFAULT_ADMIN_ROLE` is its own admin and should be secured accordingly, so
folding an operational burn onto it would force the governance key to stay hot.
Keeping burning on the operating role is what lets the admin key stay cold and
keeps every escalation visible as a `RoleGranted`.

## API

```solidity
// Passed as the BeaconProxy constructor's data, so it runs in the deploy.  admin, minter -> msg.sender
function initializeToken(uint8 decimals_, string calldata name_, string calldata symbol_) external;

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
# 0. Once per chain: the implementation and its beacon. See "Deploy".
#
# 1. Deploy. One transaction: the deployer comes out as admin AND minter, so the token
#    is live when the script returns.
export BEACON_ADDRESS=0xBeacon DECIMALS=6 DEPLOYER_PRIVATE_KEY=0x...
export TOKEN_NAME="Strands.DACAP.BitGo.USDC" TOKEN_SYMBOL="Strands.DACAP.BitGo.USDC"
# No --verify. Source publication is deliberately not performed — see "Source verification" below.
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
export TOKEN=0x...   # the "StrandsDACAP (BeaconProxy) deployed at" address the script printed
# MINTER_PK / ADMIN_PK below are the minter's and admin's keys: both $DEPLOYER_PRIVATE_KEY unless step 2 moved a role.

# 2. Optional: move a role off the deployer key — grant it on, then renounce your own.
#    Run from the DEPLOYER key. Skip it to keep one key as admin and minter (the backend's shape).
DEPLOYER=$(cast wallet address --private-key $DEPLOYER_PRIVATE_KEY)
export MINTER=0xMinter                                         # the new MINTER_ROLE holder
cast send $TOKEN "grantRole(bytes32,address)" $(cast keccak MINTER_ROLE) $MINTER \
  --rpc-url $RPC_URL --private-key $DEPLOYER_PRIVATE_KEY
cast send $TOKEN "renounceRole(bytes32,address)" $(cast keccak MINTER_ROLE) $DEPLOYER \
  --rpc-url $RPC_URL --private-key $DEPLOYER_PRIVATE_KEY

# Every amount below is in BASE UNITS of the token's decimals. Convert with `cast parse-units`:
# `$(cast parse-units 1000 $DECIMALS)` is 1,000 tokens. `1000ether` is 10^21 base units — on a
# 6-decimal token that is 10^15 tokens, not 1,000.
#
# 3. Issue straight to the holder
cast send $TOKEN "mint(address,uint256)" $HOLDER $(cast parse-units 1000 $DECIMALS) \
  --rpc-url $RPC_URL --private-key $MINTER_PK

# 4. Open the destination. Until this lands, step 5 reverts with
#    TransferDestinationNotAllowed — the list starts empty and the deploy seeds nothing.
cast send $TOKEN "setDestinationAllowed(address,bool)" $DEST true \
  --rpc-url $RPC_URL --private-key $ADMIN_PK

# 5. Now the holder can move their balance
cast send $TOKEN "transfer(address,uint256)" $DEST $(cast parse-units 100 $DECIMALS) \
  --rpc-url $RPC_URL --private-key $HOLDER_PK

# 6. Redeem — MINTER_ROLE only; the holder cannot burn their own balance. Use guardBurn,
#    which refuses the burn unless the chain's supply still matches the reading the amount
#    was decided against ($SUPPLY_YOU_READ is `totalSupply()`, in base units).
cast send $TOKEN "guardBurn(address,uint256,uint256)" $HOLDER $(cast parse-units 100 $DECIMALS) $SUPPLY_YOU_READ \
  --rpc-url $RPC_URL --private-key $MINTER_PK
#    ...OR, INSTEAD of guardBurn (never both — that burns twice), the unguarded fallback:
# cast send $TOKEN "adminBurn(address,uint256)" $HOLDER $(cast parse-units 100 $DECIMALS) \
#   --rpc-url $RPC_URL --private-key $MINTER_PK
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

The deploy seats both roles on the **deployer key**, with no window in between
for anyone else to claim them. Until it hands a role on, that key alone is the
token's governance and its operations, so it must be controlled accordingly.

**The beacon's owner sits above all of this.** It can point every token at new
code, and new code can do anything: mint without `MINTER_ROLE`, ignore the
allowlist, burn without emitting `Burned`. Every guarantee in this document
holds only for as long as the beacon names an implementation that keeps it.
It is the most powerful key in the system.

**The beacon is to be owned by Derive.** Cameron decided this on 2026-10-05,
accepting that Derive can then replace the code of every token on the chain at
once. Derive also receives each token's `DEFAULT_ADMIN_ROLE` during enrolment,
so with both it needs nobody else to mint, burn or change the code. Strands
keeps `MINTER_ROLE` and, today, its own `DEFAULT_ADMIN_ROLE` seat: enrolment
grants Derive the role without Strands renouncing its own. While Strands holds
that seat, Derive revoking Strands' minter does not stick, because Strands can
grant it back. An upgrade by Derive changes
the code under the backend with no change on the Strands side, so an
implementation the backend's bindings were not generated from can break or alter
every call it makes.

In production:

- Monitor the beacon's `Upgraded` and `OwnershipTransferred` events. They are
  the only signal that the code behind every token, or who can change it, has
  moved.
- Recommend that Derive hold the beacon in a timelock-controlled multisig rather
  than an EOA. Once the beacon is theirs, that choice is theirs.

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
- **Deploy from the key that should hold the roles, directly.** The deploy
  seats its immediate creator; deploying through a factory or a CREATE2 deployer
  would hand that contract both roles.

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

**Once per chain** — the implementation and the beacon every token points at:

```bash
export DEPLOYER_PRIVATE_KEY=0x...
export BEACON_OWNER=0x...                          # required; the only address that can upgrade
forge script script/DeployBeacon.s.sol \
  --rpc-url $RPC_URL \
  --broadcast
```

The `UpgradeableBeacon` address it prints is `BEACON_ADDRESS` below, and what the
backend is configured with as `DERIVE_CUSTODY_DACAP_BEACON`.

**Per token** — a `BeaconProxy` in front of it:

```bash
export BEACON_ADDRESS=0x...                        # from DeployBeacon above
export DEPLOYER_PRIVATE_KEY=0x...                  # becomes the token's admin AND minter
export DECIMALS=6                                  # REQUIRED: the asset's native decimals (USDC 6, BTC 8, ETH 18)
export TOKEN_NAME="Strands.DACAP.BitGo.USDC"       # optional, defaults to "Strands.DACAP"
export TOKEN_SYMBOL="Strands.DACAP.BitGo.USDC"     # optional, defaults to "Strands.DACAP"
forge script script/Deploy.s.sol \
  --rpc-url $RPC_URL \
  --broadcast
```

**Set `TOKEN_NAME` and `TOKEN_SYMBOL`, and set them to the same string.** Both
follow `Strands.DACAP.<custodian>.<ASSET>`; the symbol is not abbreviated because
these labels identify a custodial claim rather than a tradeable ticker. They both
default to `Strands.DACAP` so a deploy never fails or produces a nameless token for
want of an environment variable. But the label is permanent, and taking the default
gives you a token indistinguishable from every other one on an explorer, which is
the whole thing these arguments exist to fix.

The deploy is the whole of initialization, so the token is live when the script
returns, with the deployer key as both admin and minter. Moving either role
elsewhere is a later `grantRole` then `renounceRole` from that key (see
[Operating the token](#operating-the-token)).

### Hand the beacon to Derive

`script/TransferBeaconOwnership.s.sol` moves the beacon's ownership, and with it
the power to upgrade every token on the chain, from the current owner's key to
`NEW_BEACON_OWNER`. `UpgradeableBeacon` uses OpenZeppelin's one-step `Ownable`:
the transfer takes effect in the same transaction and cannot be taken back, so a
wrong address loses upgrade control of every token for good.

1. Get Derive's address and confirm it with them on a second channel. The
   beacon and its current owner are in [`DEPLOYMENTS.md`](./DEPLOYMENTS.md).
2. Simulate on a local fork. The fork runs under a different chain id, so
   nothing signed there is valid on the real chain:

   ```bash
   anvil --fork-url $RPC_URL --chain-id 31337 --port 8546 &
   export BEACON_ADDRESS=0x... NEW_BEACON_OWNER=0x... BEACON_OWNER_PRIVATE_KEY=0x...
   forge script script/TransferBeaconOwnership.s.sol --rpc-url http://127.0.0.1:8546 --broadcast
   ```

   Check the logged current and new owner, and whether the new owner is a
   contract (a Safe) or a plain wallet.
3. Broadcast for real, then read the owner back:

   ```bash
   forge script script/TransferBeaconOwnership.s.sol --rpc-url $RPC_URL --broadcast
   cast call $BEACON_ADDRESS 'owner()(address)' --rpc-url $RPC_URL   # must print NEW_BEACON_OWNER
   ```

4. Add a row to that chain's ownership history in `DEPLOYMENTS.md`.

The script refuses before signing anything if the key is not the beacon's owner,
or if the new owner is zero or already the owner. A beacon owned by a multisig
cannot use it: send `transferOwnership(newOwner)` from the multisig instead.

On a chain with no beacon yet, `DeployBeacon.s.sol` can instead take Derive's
address as `BEACON_OWNER`, so no transfer is needed.

## Source verification

**Deployments are not verified on a block explorer, and `--verify` is deliberately
absent from every command above.** Verifying publishes this repository's Solidity
source to a public explorer; that publication carries legal implications that have
not been settled, so it is off by default rather than a step an operator has to
remember to skip.

The capability still exists on the consumer side and is switched, not deleted: the
backend gates it behind `CONTRACT_VERIFICATION_ENABLED`, which defaults to false.
That is why `abi/StrandsDACAP.standard-input.json` is still committed and still
checked for drift by CI — the moment the flag is turned on, a stale artifact
verifies nothing, silently. Keep it correct even while it is unused.

If verification is ever authorised, turn on the backend flag rather than adding
`--verify` here; the backend submits the same standard JSON input, and having one
path means one thing to audit.

## .NET / Nethereum code generation

Pre-extracted artifacts in [`abi/`](./abi):

| File | Format | Use with |
| --- | --- | --- |
| `abi/StrandsDACAP.json` | Hardhat-style artifact (object with `_format`, `contractName`, `sourceName`, inline `abi` and `bytecode`) | Strands `ContractInterfaceGenerator` and any tool that expects a Hardhat/Truffle artifact |
| `abi/StrandsDACAP.abi` | Raw ABI JSON array | Vanilla `Nethereum.Generator.Console` |
| `abi/StrandsDACAP.bin` | Creation bytecode hex (no `0x` prefix) | Vanilla `Nethereum.Generator.Console` (deployment support) |
| `abi/StrandsDACAP.standard-input.json` | `{solcLongVersion, input}` wrapping the solc standard JSON input that produced the bytecode | Block-explorer source verification, via the consumer's generated `SOURCES` constant |
| `abi/BeaconProxy.json` | Hardhat-style artifact for OpenZeppelin's `BeaconProxy`, compiled with this repo's settings | Strands `ContractInterfaceGenerator` — **this is the bytecode a consumer deploys per token** |

`StrandsDACAP.json` is the token's ABI, which is what a consumer calls through
the proxy. Its `bytecode` is the *implementation's* — deployed once per chain by
`DeployBeacon.s.sol`, never per token. A consumer deploys `BeaconProxy`, with the
beacon address and ABI-encoded `initializeToken(...)` calldata as its two
constructor arguments.

### Strands ContractInterfaceGenerator

Copy `abi/StrandsDACAP.json` into the directory the generator scans
(e.g. `Sources/Strands/StrandsDACAP/StrandsDACAP.json`) and run
the CIG normally. The artifact carries `bytecode` inline, so that copy is the
whole ABI/bytecode sync — the generator bakes that value into
`StrandsDACAPDeploymentBase.BYTECODE`, and splicing the ABI and the
creation bytecode from separate files is how the two drift apart.

Copy `abi/BeaconProxy.json` the same way (e.g.
`Sources/Strands/BeaconProxy/BeaconProxy.json`): its generated deployment class is
the one the consumer sends.

Copy `abi/StrandsDACAP.standard-input.json` alongside it, under the same stem
(`Sources/Strands/StrandsDACAP/StrandsDACAP.standard-input.json`). The generator
picks it up by that name and emits `StrandsDACAPDeployment.SOURCES`; without it
that constant is simply not generated, and verification has nothing to submit.
The two files must come from the same `forge build` — see "Source verification"
for why a mismatch is invisible rather than loud.

If/when the contract is deployed, add a sibling `StrandsDACAP-deployments.json`
of shape `{"<chainId>": "0x<address>"}` to have the deployment class generated too.

### Plain Nethereum.Generator.Console

```bash
dotnet tool install -g Nethereum.Generator.Console
Nethereum.Generator.Console generate from-abi \
  -abi abi/StrandsDACAP.abi \
  -bin abi/StrandsDACAP.bin \
  -o   ./StrandsCustody.Contracts \
  -ns  StrandsCustody.Contracts \
  -cn  StrandsDACAP
```

### Regenerating after a contract change

```bash
forge build
forge inspect StrandsDACAP abi --json > abi/StrandsDACAP.abi
forge inspect StrandsDACAP bytecode | sed 's/^0x//' > abi/StrandsDACAP.bin
python3 - <<'PY'
import json
abi = json.load(open("abi/StrandsDACAP.abi"))
bytecode = open("abi/StrandsDACAP.bin").read().strip()
with open("abi/StrandsDACAP.json", "w") as f:
    json.dump({
        "_format": "hh-sol-artifact-1",
        "contractName": "StrandsDACAP",
        "sourceName":   "src/StrandsDACAP.sol",
        "abi": abi,
        "bytecode": "0x" + bytecode,
    }, f, indent=2)
    f.write("\n")
PY

# The proxy a consumer deploys per token. Unchanged by an edit to src/ — it moves only with the
# OpenZeppelin submodule or the compiler settings — but regenerated here so it cannot be forgotten.
forge inspect BeaconProxy abi --json > /tmp/BeaconProxy.abi
forge inspect BeaconProxy bytecode | sed 's/^0x//' > /tmp/BeaconProxy.bin
python3 - <<'PY3'
import json
with open("abi/BeaconProxy.json", "w") as f:
    json.dump({
        "_format": "hh-sol-artifact-1",
        "contractName": "BeaconProxy",
        "sourceName":   "lib/openzeppelin-contracts/contracts/proxy/beacon/BeaconProxy.sol",
        "abi": json.load(open("/tmp/BeaconProxy.abi")),
        "bytecode": "0x" + open("/tmp/BeaconProxy.bin").read().strip(),
    }, f, indent=2)
    f.write("\n")
PY3

# The verification payload. Nothing above produces it and nothing else reads it, so it is the
# one artifact that rots silently — see "Source verification". The address is a placeholder;
# --show-standard-json-input prints the payload locally and contacts no explorer.
forge verify-contract --show-standard-json-input \
  0x0000000000000000000000000000000000000001 src/StrandsDACAP.sol:StrandsDACAP > /tmp/bare.json
python3 - <<'PY2'
import json
bare = json.load(open("/tmp/bare.json"))
version = json.load(open("out/StrandsDACAP.sol/StrandsDACAP.json"))["metadata"]["compiler"]["version"]
# Wrapped as {solcLongVersion, input} so the compiler version travels with the sources and is
# never hand-typed. The consumer unwraps it: an explorer wants the bare {language, sources,
# settings}, and handing one the wrapper is accepted and then never verifies.
with open("abi/StrandsDACAP.standard-input.json", "w") as f:
    json.dump({"solcLongVersion": version, "input": bare}, f, indent=2)
    f.write("\n")
PY2
```

Then copy `abi/StrandsDACAP.json`, `abi/StrandsDACAP.standard-input.json` and
`abi/BeaconProxy.json` over the consumer's generator source and re-run the generator. Updating one without
the other leaves the generated `BYTECODE` constant deploying an older contract, or
the generated `SOURCES` constant describing one.

## License

`src/` — the deployed contracts — is Business Source License 1.1. The tests,
the deploy script and everything else in the repo remain MIT.
