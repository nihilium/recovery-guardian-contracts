# Deployment records

One file per cluster, written on a real deploy. These are committed: a program id is shared by
every vault on a cluster, so it is part of the repo's public record rather than local scratch state.

## What replaces EVM's `initCodeHash`

On the EVM side the address *is* the checkable artifact — CREATE2 makes it a pure function of the
source, so anyone can recompute `initCodeHash` and confirm the deployed code is this code.

**That property does not port.** A Solana program id is a keypair, chosen rather than derived, so
the id says nothing about what is deployed at it. `binarySha256` is the substitute here: the hash of
the `.so` that was deployed, which anyone can compare against `solana program dump`. It is weaker
than CREATE2 — it proves the deployed bytes match a recorded hash, not that they match this source —
and the real answer is a `solana-verify` reproducible build, which is why `Cargo.lock` is committed.

## `immutable` is the field that matters

The EVM modules have no owner, no admin and no upgrade path, because whoever holds an upgrade key
could rewrite the veto rules on every account at once. Solana programs are upgradeable **by
default**, so that guarantee has to be taken away deliberately by setting the upgrade authority to
`None`.

`immutable: false` therefore means *this deployment does not yet have the EVM security property*.
That is correct for devnet, where the program is still being iterated on and burning the id would
waste it. It must be `true` before anything on mainnet holds value.

## Upgrades need headroom, planned in advance

A Solana program account is sized at deploy time and **an upgrade that grows the binary fails**
unless the account was extended first — and `solana program extend` refuses anything under 10240
bytes. So a deploy that fits exactly is a deploy that cannot be upgraded without a separate
transaction and more rent.

This has no EVM counterpart: there, a changed module is simply a new address. Here, deploy with
room to grow. `dataLength` in each record is the *account* size, not the binary's.

## Clusters

| Cluster | Program id | Immutable |
|---|---|---|
| devnet | `DaLebS3k5gD1k42uGU6LPnSP9qTNwYxaKqLQBb7BqgkG` | no — upgrade authority retained for iteration |
| mainnet-beta | not deployed | — |

### Cluster tags are not interchangeable

Each build bakes in one `CLUSTER_TAG` and folds it into every digest, standing in for the
`block.chainid` an EVM contract gets for free. A devnet-built program refuses a signature made for
mainnet and vice versa, which `scripts/devnet-smoke.ts` asserts live. Deploying a binary built for
the wrong cluster produces a program nobody can sign for — check `buildFeatures` here against the
`nihilium-cluster:` string in the deployed binary before trusting a deployment.
