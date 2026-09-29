//! Which deployment a signature is valid on.
//!
//! EVM gets this free from `block.chainid`, which `RecoveryModule`'s EIP-712 domain separator
//! folds in. **A Solana program cannot read its cluster.** `declare_id!` fixes the program id in
//! source, so the same program deployed to devnet and to mainnet produces the same PDAs from the
//! same seeds — and a resume endorsement gathered on devnet would verify on mainnet against a
//! vault whose owner never agreed to it.
//!
//! So the separation is compiled in. The tag is chosen at build time and folded into every digest.
//!
//! **It is a domain separator, not an identifier.** It deliberately is not the cluster's genesis
//! hash: nothing here needs to *identify* the cluster, only to guarantee that two deployments never
//! agree on a digest. A readable ASCII constant does that exactly as well as a hash and can be
//! checked by eye, where a wrong genesis hash would be a silent, unfalsifiable mistake.
//!
//! Exactly one cluster feature must be enabled. Building with none, or with two, fails here rather
//! than producing a program whose signatures are valid somewhere unintended.

/// 32 bytes, NUL-padded. Folded into every digest in [`crate::digest`].
#[cfg(all(feature = "mainnet", not(any(feature = "devnet", feature = "localnet"))))]
pub const CLUSTER_TAG: [u8; 32] = *b"nihilium-cluster:mainnet-beta\0\0\0";

#[cfg(all(feature = "devnet", not(any(feature = "mainnet", feature = "localnet"))))]
pub const CLUSTER_TAG: [u8; 32] = *b"nihilium-cluster:devnet\0\0\0\0\0\0\0\0\0";

#[cfg(all(feature = "localnet", not(any(feature = "mainnet", feature = "devnet"))))]
pub const CLUSTER_TAG: [u8; 32] = *b"nihilium-cluster:localnet\0\0\0\0\0\0\0";

#[cfg(not(any(feature = "mainnet", feature = "devnet", feature = "localnet")))]
compile_error!(
    "no cluster feature enabled: build with exactly one of `localnet`, `devnet` or `mainnet`, or \
     the program's signatures would carry no domain separation between deployments"
);

#[cfg(any(
    all(feature = "mainnet", feature = "devnet"),
    all(feature = "mainnet", feature = "localnet"),
    all(feature = "devnet", feature = "localnet"),
))]
compile_error!(
    "more than one cluster feature enabled: the build must commit to exactly one, or two \
     deployments would agree on a digest"
);

#[cfg(test)]
mod tests {
    use super::CLUSTER_TAG;

    /// A tag that collides with another cluster's, or that is silently truncated, defeats the
    /// whole point. Both are cheap to rule out and neither is visible by reading the constant.
    #[test]
    fn the_tag_is_a_full_32_bytes_and_readable() {
        assert_eq!(CLUSTER_TAG.len(), 32);
        let text = core::str::from_utf8(&CLUSTER_TAG).expect("tag must stay readable");
        assert!(text.starts_with("nihilium-cluster:"));
        assert!(
            text.trim_end_matches('\0').len() < 32,
            "the name fills all 32 bytes, so a longer cluster name would truncate silently",
        );
    }
}
