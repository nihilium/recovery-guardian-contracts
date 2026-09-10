# evm

The ERC-7579 recovery module and the graduated-veto state machine for
[nihilium-recovery-sdk](https://github.com/nihilium/recovery-sdk), plus the generated ABI surface
the TypeScript SDK consumes. See the [repo root](../README.md) for how this fits alongside other
chains.

This is a standalone [Foundry](https://book.getfoundry.sh/) project — it installs its own
dependency tree, so the contract toolchain stays independent of the SDK's and `forge test` never
needs the TypeScript build.

```bash
npm install      # ModuleKit's Solidity deps
npm test         # 58 tests, including 2048-run fuzzing and the TS↔Solidity differential
npm run build    # forge build + ABI bindings + tsc
```

## Deployments

**v2.0.0** — the veto clock counts wall-clock seconds, not block heights.

| Chain | Address | |
|---|---|---|
| Sepolia (11155111) | [`0x55c469aBe9D19db9f88ef023af759FF540B3bCD8`](https://sepolia.etherscan.io/address/0x55c469abe9d19db9f88ef023af759ff540b3bcd8) | verified |
| Arbitrum One (42161) | [`0x55c469aBe9D19db9f88ef023af759FF540B3bCD8`](https://arbiscan.io/address/0x55c469abe9d19db9f88ef023af759ff540b3bcd8) | verified |

Same address on both chains — that is CREATE2 doing its job, not a coincidence. The deployed
codehash has been compared across the two and is identical. Recorded in
[`deployments/11155111.json`](deployments/11155111.json) /
[`deployments/42161.json`](deployments/42161.json) and in the address book at
[`bindings/index.ts`](bindings/index.ts), which is where the TypeScript SDK reads it from.

The **v1.0.0** modules at `0x00339522A395f0d0838Ad5cf979fAdc8B9c6269B` are still on-chain on both
and always will be: there is no upgrade path by design, so v2 is a different contract at a different
address rather than a replacement. An account that installed v1 keeps its block-counted veto until
its owner installs v2. They are recorded in `legacyRecoveryModuleAddresses`.

One singleton per chain, shared by every account; per-account state lives in the module's storage,
keyed by account. It has no owner, no admin and no upgrade path — a fix means deploying a new module
and each account choosing to install it. An upgradeable recovery module would mean whoever holds the
upgrade key can rewrite the veto rules on every account at once, which would undo the separation of
powers the whole design rests on.

### The veto clock is wall-clock seconds

`timelockSeconds` and `pauseCeilingSeconds` (v1: `timelockBlocks` / `pauseCeilingBlocks`) count
seconds, and `GradualVeto` advances on `block.timestamp`.

A timelock is a *human* interval — how long a hijacked recovery has to be noticed and paused — and a
block count only approximates that at a rate that differs per chain. One config meant roughly a
fortnight on Ethereum and a few days on a 2-second-block L2, so the security parameter silently
changed meaning as the module was deployed more widely. On Arbitrum it was worse than imprecise:
`block.number` there is the **L1** height, not the chain's own. `RecoveryModule` already timestamped
intent expiry, so this also removes a second, disagreeing clock from the same contract.

Timestamps are proposer-influenced by a few seconds; against a timelock measured in days that is
immaterial. `BlockRef` and `revocationFreshnessBlocks` on the trust-anchor side are deliberately
*unchanged* — anchoring a DKIM key to a point in time to stop backdating is the one place a block
height is the better instrument.

### The settlement chain and the proof network are separate axes

Deploying the module on Arbitrum does **not** move the identity gate there. Nihilium's zkEmail
verifiers (`zk_email_proof_1024` / `_2048`) and its DKIM registry are deployed on Sepolia and **not
on any Arbitrum**, so `ZKEmailConditionAdapter` must keep `network: 11155111` even for an Arbitrum
account. That composes correctly — the proof is verified off-chain by Nihilium against those
contracts, while settlement, the timelock and the veto run wherever the account lives — but it does
mean the identity half currently rests on testnet-deployed verifiers, which is worth weighing before
putting mainnet value behind it.

`ZKEmailConditionAdapter` (in the SDK repo) refuses a network with no verifier at construction time
rather than at recovery. Without that check a seal against `network: 42161` would look healthy, be
paid for, and fail only when someone actually needed their key back.

Deployed through the canonical CREATE2 factory, which makes the address a pure function of the
source. The same salt produces the same address on every chain, and anyone can recompute it to check
that the code at that address is the code in this repo.

## Deploying to Sepolia

`RecoveryModule` is a **singleton**: one instance per chain, shared by every account, with per-account
state kept in the module's own storage. It has no constructor arguments, no owner and no upgrade
path, so a deployment is a single unparameterised transaction.

### 1. Fill in `.env`

```bash
cp .env.example .env    # then fill in the blanks
```

`.env` is gitignored. Only `SEPOLIA_RPC_URL` is strictly required.

### 2. Choose how to sign

Preferred — an encrypted keystore, so no key is ever in a file this repo can read:

```bash
cast wallet import sepolia-deployer --interactive
npm run deploy:sepolia -- --account sepolia-deployer
```

`--ledger` works the same way. For CI or a throwaway testnet key, set `PRIVATE_KEY` in `.env` and
drop the flag. The script picks whichever is present, preferring the command line.

### 3. Dry run, then deploy

```bash
npm run deploy:sepolia:dry                                  # simulate; writes nothing
npm run deploy:sepolia -- --account sepolia-deployer        # broadcast
npm run deploy:sepolia:verify -- --account sepolia-deployer # broadcast + Etherscan
```

A successful broadcast writes `deployments/11155111.json` with the address, salt and initcode hash.
Verification can also be retried on its own once `RECOVERY_MODULE_ADDRESS` is in `.env`:

```bash
npm run verify:sepolia
```

### What the script protects you from

| Guard | Behaviour |
|---|---|
| Wrong chain | Refuses anything but Sepolia or Anvil; `ALLOW_ANY_CHAIN=true` overrides, deliberately |
| Re-running | Idempotent — if the predicted address already holds code, nothing is broadcast |
| Empty `.env` values | A present-but-empty variable is treated as unset, not as the empty string |
| Wrong artifact | Post-deploy assertions on the live bytecode: executor and not validator, expected `name()`, no pre-existing state |
| Dry runs | Never write a deployment record, so a simulation cannot be mistaken for a deployment |

### Address stability

The address moves if the initcode moves — a solc version bump, an optimizer setting, any source
change. That is intended: a changed module gets a new address rather than silently replacing the one
accounts already trust. Since there is no upgrade path, migrating means an account installing the new
module and uninstalling the old one, which is its own decision to make.

## Testing against other account implementations

The foundry suite doesn't hardcode an account. ModuleKit selects one from `ACCOUNT_TYPE`, defaulting
to the ERC-7579 reference account:

```bash
ACCOUNT_TYPE=KERNEL forge test    # ZeroDev Kernel
ACCOUNT_TYPE=SAFE7579 forge test
ACCOUNT_TYPE=NEXUS forge test
```

## Consumed by recovery-sdk

This repo is pulled into [recovery-sdk](https://github.com/nihilium/recovery-sdk) as a git
submodule at `onchain/evm`, pinned to a specific reviewed commit rather than tracking `main`. The
`test/fixtures/veto-traces.json` differential-testing fixture is generated by that repo's
`packages/veto` (its TypeScript veto state machine) and committed here so `VetoDifferential.t.sol`
can replay it — see that repo's `packages/veto/scripts/generate-veto-traces.mjs` for the
regeneration workflow.
