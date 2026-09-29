# evm

The ERC-7579 recovery module and the graduated-veto state machine for
[nihilium-recovery-sdk](https://github.com/nihilium/recovery-sdk), plus the generated ABI surface
the TypeScript SDK consumes. See the [repo root](../README.md) for how this fits alongside other
chains.

This is a standalone [Foundry](https://book.getfoundry.sh/) project — it installs its own
dependency tree, so the contract toolchain stays independent of the SDK's and `forge test` never
needs the TypeScript build.

```bash
npm install            # ModuleKit's Solidity deps
npm test               # 118 tests, including 2048-run fuzzing and the TS↔Solidity differential
npm run test:accounts  # the recovery lifecycle on real Default/Safe/Kernel/Nexus accounts
npm run build          # forge build + ABI bindings + tsc
```

## Security advisory — upgrade to RecoveryModule 4.0.0 / Eip7702RecoveryAccount 2.0.0

An audit on 2026-09-28 found issues in **every deployed version**. The fixed versions are in this
tree and **not yet deployed**. `bindings/index.ts` lists each deployed version's issues in
`recoveryModuleKnownIssues` / `eip7702AccountKnownIssues`.

| Issue | Affects | Fixed by |
|---|---|---|
| **H-1** Resume signatures stay valid for the whole attempt, so anyone can replay the first resume to undo every later pause | module v1–v3, 7702 v1 | every `pause` moves `attemptSeq`, so an endorsement lifts one pause |
| **H-2** Resume signatures also carry over to a later attempt with the same intent, including across uninstall/reinstall | module v1–v2 (**Arbitrum One mainnet**) | v3 bound them to the attempt |
| **M-1** Abort leaves the nonce alone, so anyone can resubmit an aborted intent's public signature | all | `abort` bumps the nonce |
| **M-2** `pauseCeilingSeconds` bounds each pause, not the total, so the pause authority can freeze an attempt forever | all | the ceiling is a per-attempt budget |
| **M-3** 7702 `register` leaves an in-flight attempt running and re-times it | 7702 v1 | `register` is refused while an attempt is live |
| **M-4** A delegated EOA rejects ETH and safe NFT transfers, and has no ERC-1271 | 7702 v1 | Solady `Receiver` + `ERC1271` (ERC-7739) |
| **L-2** A contract new owner (a Safe) cannot operate the account | 7702 v1 | owner signatures fall back to ERC-1271 |
| **L-3** The recovery key may also hold a veto role | all | refused on install / register |

There is no upgrade path by design, so a fix reaches an account only when its owner installs (or
delegates to) the fixed version.

## Deployments

Every deployed version has known issues; see the advisory above. 4.0.0 (module) and 2.0.0 (7702
account) are not deployed yet.

**RecoveryModule v2.0.0** — the veto clock counts wall-clock seconds, not block heights.

| Chain | Address | |
|---|---|---|
| Sepolia (11155111) | [`0x55c469aBe9D19db9f88ef023af759FF540B3bCD8`](https://sepolia.etherscan.io/address/0x55c469abe9d19db9f88ef023af759ff540b3bcd8) | verified |
| Arbitrum One (42161) | [`0x55c469aBe9D19db9f88ef023af759FF540B3bCD8`](https://arbiscan.io/address/0x55c469abe9d19db9f88ef023af759ff540b3bcd8) | verified |

**RecoveryModule v3.0.0** — resume signatures bound to the attempt.

| Chain | Address |
|---|---|
| Arbitrum Sepolia (421614) | `0xb1e4b94804a0E770A8c84C2BD62B2Ee6F93AD4E9` |

**Eip7702RecoveryAccount v1.0.0**

| Chain | Address |
|---|---|
| Arbitrum Sepolia (421614) | `0xF5768f61C8739727cf392C8655E0a67BEb25B872` |

Same address on every chain running the same version — that is CREATE2 doing its job, not a
coincidence. The v2 codehash has been compared across Sepolia and Arbitrum One and is identical.
Recorded under [`deployments/`](deployments/) (one folder per contract and version) and in the
address book at [`bindings/index.ts`](bindings/index.ts), which is where the TypeScript SDK reads
it from.

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
immaterial.

### The pause ceiling is a budget per attempt

Since 4.0.0, `pauseCeilingSeconds` bounds the pause authority's **total** freeze of an attempt,
not each pause. `pausedSeconds` counts every pause in the attempt; a resume or an auto-resume
leaves it spent, and `pause` reverts with `PauseBudgetExhausted` once it reaches the ceiling. An
attempt therefore matures within `timelockSeconds + pauseCeilingSeconds` whatever the pause
authority does. Before, the ceiling was per pause, and re-pausing the moment each one lapsed held
an attempt indefinitely. A resume endorsement lifts exactly one pause: every `pause` moves the
digest the resume quorum signs, so read `resumeDigest` after the pause you mean to lift. `BlockRef` and `revocationFreshnessBlocks` on the trust-anchor side are deliberately
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

A successful broadcast writes `deployments/recovery-module/<version>/11155111.json` with the
address, salt and initcode hash.
Verification can also be retried on its own once `RECOVERY_MODULE_ADDRESS` is in `.env`:

```bash
npm run verify:sepolia
```

### What the script protects you from

| Guard | Behaviour |
|---|---|
| Wrong chain | Refuses anything but Sepolia, Arbitrum Sepolia or Anvil; `ALLOW_ANY_CHAIN=true` overrides, deliberately — and the `deploy:arbitrum*` scripts do not set it for you |
| Re-running | Idempotent — if the predicted address already holds code, nothing is broadcast |
| Empty `.env` values | A present-but-empty variable is treated as unset, not as the empty string |
| Wrong artifact | Post-deploy assertions on the live bytecode: executor and not validator, expected `name()` and `version()`, no pre-existing state |
| Overwriting history | Records are written per version, so deploying a new version never replaces an older one's record |
| Dry runs | Never write a deployment record, so a simulation cannot be mistaken for a deployment |

### Address stability

The address moves if the initcode moves — a solc version bump, an optimizer setting, any source
change. That is intended: a changed module gets a new address rather than silently replacing the one
accounts already trust. Since there is no upgrade path, migrating means an account installing the new
module and uninstalling the old one, which is its own decision to make.

## Testing against other account implementations

The unit suite (`test/`) uses a recording mock account, which is what lets it check exactly what
the module asks an account to do. Whether real accounts *let* it is checked by the integration
suite in `integration/`, which runs the recovery lifecycle through ModuleKit on real accounts:

```bash
npm run test:accounts                                            # all four, in turn
FOUNDRY_PROFILE=integration ACCOUNT_TYPE=KERNEL forge test       # one: DEFAULT, SAFE, KERNEL, NEXUS
```

It lives in its own Foundry profile because Foundry's linter cannot parse ModuleKit's test harness;
the default profile keeps linting everything else.

## Known limitations, accepted

- **A matured attempt does not expire.** Once `EXECUTABLE`, anyone may execute it at any later time,
  and it blocks new attempts until then. Bounding it would need a new config field; `abort` remains
  the remedy, and a watchtower should flag an attempt left `EXECUTABLE` for long.
- **Recovery covers loss, not theft (7702).** The EOA's own key keeps protocol-level control for
  good: it can transact directly and re-delegate the EOA. Re-delegating elsewhere turns recovery off.
- **A stale `installed` flag.** An account that ignores a failing `onUninstall` (some use
  `excessivelySafeCall`) leaves the module thinking it is installed, and a reinstall then reverts
  `AlreadyInstalled`. The account can clear it by calling `onUninstall` on the module itself.
- **`verify:*` scripts source `.env` as shell**, so it must contain only `KEY=value` lines.

## Consumed by recovery-sdk

This repo is pulled into [recovery-sdk](https://github.com/nihilium/recovery-sdk) as a git
submodule at `onchain/evm`, pinned to a specific reviewed commit rather than tracking `main`. The
`test/fixtures/veto-traces.json` differential-testing fixture is generated by that repo's
`packages/veto` (its TypeScript veto state machine) and committed here so `VetoDifferential.t.sol`
can replay it — see that repo's `packages/veto/scripts/generate-veto-traces.mjs` for the
regeneration workflow.
