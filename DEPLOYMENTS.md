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

## Ethereum Sepolia (chain 11155111)

Strands' own testnet deploy, ahead of Ethereum mainnet. Derive has no V3 testnet, so nothing of Derive's is on
Sepolia. Cameron deployed it by hand on 2026-10-05, with the deploying key he means to use on mainnet.

| | Address |
|---|---|
| `UpgradeableBeacon` | [`0x47A6aDF49f9D2dF03d1b8e2319A79A0dD47E8Df7`](https://sepolia.etherscan.io/address/0x47A6aDF49f9D2dF03d1b8e2319A79A0dD47E8Df7) |
| `StrandsDACAP` implementation (current) | [`0x20A5bf6C9F8F64772677fF7acabB0806C7471173`](https://sepolia.etherscan.io/address/0x20A5bf6C9F8F64772677fF7acabB0806C7471173) |
| Beacon owner (can upgrade every token) | `0x30F10Bc50fCd6CA6d8567A2Bd2685ED975487c3c` — the dev backend's mint-authority hot wallet |
| Deployer | `0x30F10Bc50fCd6CA6d8567A2Bd2685ED975487c3c` |

Backend config, for an environment pointed at Sepolia:
`DERIVE_CUSTODY_DACAP_BEACON=0x47A6aDF49f9D2dF03d1b8e2319A79A0dD47E8Df7`.

Ownership history:

| Date | Owner | How |
|---|---|---|
| 2026-10-05 | `0x30F10Bc50fCd6CA6d8567A2Bd2685ED975487c3c` (dev hot wallet) | The deploying key, set at deploy, tx `0xefe93717…b11b57` |

Implementation history:

| Date | Implementation | Code | Deploy tx (block) | Beacon tx (block) |
|---|---|---|---|---|
| 2026-10-05 | `0x20A5bf6C9F8F64772677fF7acabB0806C7471173` | `src/` as on `main` @ `bad9e49` | [`0x40fbe015…1edc877`](https://sepolia.etherscan.io/tx/0x40fbe01525770636ad436ef7f64ae328724ba7a85ee5085fe547ea3aa1edc877) (11852068) | [`0xefe93717…b11b57`](https://sepolia.etherscan.io/tx/0xefe9371740cbe34ed2f34db4af6c42f2ba64d7878a58db9fb8d2666e62b11b57) (11852068), deployed with this implementation |

Deployed with `forge script script/DeployBeacon.s.sol --sig "sepolia()" --broadcast`: 1,571,403 gas (implementation
1,322,062, beacon 249,341).

Verified after deploy:
- `forge script script/CheckBeacon.s.sol --sig "sepolia()"` passed every check. The beacon is OpenZeppelin's, owned by
  the deploying key. The implementation is locked and its code is `abi/StrandsDACAP.json`'s (runtime keccak
  `0x5f7cd2aac4c1b3d026f88143f6e010e0c5baff660fab14b4eea833da8f7ff11e`). A token deployed against it comes out live.
- `owner()` and `implementation()` read back as above with `cast call`.

It was rehearsed first on a local anvil fork of Sepolia (`--sig "localFork()"`), then dry-run against Sepolia itself.
Source is not verified on the explorer; see "Source verification" in the README.

## Ethereum mainnet (chain 1, Derive V3)

Cameron deployed it by hand on 2026-10-06 at 00:14Z (the evening of 2026-10-05, US time), with the same deploying key
as Sepolia. `DeployBeacon.s.sol` made that key the beacon's owner; it is handed to Derive later with
`TransferBeaconOwnership.s.sol`, once Derive names its L1 address. This is not Derive Chain mainnet (957), which is
still on hold.

| | Address |
|---|---|
| `UpgradeableBeacon` | [`0x39f609C99C2145B634eA0caeb783Dd19053c0E58`](https://etherscan.io/address/0x39f609C99C2145B634eA0caeb783Dd19053c0E58) |
| `StrandsDACAP` implementation (current) | [`0x735ff6D5a2d3E4a51cAC3829fFA1E57732885Cb5`](https://etherscan.io/address/0x735ff6D5a2d3E4a51cAC3829fFA1E57732885Cb5) |
| Beacon owner (can upgrade every token) | `0x30F10Bc50fCd6CA6d8567A2Bd2685ED975487c3c` — the dev backend's mint-authority hot wallet, until the beacon is handed to Derive |
| Deployer | `0x30F10Bc50fCd6CA6d8567A2Bd2685ED975487c3c` |

Backend config, for an environment pointed at Ethereum mainnet:
`DERIVE_CUSTODY_DACAP_BEACON=0x39f609C99C2145B634eA0caeb783Dd19053c0E58`.

Ownership history:

| Date | Owner | How |
|---|---|---|
| 2026-10-06 | `0x30F10Bc50fCd6CA6d8567A2Bd2685ED975487c3c` (dev hot wallet) | The deploying key, set at deploy, tx `0x9d5eee9a…238bb0` |

Implementation history:

| Date | Implementation | Code | Deploy tx (block) | Beacon tx (block) |
|---|---|---|---|---|
| 2026-10-06 | `0x735ff6D5a2d3E4a51cAC3829fFA1E57732885Cb5` | `src/` as on `main` @ `bad9e49` | [`0xf21e509a…a9e198`](https://etherscan.io/tx/0xf21e509a593be6fc8106dd3861a872dfc3eee661bc05b7a87cb4bee022a9e198) (26129681) | [`0x9d5eee9a…238bb0`](https://etherscan.io/tx/0x9d5eee9a52c861672b929383f6647247dae8ac0e7de461ab092aa3883b238bb0) (26129683), deployed with this implementation |

Deployed with `forge script script/DeployBeacon.s.sol --sig "mainnet()" --broadcast`, run from PR #18's branch
(`src/`, `abi/` and `lib/` identical to `main` @ `bad9e49`): 1,571,403 gas (implementation 1,322,062, beacon 249,341),
the same as the Sepolia deploy and the fork rehearsal.

Verified after deploy:
- `forge script script/CheckBeacon.s.sol --sig "mainnet()"` passed every check. The beacon is OpenZeppelin's, owned by
  the deploying key. The implementation is locked and its code is `abi/StrandsDACAP.json`'s (runtime keccak
  `0x5f7cd2aac4c1b3d026f88143f6e010e0c5baff660fab14b4eea833da8f7ff11e`, the same as Sepolia's). A token deployed
  against it comes out live.
- `owner()` and `implementation()` read back as above with `cast call`, and the implementation's Initializable version
  is `type(uint64).max`.

Source is not verified on the explorer; see "Source verification" in the README.

Derive V3 has no testnet of its own, so the deploy was also rehearsed on a local anvil fork of Ethereum mainnet. With
`ALCHEMY_KEY` and `DEPLOYER_PRIVATE_KEY` in the environment, the steps were (from "Fork test" and "Deploy" in the
README):
1. Run the fork suite in `test/fork/`. On a fork of Ethereum mainnet it runs `DeployBeacon.s.sol`, deploys a token,
   hands the token's admin role and the beacon to Derive, and checks that everything comes out correctly deployed,
   initialized and permissioned.
2. Rehearse on a local anvil fork of mainnet (`--chain-id 31337`): `DeployBeacon.s.sol` then `CheckBeacon.s.sol`, both
   `--sig "localFork()"`.
3. Dry-run: `forge script script/DeployBeacon.s.sol --sig "mainnet()"`.
4. Deploy and check: the same with `--broadcast`, then `forge script script/CheckBeacon.s.sol --sig "mainnet()"`.

Rehearsed on 2026-10-05, on a fork at block 26,129,310: the implementation took 1,322,062 gas and the beacon 249,341,
1,571,403 in all. `CheckBeacon.s.sol` passed against it.
