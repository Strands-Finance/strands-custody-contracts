# Deployments

Where each chain's shared `StrandsDACAP` implementation and `UpgradeableBeacon` live. These are deployed once per chain
by `script/DeployBeacon.s.sol`. Tokens are not listed here: each one is a `BeaconProxy` that the backend deploys per
user, custodian and asset, and records in its own database.

When the beacon is pointed at a new implementation or handed to a new owner, add a row to that chain's history
instead of overwriting.

**Derive V2 and V3 are on different chains.** Derive V2 runs on Derive Chain, an OP-stack L2: testnet is chain 901 and
mainnet is chain 957. Derive V3 settles on Ethereum mainnet, chain 1. Each section below names the version it belongs
to.

The beacon on every chain is to be owned by Derive (decided by Cameron on 2026-10-05). Hand it over with
`script/TransferBeaconOwnership.s.sol`; see "Hand the beacon to Derive" in the README.

## Derive Chain testnet (chain 901, Derive V2)

| | Address |
|---|---|
| `UpgradeableBeacon` | [`0x54561b6e21c802a83CD986309de84ebDB01Ee33b`](https://testnet-explorer.derive.xyz/address/0x54561b6e21c802a83CD986309de84ebDB01Ee33b) |
| `StrandsDACAP` implementation (current) | [`0x74d0C819F28D37BceDc7A4Bbd2f342963d946686`](https://testnet-explorer.derive.xyz/address/0x74d0C819F28D37BceDc7A4Bbd2f342963d946686) |
| Beacon owner (can upgrade every token) | `0x30F10Bc50fCd6CA6d8567A2Bd2685ED975487c3c` — the dev backend's mint-authority hot wallet, until the beacon is handed to Derive |
| Deployer | `0x30F10Bc50fCd6CA6d8567A2Bd2685ED975487c3c` |

Backend config: `DERIVE_CUSTODY_DACAP_BEACON=0x54561b6e21c802a83CD986309de84ebDB01Ee33b`.

Ownership history:

| Date | Owner | How |
|---|---|---|
| 2026-10-02 | `0x30F10Bc50fCd6CA6d8567A2Bd2685ED975487c3c` (dev hot wallet) | Set at deploy (`BEACON_OWNER`), tx `0xb0198943…e3e0a4` |

Implementation history:

| Date | Implementation | Code | Deploy tx (block) | Beacon tx (block) |
|---|---|---|---|---|
| 2026-10-02 | `0x74d0C819F28D37BceDc7A4Bbd2f342963d946686` | PR #13 @ `d19c102` (unmerged) | [`0xc6ca7151…f5d674`](https://testnet-explorer.derive.xyz/tx/0xc6ca715122b9343ad5750e88972731821f8b000a5f7b23fac9f7b3958df5d674) (49937232) | [`0xb0198943…e3e0a4`](https://testnet-explorer.derive.xyz/tx/0xb019894c352fd968288704be3d06f1e3a1c34c13aec1d0fc203ec92a76e3e0a4) (49937234), deployed with this implementation |

**This deployment is unmerged PR code.** If review changes `src/`, deploy a new implementation, have the beacon owner
call `upgradeTo` with it, and add a row above. Once the beacon is Derive's, only Derive can send that `upgradeTo`.
`abi/` and the backend's bindings must move with it.

**The current implementation is out of date.** It is the two-initializer version, where a token's roles were seated by
a separate `initialize(admin, minter)`. The single-initializer change (`initializeToken` seats the deployer as admin and
minter; `initialize` and `initialized()` removed) needs a new implementation here and an `upgradeTo` from the beacon
owner before any backend deploys a token against this beacon.

Verified after deploy:
- Both contracts' runtime code equals a clean `forge build` (`forge inspect … deployedBytecode`).
- `implementation()` and `owner()` read back as above.
- The implementation is locked: its Initializable version is `type(uint64).max`, and `initializeToken` reverts with
  `InvalidInitialization`.
- A create-style `eth_call` of `abi/BeaconProxy.json` with `(beacon, initializeToken(6, …))` from the deployer returns
  the expected proxy code.
- A token's full lifecycle against this beacon, upgrade included, passed on a local anvil fork.

Source is not verified on the explorer; see "Source verification" in the README.

## Derive Chain mainnet (chain 957, Derive V2)

Not deployed, on purpose. Cameron decided on 2026-10-05 to deploy mainnet only once this stack is merged and the fork
testing is at a state he trusts. Until then, "not deployed" is expected, not a gap to close.

The beacon is to be owned by Derive. `DeployBeacon.s.sol` makes the deploying Strands key the owner; hand it over with
`TransferBeaconOwnership.s.sol`.

## Ethereum mainnet (chain 1, Derive V3)

Not deployed, on purpose: the same 2026-10-05 hold applies. The same choice of owner applies as on Derive Chain mainnet.

Before deploying here, run the fork suite in `test/fork/`. On a fork of Ethereum mainnet it runs `DeployBeacon.s.sol`,
deploys a token, hands the token's admin role and the beacon to Derive, and checks that everything comes out correctly
deployed, initialized and permissioned. See "Fork test" in the README.
