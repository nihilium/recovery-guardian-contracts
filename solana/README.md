# solana

The Anchor implementation of the recovery guardian for
[nihilium-recovery-sdk](https://github.com/nihilium/recovery-sdk). See the
[repo root](../README.md) for how this fits alongside other chains.

**Status: the vault program is deployed on devnet.** `nihilium-recovery-vault` passes an
end-to-end suite on a local validator and a live smoke test against
[`DaLebS3k5gD1k42uGU6LPnSP9qTNwYxaKqLQBb7BqgkG`](https://explorer.solana.com/address/DaLebS3k5gD1k42uGU6LPnSP9qTNwYxaKqLQBb7BqgkG?cluster=devnet)
on devnet — see [`deployments/`](deployments/). The Squads guard is not written yet.

## Recovery on Solana has to be set up in advance, and cannot be retrofitted

This is the one structural difference from `evm/`, and it is not a limitation of this
implementation — it is a property of the chain.

On EVM an account's address is independent of its signing key, so recovery *rotates* the key and
the address survives. Both EVM constructions rest on that: `RecoveryModule.sol` installs a new
ERC-7579 validator, and `Eip7702RecoveryAccount.sol` rotates a stored `owner` on a delegating EOA.

**A Solana keypair's address *is* its ed25519 public key.** There is no EIP-7702 analogue — no way
to attach code to a keypair address after the fact — so a lost Solana key means a permanently lost
address, and no program can change that. Recovery here therefore only protects assets that live in
a **program-owned account from the start**. A wallet that already holds funds at a plain keypair
address cannot be brought under this guardian retroactively; the assets have to be moved.

That is the honest answer to "why does the Solana version need setting up beforehand when the EVM
one doesn't", and it is why both planned constructions are account types rather than modules
bolted onto an existing one.

## What Solana gives back

- **`rk_pk` is already an address.** The recovery key is ed25519, so the derived key *is* a
  `Pubkey` — no `ecrecover`, no address derivation. The SDK's `key-solana` adapter already says so.
- **Wall-clock seconds are native.** `Clock::unix_timestamp` is exactly the unit the EVM veto moved
  to in v2.0.0, so the clock arithmetic ports with no change of meaning.
- **The fee payer is a separate signer**, so "a relayer broadcasts for a user with no funds" costs
  nothing and needs no meta-transaction plumbing.
- **The differential test needs no validator.** It is a plain `cargo test` over pure functions.

Be honest about the clock, though: Solana's `unix_timestamp` comes from validator votes and has
historically drifted from real time by more than the seconds an Ethereum proposer can shift it.
Against a timelock measured in days that is immaterial, and it is the only unit under which this
implementation and the oracle mean the same thing.

## What exists today

| Path | What it is |
|---|---|
| [`programs/nihilium-recovery-vault/`](programs/nihilium-recovery-vault/) | The vault program: a stored `owner` that a completed recovery rotates, with `execute_transfer` — the only instruction that can move value — gated on whoever `owner` currently is. |
| [`crates/gradual-veto/`](crates/gradual-veto/) | The §6.3 state machine, ported from `evm/src/GradualVeto.sol`. Pure Rust, **no Solana dependency** — addresses are `[u8; 32]` and the clock arrives as an `i64`, so it is auditable and testable on its own. |
| [`crates/nihilium-recovery-common/`](crates/nihilium-recovery-common/) | What a signature commits to (`digest.rs`), the cluster domain separator (`cluster.rs`), and ed25519 instruction introspection (`verify.rs`). Shared, so two programs never carry two copies of one security primitive. |
| [`bindings/`](bindings/) | The only surface the SDK may import: PDA derivations, state ordinals, and the client half of the digests and the ed25519 packer. |
| [`tests/`](tests/) | End-to-end against a local validator, including the confinement property and the ed25519 attacks. |

Not yet written: `nihilium-recovery-squads` (a guard over an external Squads smart account), the
deploy script, and the generated IDL address book.

```bash
npm run test:veto      # the veto port and digests: no validator needed, runs in milliseconds
npm run build          # anchor build (localnet) + IDL
npm run test:program   # end to end on a local validator
npm test               # both

npm run build:devnet   # rebuild with the devnet cluster tag
npm run deploy:devnet   # needs PRIVATE_KEY in .env
npm run smoke:devnet    # live check against the deployed program
```

**The cluster tag is chosen at build time, and the wrong one is silently useless.** `npm run build`
produces a *localnet* binary; deploying that to devnet gives a program whose digests nobody can
match. Always rebuild with the matching feature before deploying, and check the result:

```bash
strings target/deploy/nihilium_recovery_vault.so | grep -o 'nihilium-cluster:[a-z-]*'
```

### The toolchain needs platform-tools v1.53

`anchor build` defaults to platform-tools v1.48, whose bundled cargo is 1.84 and cannot parse
dependencies that now require edition 2024. v1.53 ships rustc 1.89 and builds cleanly, so the build
script passes `--tools-version v1.53`. The IDL step runs under the *host* toolchain and must not
receive that flag, which is why `npm run build` is two commands rather than a plain `anchor build`.

## The two instructions that carry the design

**`execute_recovery` rotates the owner and can do nothing else.** It moves no lamports and makes no
CPI; its only effect is `owner = intent.new_owner` plus the epoch and nonce bump. So whoever
extracts the raw recovery key gets the committed, vetoable rotation and never the funds — §15's
confinement property, asserted in `tests/` rather than trusted.

**`register` requires two independent signatures**, following `Eip7702RecoveryAccount.register`:
the current owner signs the transaction, and the claimed recovery key signs a registration digest
detached. Only the identity ceremony can mint the recovery key; only the owner can consent to it
being installed. A single-signature version leaves a window in which anyone binds their own key to
a freshly created vault.

## Detached signatures, and the attack they invite

Authority comes from ed25519 signatures carried in the transaction's `Ed25519SigVerify` instruction
rather than from its signers, so an intent can be signed once, offline, and broadcast by a relayer
for a user with no funded account.

**The precompile cannot be called and verifies whatever it was asked to verify.** A program that
merely confirms "a valid ed25519 instruction is present" accepts an attacker's own key over an
attacker's own message. Worse, because the precompile reads the signed message from whichever
instruction the offsets name while an introspecting program reads from the instruction it was
handed, the two can be pointed at *different places* — and then any signature the recovery key ever
published authorises any recovery.

`verify.rs` closes that by requiring every offset to reference the instruction under inspection, and
`tests/vault.ts` builds the full forgery to prove it: with that one check removed, the attack
succeeds and the test fails.

A consequence with no EVM counterpart: a resume carries k signatures inside a 1232-byte
transaction. Members share one 32-byte digest so each costs 110 bytes, which is where
`MAX_RESUME_MEMBERS = 8` comes from — a quorum larger than that is a pause that could never be
lifted, so it is refused at registration.

## The oracle, and why the fixture is duplicated

`packages/veto/src/machine.ts` in the SDK repo is the oracle. Every chain replays the *same*
traces against its own implementation: Solidity via `evm/test/VetoDifferential.t.sol`, Rust via
`crates/gradual-veto/tests/differential.rs`.

The fixture therefore exists twice, once per chain directory, so each directory stays
self-contained — and both copies are written from one in-memory value by
`packages/veto/scripts/generate-veto-traces.mjs`, then checked byte-for-byte against each other by
`packages/veto/test/traces.test.ts`. Two implementations pinned to two *different* fixtures are not
pinned to each other at all, and that failure would be invisible from inside either chain's own
suite. Regenerate with:

```bash
node packages/veto/scripts/generate-veto-traces.mjs   # writes every chain's copy
```

Only regenerate when the derivation was *meant* to change: regenerating is how you would "fix" a
failing differential test by moving the target.

## Two things a Solana port can silently lose

Recorded here because both are EVM guarantees that do not come for free on this chain, and neither
failure is visible from reading the program.

1. **Immutability.** The EVM modules have "no owner, no admin and no upgrade path" — whoever holds
   an upgrade key could rewrite the veto rules on every account at once, which would undo the
   separation of powers the design rests on. Solana programs are upgradeable **by default**, so
   this has to be taken away deliberately: set the upgrade authority to `None` after deployment,
   and assert it in the deploy script.
2. **Address determinism.** `evm/` deploys through CREATE2, so the address is a pure function of
   the source and anyone can recompute it to check the deployed code. A Solana program id is a
   keypair, not a function of the source, so that property **does not port**. The substitute is a
   `solana-verify` reproducible build with the verified hash recorded per deployment — which is
   also why `Cargo.lock` is committed.
