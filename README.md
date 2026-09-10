# recovery-guardian-contracts

On-chain contracts for [nihilium-recovery-sdk](https://github.com/nihilium/recovery-sdk)'s
recovery guardian — identity-gated, condition-based key recovery for self-custodial wallets. Kept
in its own repo, independent of the SDK's TypeScript codebase, so the on-chain code can be
publicly audited on its own.

Recovery guardian is a per-chain concept: each chain gets its own recovery module and its own
implementation, one directory per chain.

| Directory | Chain | Status |
|---|---|---|
| [`evm/`](evm/) | Ethereum and other EVM chains (Foundry) | Live — deployed on Sepolia and Arbitrum One, see [`evm/README.md`](evm/README.md) |
| `solana/` | Solana (Anchor) | Not started |

`nihilium-recovery-sdk` pulls this whole repo in as a single git submodule mounted at `onchain/`,
pinned to a specific reviewed commit rather than tracking `main`, so `onchain/evm/` here lines up
with `onchain/evm/` there.
