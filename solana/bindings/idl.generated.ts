/**
 * Program IDL in camelCase format in order to be used in JS/TS.
 *
 * Note that this is only a type helper and is not the actual IDL. The original
 * IDL can be found at `target/idl/nihilium_recovery_vault.json`.
 */
export type NihiliumRecoveryVault = {
  "address": "DaLebS3k5gD1k42uGU6LPnSP9qTNwYxaKqLQBb7BqgkG",
  "metadata": {
    "name": "nihiliumRecoveryVault",
    "version": "0.7.2",
    "spec": "0.1.0",
    "description": "Identity-gated, graduated-veto recovery for a program-owned Solana vault."
  },
  "instructions": [
    {
      "name": "abort",
      "docs": [
        "Any non-terminal -> ABORTED, by the abort authority only (§15). Irreversible.",
        "",
        "The anti-rogue-Nihilium backstop (§7). It must work when everything else has failed, so it",
        "takes no proof, no quorum and no cooperation — one signature from a key the owner keeps",
        "offline."
      ],
      "discriminator": [
        73,
        205,
        102,
        177,
        241,
        200,
        145,
        80
      ],
      "accounts": [
        {
          "name": "vault",
          "writable": true
        },
        {
          "name": "abortAuthority",
          "signer": true
        }
      ],
      "args": []
    },
    {
      "name": "createVault",
      "docs": [
        "Create an empty vault. The creator becomes the first owner.",
        "",
        "`creator` and `vault_id` are the PDA seeds and are fixed forever; `owner` moves. Keeping",
        "them apart is what lets a recovery rotate the owner without moving the vault's address,",
        "which the SDK's key derivation requires: the address is `accountId`, a KDF input that must",
        "be reproducible at recovery time."
      ],
      "discriminator": [
        29,
        237,
        247,
        208,
        193,
        82,
        54,
        135
      ],
      "accounts": [
        {
          "name": "payer",
          "writable": true,
          "signer": true
        },
        {
          "name": "creator",
          "signer": true
        },
        {
          "name": "vault",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  118,
                  97,
                  117,
                  108,
                  116
                ]
              },
              {
                "kind": "account",
                "path": "creator"
              },
              {
                "kind": "arg",
                "path": "vaultId"
              }
            ]
          }
        },
        {
          "name": "vaultSol",
          "docs": [
            "stored; never written to by this program except through a signed system transfer."
          ],
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  115,
                  111,
                  108
                ]
              },
              {
                "kind": "account",
                "path": "vault"
              }
            ]
          }
        },
        {
          "name": "systemProgram",
          "address": "11111111111111111111111111111111"
        }
      ],
      "args": [
        {
          "name": "vaultId",
          "type": {
            "array": [
              "u8",
              16
            ]
          }
        }
      ]
    },
    {
      "name": "executeRecovery",
      "docs": [
        "EXECUTABLE -> EXECUTED: rotate the owner and bump the epoch.",
        "",
        "The epoch bump is what invalidates every prior-epoch intent, in the same transaction as the",
        "rotation. Permissionless to submit for the same reason as `initiate_recovery`: the authority",
        "came from the signature checked at initiation, and the timelock and veto have governed",
        "everything since.",
        "",
        "The intent is re-supplied and re-hashed rather than stored: `new_owner_config` is unbounded,",
        "and storing it would force an arbitrary cap into the account layout."
      ],
      "discriminator": [
        203,
        133,
        133,
        228,
        153,
        121,
        182,
        237
      ],
      "accounts": [
        {
          "name": "vault",
          "writable": true
        }
      ],
      "args": [
        {
          "name": "intent",
          "type": {
            "defined": {
              "name": "intent"
            }
          }
        }
      ]
    },
    {
      "name": "executeTransfer",
      "docs": [
        "Move lamports out of the vault. **The only instruction that can move value**, and it",
        "requires the current owner.",
        "",
        "Deliberately not reachable by the recovery key, the pause authority, the abort authority or",
        "the resume quorum. That is the confinement property stated in this module's header, and the",
        "reason a recovery rotates `owner` rather than acting on the owner's behalf."
      ],
      "discriminator": [
        233,
        126,
        160,
        184,
        235,
        206,
        31,
        119
      ],
      "accounts": [
        {
          "name": "vault"
        },
        {
          "name": "owner",
          "signer": true
        },
        {
          "name": "vaultSol",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  115,
                  111,
                  108
                ]
              },
              {
                "kind": "account",
                "path": "vault"
              }
            ]
          }
        },
        {
          "name": "destination",
          "writable": true
        },
        {
          "name": "systemProgram",
          "address": "11111111111111111111111111111111"
        }
      ],
      "args": [
        {
          "name": "amount",
          "type": "u64"
        }
      ]
    },
    {
      "name": "initiateRecovery",
      "docs": [
        "Start a recovery. Permissionless to *submit* — the authority is the detached signature."
      ],
      "discriminator": [
        132,
        148,
        60,
        74,
        49,
        178,
        235,
        187
      ],
      "accounts": [
        {
          "name": "vault",
          "writable": true
        },
        {
          "name": "instructions",
          "address": "Sysvar1nstructions1111111111111111111111111"
        }
      ],
      "args": [
        {
          "name": "intent",
          "type": {
            "defined": {
              "name": "intent"
            }
          }
        },
        {
          "name": "ed25519Index",
          "type": "u8"
        }
      ]
    },
    {
      "name": "pause",
      "docs": [
        "INITIATED -> PAUSED, by the pause authority only (§15)."
      ],
      "discriminator": [
        211,
        22,
        221,
        251,
        74,
        121,
        193,
        47
      ],
      "accounts": [
        {
          "name": "vault",
          "writable": true
        },
        {
          "name": "pauseAuthority",
          "signer": true
        }
      ],
      "args": []
    },
    {
      "name": "projectedState",
      "docs": [
        "The effective state right now, with the clock projected forward — auto-resume included.",
        "",
        "A paused attempt past its ceiling really is INITIATED again whether or not anyone has poked",
        "the program, so a caller must be able to learn that without sending a transaction that",
        "changes anything. Simulate this instruction to read it."
      ],
      "discriminator": [
        154,
        83,
        215,
        71,
        59,
        78,
        108,
        201
      ],
      "accounts": [
        {
          "name": "vault"
        }
      ],
      "args": [],
      "returns": "u8"
    },
    {
      "name": "register",
      "docs": [
        "Bind a recovery key and a veto configuration to this vault, or replace the ones it has.",
        "",
        "**Two independent signatures, both required**, following `Eip7702RecoveryAccount.register`:",
        "the current `owner` signs the transaction, and the claimed `recovery_owner` signs",
        "`registration_digest` detached. Only the identity ceremony can mint the recovery key, and",
        "only the owner can consent to it being installed. A single-signature version would leave a",
        "front-running window in which anyone binds their own recovery key to a freshly created",
        "vault.",
        "",
        "**Re-callable, deliberately.** A recovery key is not fixed for the life of a vault. The",
        "Nihilium setup behind it can change; a completed recovery exposes the key it derived; a",
        "cohort can be retired. A vault that could never be repointed would, in any of those cases,",
        "be left with a recovery key nobody should trust and no way to replace it — which is not a",
        "degraded recovery but the absence of one. `config_nonce` makes each registration a distinct,",
        "once-spendable signature so an old one cannot be replayed to revert a rotation.",
        "",
        "**Refused while a recovery is in flight**, and this is the interesting part. Rotating the",
        "key does *not* stop an attempt the old key already opened: `execute_recovery` checks the",
        "committed intent digest, and the recovery key's signature was verified back at",
        "`initiate_recovery` and is never re-checked. So a rotation performed *because* the old key",
        "was compromised would leave the attacker's in-flight attempt running while the owner",
        "reasonably believed they had just stopped it. Refusing here makes that impossible to get",
        "wrong: killing an attempt is `abort`'s job, and it is a different authority on purpose."
      ],
      "discriminator": [
        211,
        124,
        67,
        15,
        211,
        194,
        178,
        240
      ],
      "accounts": [
        {
          "name": "vault",
          "writable": true
        },
        {
          "name": "owner",
          "signer": true
        },
        {
          "name": "instructions",
          "address": "Sysvar1nstructions1111111111111111111111111"
        }
      ],
      "args": [
        {
          "name": "recoveryOwner",
          "type": "pubkey"
        },
        {
          "name": "veto",
          "type": {
            "defined": {
              "name": "vetoConfigAccount"
            }
          }
        },
        {
          "name": "configNonce",
          "type": "u64"
        },
        {
          "name": "ed25519Index",
          "type": "u8"
        }
      ]
    },
    {
      "name": "resume",
      "docs": [
        "PAUSED -> INITIATED, by a threshold of the resume quorum only (§15).",
        "",
        "Plurality is the defence against premature release, so the threshold is counted over",
        "*distinct* members — a repeated signer is rejected rather than counted twice.",
        "",
        "`signers` drives both halves: it is checked for distinctness and membership here, and it is",
        "the order the precompile's entries must appear in. One argument, one order, so the client",
        "cannot get the two out of step."
      ],
      "discriminator": [
        1,
        166,
        51,
        170,
        127,
        32,
        141,
        206
      ],
      "accounts": [
        {
          "name": "vault",
          "writable": true
        },
        {
          "name": "instructions",
          "address": "Sysvar1nstructions1111111111111111111111111"
        }
      ],
      "args": [
        {
          "name": "signers",
          "type": {
            "vec": "pubkey"
          }
        },
        {
          "name": "ed25519Index",
          "type": "u8"
        }
      ]
    }
  ],
  "accounts": [
    {
      "name": "vault",
      "discriminator": [
        211,
        8,
        232,
        43,
        2,
        152,
        117,
        119
      ]
    }
  ],
  "events": [
    {
      "name": "recoveryAborted",
      "discriminator": [
        6,
        213,
        21,
        181,
        34,
        22,
        147,
        138
      ]
    },
    {
      "name": "recoveryExecuted",
      "discriminator": [
        161,
        218,
        6,
        191,
        85,
        217,
        12,
        144
      ]
    },
    {
      "name": "recoveryInitiated",
      "discriminator": [
        138,
        165,
        92,
        207,
        123,
        93,
        223,
        98
      ]
    },
    {
      "name": "recoveryKeyRotated",
      "discriminator": [
        9,
        18,
        60,
        161,
        76,
        115,
        247,
        45
      ]
    },
    {
      "name": "recoveryPaused",
      "discriminator": [
        23,
        171,
        247,
        141,
        196,
        27,
        155,
        81
      ]
    },
    {
      "name": "recoveryRegistered",
      "discriminator": [
        111,
        15,
        131,
        68,
        223,
        251,
        40,
        71
      ]
    },
    {
      "name": "recoveryResumed",
      "discriminator": [
        91,
        175,
        113,
        41,
        219,
        39,
        178,
        0
      ]
    },
    {
      "name": "vaultCreated",
      "discriminator": [
        117,
        25,
        120,
        254,
        75,
        236,
        78,
        115
      ]
    }
  ],
  "errors": [
    {
      "code": 6000,
      "name": "wrongConfigNonce",
      "msg": "registration nonce does not match; this signature was minted for a different rotation"
    },
    {
      "code": 6001,
      "name": "notRegistered",
      "msg": "this vault has no recovery key bound to it yet"
    },
    {
      "code": 6002,
      "name": "notOwner",
      "msg": "signer is not this vault's owner"
    },
    {
      "code": 6003,
      "name": "zeroRecoveryOwner",
      "msg": "the recovery owner cannot be the zero address"
    },
    {
      "code": 6004,
      "name": "zeroNewOwner",
      "msg": "the new owner cannot be the zero address"
    },
    {
      "code": 6005,
      "name": "intentExpired",
      "msg": "this intent has expired"
    },
    {
      "code": 6006,
      "name": "wrongEpoch",
      "msg": "this intent is for a different recovery epoch"
    },
    {
      "code": 6007,
      "name": "wrongNonce",
      "msg": "this intent is for a different nonce"
    },
    {
      "code": 6008,
      "name": "attemptInFlight",
      "msg": "a recovery attempt is already in flight for this vault"
    },
    {
      "code": 6009,
      "name": "noAttempt",
      "msg": "this vault has no recovery attempt"
    },
    {
      "code": 6010,
      "name": "unknownIntent",
      "msg": "this is not the intent the in-flight attempt was opened for"
    },
    {
      "code": 6011,
      "name": "notPauseAuthority",
      "msg": "signer is not the pause authority"
    },
    {
      "code": 6012,
      "name": "notAbortAuthority",
      "msg": "signer is not the abort authority"
    },
    {
      "code": 6013,
      "name": "notResumeQuorum",
      "msg": "a named signer is not a member of the resume quorum"
    },
    {
      "code": 6014,
      "name": "belowResumeThreshold",
      "msg": "fewer distinct endorsements than the resume threshold"
    },
    {
      "code": 6015,
      "name": "duplicateResumeSigner",
      "msg": "a resume signer was named twice; plurality is counted over distinct members"
    },
    {
      "code": 6016,
      "name": "notInitiated",
      "msg": "pause is only legal from INITIATED"
    },
    {
      "code": 6017,
      "name": "notPaused",
      "msg": "resume is only legal from PAUSED"
    },
    {
      "code": 6018,
      "name": "notExecutable",
      "msg": "execute is only legal once the timelock has matured"
    },
    {
      "code": 6019,
      "name": "alreadyTerminal",
      "msg": "this recovery is already over"
    },
    {
      "code": 6020,
      "name": "pauseAuthorityIsZero",
      "msg": "pauseAuthority is zero"
    },
    {
      "code": 6021,
      "name": "abortAuthorityIsZero",
      "msg": "abortAuthority is zero"
    },
    {
      "code": 6022,
      "name": "resumeQuorumIsEmpty",
      "msg": "resume quorum is empty"
    },
    {
      "code": 6023,
      "name": "resumeThresholdIsZero",
      "msg": "resume threshold is zero"
    },
    {
      "code": 6024,
      "name": "resumeThresholdExceedsMembership",
      "msg": "resume threshold exceeds membership"
    },
    {
      "code": 6025,
      "name": "timelockIsZero",
      "msg": "timelockSeconds is zero"
    },
    {
      "code": 6026,
      "name": "pauseCeilingIsZero",
      "msg": "pauseCeilingSeconds is zero, so no pause would ever be possible"
    },
    {
      "code": 6027,
      "name": "pauseAndAbortHeldByOneParty",
      "msg": "pause and abort held by one party"
    },
    {
      "code": 6028,
      "name": "pauseAndResumeHeldByOneParty",
      "msg": "pause and resume held by one party"
    },
    {
      "code": 6029,
      "name": "resumeAndAbortHeldByOneParty",
      "msg": "resume and abort held by one party"
    },
    {
      "code": 6030,
      "name": "resumeQuorumContainsZeroAddress",
      "msg": "resume quorum contains the zero address"
    },
    {
      "code": 6031,
      "name": "resumeQuorumContainsDuplicate",
      "msg": "resume quorum contains a duplicate"
    },
    {
      "code": 6032,
      "name": "tooManyResumeMembers",
      "msg": "resume quorum is larger than a resume transaction can carry"
    },
    {
      "code": 6033,
      "name": "pauseBudgetExhausted",
      "msg": "this attempt's pause budget (pauseCeilingSeconds) is spent"
    },
    {
      "code": 6034,
      "name": "recoveryOwnerHoldsVetoRole",
      "msg": "the recovery owner cannot also hold a veto role"
    }
  ],
  "types": [
    {
      "name": "attemptAccount",
      "docs": [
        "One attempt's clock, as the account stores it.",
        "",
        "`state` is the ordinal rather than the enum so the layout is fixed and the IDL is readable; the",
        "ordinals are pinned by `gradual_veto`'s own tests and shared with the Solidity enum."
      ],
      "type": {
        "kind": "struct",
        "fields": [
          {
            "name": "state",
            "type": "u8"
          },
          {
            "name": "accruedSeconds",
            "type": "u64"
          },
          {
            "name": "pausedSeconds",
            "type": "u64"
          },
          {
            "name": "checkpointTime",
            "type": "i64"
          }
        ]
      }
    },
    {
      "name": "intent",
      "docs": [
        "The recovery this vault has committed to. One-to-one with `RecoveryModule.Intent`."
      ],
      "type": {
        "kind": "struct",
        "fields": [
          {
            "name": "newOwner",
            "type": "pubkey"
          },
          {
            "name": "newOwnerConfig",
            "docs": [
              "Chain-native encoding of the owner configuration to install. Opaque to this program."
            ],
            "type": "bytes"
          },
          {
            "name": "epoch",
            "type": "u64"
          },
          {
            "name": "nonce",
            "type": "u64"
          },
          {
            "name": "expiry",
            "docs": [
              "Unix seconds after which this intent may no longer open a recovery."
            ],
            "type": "i64"
          }
        ]
      }
    },
    {
      "name": "recoveryAborted",
      "type": {
        "kind": "struct",
        "fields": [
          {
            "name": "vault",
            "type": "pubkey"
          },
          {
            "name": "intentDigest",
            "type": {
              "array": [
                "u8",
                32
              ]
            }
          }
        ]
      }
    },
    {
      "name": "recoveryExecuted",
      "type": {
        "kind": "struct",
        "fields": [
          {
            "name": "vault",
            "type": "pubkey"
          },
          {
            "name": "intentDigest",
            "type": {
              "array": [
                "u8",
                32
              ]
            }
          },
          {
            "name": "newOwner",
            "type": "pubkey"
          },
          {
            "name": "newEpoch",
            "type": "u64"
          }
        ]
      }
    },
    {
      "name": "recoveryInitiated",
      "type": {
        "kind": "struct",
        "fields": [
          {
            "name": "vault",
            "type": "pubkey"
          },
          {
            "name": "intentDigest",
            "type": {
              "array": [
                "u8",
                32
              ]
            }
          },
          {
            "name": "epoch",
            "type": "u64"
          }
        ]
      }
    },
    {
      "name": "recoveryKeyRotated",
      "docs": [
        "A recovery key replaced, rather than installed for the first time.",
        "",
        "Distinct from `RecoveryRegistered` because a watchtower must be able to tell \"this vault just",
        "got its protection\" from \"this vault's protection changed underneath the watch it registered\" —",
        "the second is what `WatchObservation.integrity` reports, and conflating them would make every",
        "new vault look like a tampered one."
      ],
      "type": {
        "kind": "struct",
        "fields": [
          {
            "name": "vault",
            "type": "pubkey"
          },
          {
            "name": "previous",
            "type": "pubkey"
          },
          {
            "name": "recoveryOwner",
            "type": "pubkey"
          },
          {
            "name": "configNonce",
            "type": "u64"
          }
        ]
      }
    },
    {
      "name": "recoveryPaused",
      "type": {
        "kind": "struct",
        "fields": [
          {
            "name": "vault",
            "type": "pubkey"
          },
          {
            "name": "intentDigest",
            "type": {
              "array": [
                "u8",
                32
              ]
            }
          }
        ]
      }
    },
    {
      "name": "recoveryRegistered",
      "type": {
        "kind": "struct",
        "fields": [
          {
            "name": "vault",
            "type": "pubkey"
          },
          {
            "name": "recoveryOwner",
            "type": "pubkey"
          },
          {
            "name": "epoch",
            "type": "u64"
          }
        ]
      }
    },
    {
      "name": "recoveryResumed",
      "type": {
        "kind": "struct",
        "fields": [
          {
            "name": "vault",
            "type": "pubkey"
          },
          {
            "name": "intentDigest",
            "type": {
              "array": [
                "u8",
                32
              ]
            }
          }
        ]
      }
    },
    {
      "name": "vault",
      "docs": [
        "A vault, its recovery configuration, and its one in-flight attempt.",
        "",
        "**The attempt is a field here, not a separate PDA.** It is fixed-size, so embedding it makes",
        "\"one attempt at a time\" structural rather than checked, costs no extra rent, and avoids",
        "`init_if_needed` — which is a reinitialization footgun and would be the only way to reopen a",
        "per-attempt account.",
        "",
        "`epoch`, `nonce` and `attempt_seq` live beside the attempt but are **never cleared with it**.",
        "They are replay-protection state: zeroing them when an attempt ends would make every previously",
        "signed intent and every banked resume endorsement valid again. `RecoveryModule` keeps the same",
        "separation across `onUninstall`, and for the same reason."
      ],
      "type": {
        "kind": "struct",
        "fields": [
          {
            "name": "creator",
            "docs": [
              "Immutable, and in the PDA seeds. Distinct from `owner` on purpose: the seeds must not move",
              "when a recovery rotates the owner, or the vault's address would change and every seal",
              "derived against it would be orphaned — `accountId` is a KDF input in the SDK."
            ],
            "type": "pubkey"
          },
          {
            "name": "vaultId",
            "type": {
              "array": [
                "u8",
                16
              ]
            }
          },
          {
            "name": "owner",
            "docs": [
              "Rotated by a completed recovery. The only key that can move value."
            ],
            "type": "pubkey"
          },
          {
            "name": "recoveryOwner",
            "docs": [
              "`rk_pk`. An ed25519 recovery key *is* a Solana address, so this is the derived key itself",
              "rather than a hash or an address derived from one."
            ],
            "type": "pubkey"
          },
          {
            "name": "epoch",
            "docs": [
              "Bumped on every completed recovery, invalidating every prior-epoch intent."
            ],
            "type": "u64"
          },
          {
            "name": "nonce",
            "docs": [
              "Bumped on every completed *and every aborted* recovery, so an aborted intent's signature",
              "cannot reopen the attempt."
            ],
            "type": "u64"
          },
          {
            "name": "attemptSeq",
            "docs": [
              "Bumped on every `initiate_recovery` *and every `pause`*, folded into the resume digest, so a",
              "resume endorsement lifts exactly one pause."
            ],
            "type": "u64"
          },
          {
            "name": "configNonce",
            "docs": [
              "Bumped on every `register`, folded into the registration digest.",
              "",
              "Registration is re-callable — a recovery key is rotated, not fixed for life — so a",
              "registration signature must be spendable exactly once. Without this counter the digest for",
              "(owner, recovery_owner, veto) is constant, and an old signature could be replayed to revert",
              "a rotation: back to a key the owner had just decided to stop trusting, which is the one",
              "direction that must never be possible. `RecoveryModule`'s `attempt_seq` guards resume",
              "endorsements the same way."
            ],
            "type": "u64"
          },
          {
            "name": "veto",
            "type": {
              "defined": {
                "name": "vetoConfigAccount"
              }
            }
          },
          {
            "name": "attempt",
            "type": {
              "defined": {
                "name": "attemptAccount"
              }
            }
          },
          {
            "name": "intentDigest",
            "docs": [
              "The intent this attempt was opened for. Zero when no attempt is open."
            ],
            "type": {
              "array": [
                "u8",
                32
              ]
            }
          },
          {
            "name": "registered",
            "docs": [
              "False until `register` has bound a recovery key and a veto configuration."
            ],
            "type": "bool"
          },
          {
            "name": "bump",
            "type": "u8"
          },
          {
            "name": "solBump",
            "docs": [
              "Bump for the lamport-holding PDA, so `execute_transfer` can sign for it."
            ],
            "type": "u8"
          }
        ]
      }
    },
    {
      "name": "vaultCreated",
      "type": {
        "kind": "struct",
        "fields": [
          {
            "name": "vault",
            "type": "pubkey"
          },
          {
            "name": "creator",
            "type": "pubkey"
          },
          {
            "name": "owner",
            "type": "pubkey"
          }
        ]
      }
    },
    {
      "name": "vetoConfigAccount",
      "docs": [
        "The veto configuration, as the account stores it.",
        "",
        "Mirrors `gradual_veto::Config` with `Pubkey` in place of `[u8; 32]`. The state machine crate",
        "keeps no Solana dependency so it stays testable without a validator, so the conversion happens",
        "here — at the one boundary, rather than being smeared across the instruction handlers."
      ],
      "type": {
        "kind": "struct",
        "fields": [
          {
            "name": "pauseAuthority",
            "type": "pubkey"
          },
          {
            "name": "abortAuthority",
            "type": "pubkey"
          },
          {
            "name": "resumeMembers",
            "type": {
              "vec": "pubkey"
            }
          },
          {
            "name": "resumeThreshold",
            "type": "u8"
          },
          {
            "name": "timelockSeconds",
            "type": "u64"
          },
          {
            "name": "pauseCeilingSeconds",
            "type": "u64"
          }
        ]
      }
    }
  ]
};
