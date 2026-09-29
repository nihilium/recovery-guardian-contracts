# Deployment records

The deploy scripts write a record here on a real broadcast (never on a dry run), one folder per
contract and version:

    recovery-module/<version>/<chainid>.json              DeployRecoveryModule
    eip7702-recovery-account/<version>/<chainid>.json     DeployEip7702RecoveryAccount

Versioned so a new release can never overwrite an older one's record: every version stays
on-chain for good, so its record has to as well. These files are committed — the contracts are
immutable and shared by every account on a chain, so their address, salt and initcode hash are part
of the repo's public record, not local scratch state.

**Every version recorded here has known security issues** (audit of 2026-09-28); see the advisory
in [`../README.md`](../README.md). The fixed releases — RecoveryModule 4.0.0 and
Eip7702RecoveryAccount 2.0.0 — are not deployed yet.

`initCodeHash` is the value that makes the address checkable. Anyone can recompute it from this
source tree at the pinned solc version and confirm the address is what CREATE2 must have produced.

## Chains

### RecoveryModule v3.0.0 — resume signatures bound to the attempt

| Chain | Id | Address |
|---|---|---|
| Arbitrum Sepolia | 421614 | `0xb1e4b94804a0E770A8c84C2BD62B2Ee6F93AD4E9` |

### Eip7702RecoveryAccount v1.0.0

| Chain | Id | Address |
|---|---|---|
| Arbitrum Sepolia | 421614 | `0xF5768f61C8739727cf392C8655E0a67BEb25B872` |

### RecoveryModule v2.0.0 — veto clock in wall-clock seconds

| Chain | Id | Address | Explorer |
|---|---|---|---|
| Ethereum Sepolia | 11155111 | `0x55c469aBe9D19db9f88ef023af759FF540B3bCD8` | Etherscan, verified |
| Arbitrum One | 42161 | `0x55c469aBe9D19db9f88ef023af759FF540B3bCD8` | Arbiscan, verified |

### v1.0.0 — superseded (veto clock in block heights)

| Chain | Id | Address |
|---|---|---|
| Ethereum Sepolia | 11155111 | `0x00339522A395f0d0838Ad5cf979fAdc8B9c6269B` |
| Arbitrum One | 42161 | `0x00339522A395f0d0838Ad5cf979fAdc8B9c6269B` |

Still deployed, and permanently so — the module has no upgrade path by design, so v2 is a different
contract at a different address rather than a replacement. v1 predates these records; its addresses
live in `bindings/index.ts` as `legacyRecoveryModuleAddresses`.

Same address on both, and that is CREATE2 working as intended rather than a coincidence: one
initcode hash and one salt give one address on every chain. The deployed codehash has been compared
across the two and is identical.

## `deployedAtBlock` on Arbitrum is an L1 block

Solidity's `block.number` on Arbitrum returns the **L1** block, not the L2 height Arbiscan indexes —
a Nitro quirk the deploy script cannot work around, because `ArbSys` is a node-level precompile and
`forge script` executes against forked state in its own EVM.

So `recovery-module/2.0.0/42161.json` records an Ethereum block number. Locate that deployment by address, or by its
transaction:

- v2: L2 block `503406623`, tx `0x8310d02e7b0b5fb05daeddf4b3ce942f606a2baa734d09d92c142105848569c4`
- v1: L2 block `503398159`, tx `0x6d39886829b5ad234f8bc529e3c4f72a29bc035ba381b4348f775aa6415317ce`

Records for a non-Arbitrum chain are unaffected.
