//! Shared by every Nihilium recovery program: what a signature commits to, and how a detached
//! ed25519 signature is checked.
//!
//! One copy, because two programs carrying two copies of one security primitive is two copies that
//! drift — the same rule the SDK's service and watchtower packages follow for their credential
//! hashing.

pub mod cluster;
pub mod digest;
pub mod verify;

pub use cluster::CLUSTER_TAG;
pub use verify::{verify_detached, VerifyError, MESSAGE_LEN};
