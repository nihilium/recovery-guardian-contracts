/**
 * GENERATED FILE — do not edit.
 *
 * Produced by `bindings/generate-abi.mjs` from the Forge build in `out/`. Regenerate with
 * `npm run build:sol && npm run build:abi` in this package.
 */

/** ABI of `RecoveryModule`, from the Forge build artifact. */
export const recoveryModuleAbi = [
    {
        "type": "function",
        "name": "abort",
        "inputs": [
            {
                "name": "account",
                "type": "address",
                "internalType": "address"
            }
        ],
        "outputs": [],
        "stateMutability": "nonpayable"
    },
    {
        "type": "function",
        "name": "attemptOf",
        "inputs": [
            {
                "name": "account",
                "type": "address",
                "internalType": "address"
            }
        ],
        "outputs": [
            {
                "name": "",
                "type": "bytes32",
                "internalType": "bytes32"
            },
            {
                "name": "",
                "type": "tuple",
                "internalType": "struct GradualVeto.Attempt",
                "components": [
                    {
                        "name": "state",
                        "type": "uint8",
                        "internalType": "enum GradualVeto.State"
                    },
                    {
                        "name": "accruedSeconds",
                        "type": "uint64",
                        "internalType": "uint64"
                    },
                    {
                        "name": "pausedSeconds",
                        "type": "uint64",
                        "internalType": "uint64"
                    },
                    {
                        "name": "checkpointTime",
                        "type": "uint64",
                        "internalType": "uint64"
                    }
                ]
            }
        ],
        "stateMutability": "view"
    },
    {
        "type": "function",
        "name": "configOf",
        "inputs": [
            {
                "name": "account",
                "type": "address",
                "internalType": "address"
            }
        ],
        "outputs": [
            {
                "name": "recoveryOwner",
                "type": "address",
                "internalType": "address"
            },
            {
                "name": "epoch",
                "type": "uint256",
                "internalType": "uint256"
            },
            {
                "name": "nonce",
                "type": "uint256",
                "internalType": "uint256"
            },
            {
                "name": "veto",
                "type": "tuple",
                "internalType": "struct GradualVeto.Config",
                "components": [
                    {
                        "name": "pauseAuthority",
                        "type": "address",
                        "internalType": "address"
                    },
                    {
                        "name": "abortAuthority",
                        "type": "address",
                        "internalType": "address"
                    },
                    {
                        "name": "resumeMembers",
                        "type": "address[]",
                        "internalType": "address[]"
                    },
                    {
                        "name": "resumeThreshold",
                        "type": "uint8",
                        "internalType": "uint8"
                    },
                    {
                        "name": "timelockSeconds",
                        "type": "uint64",
                        "internalType": "uint64"
                    },
                    {
                        "name": "pauseCeilingSeconds",
                        "type": "uint64",
                        "internalType": "uint64"
                    }
                ]
            }
        ],
        "stateMutability": "view"
    },
    {
        "type": "function",
        "name": "executeRecovery",
        "inputs": [
            {
                "name": "intent",
                "type": "tuple",
                "internalType": "struct RecoveryModule.Intent",
                "components": [
                    {
                        "name": "account",
                        "type": "address",
                        "internalType": "address"
                    },
                    {
                        "name": "epoch",
                        "type": "uint256",
                        "internalType": "uint256"
                    },
                    {
                        "name": "nonce",
                        "type": "uint256",
                        "internalType": "uint256"
                    },
                    {
                        "name": "newValidator",
                        "type": "address",
                        "internalType": "address"
                    },
                    {
                        "name": "newValidatorInitData",
                        "type": "bytes",
                        "internalType": "bytes"
                    },
                    {
                        "name": "expiry",
                        "type": "uint48",
                        "internalType": "uint48"
                    }
                ]
            }
        ],
        "outputs": [],
        "stateMutability": "nonpayable"
    },
    {
        "type": "function",
        "name": "hashIntent",
        "inputs": [
            {
                "name": "intent",
                "type": "tuple",
                "internalType": "struct RecoveryModule.Intent",
                "components": [
                    {
                        "name": "account",
                        "type": "address",
                        "internalType": "address"
                    },
                    {
                        "name": "epoch",
                        "type": "uint256",
                        "internalType": "uint256"
                    },
                    {
                        "name": "nonce",
                        "type": "uint256",
                        "internalType": "uint256"
                    },
                    {
                        "name": "newValidator",
                        "type": "address",
                        "internalType": "address"
                    },
                    {
                        "name": "newValidatorInitData",
                        "type": "bytes",
                        "internalType": "bytes"
                    },
                    {
                        "name": "expiry",
                        "type": "uint48",
                        "internalType": "uint48"
                    }
                ]
            }
        ],
        "outputs": [
            {
                "name": "",
                "type": "bytes32",
                "internalType": "bytes32"
            }
        ],
        "stateMutability": "view"
    },
    {
        "type": "function",
        "name": "initiateRecovery",
        "inputs": [
            {
                "name": "intent",
                "type": "tuple",
                "internalType": "struct RecoveryModule.Intent",
                "components": [
                    {
                        "name": "account",
                        "type": "address",
                        "internalType": "address"
                    },
                    {
                        "name": "epoch",
                        "type": "uint256",
                        "internalType": "uint256"
                    },
                    {
                        "name": "nonce",
                        "type": "uint256",
                        "internalType": "uint256"
                    },
                    {
                        "name": "newValidator",
                        "type": "address",
                        "internalType": "address"
                    },
                    {
                        "name": "newValidatorInitData",
                        "type": "bytes",
                        "internalType": "bytes"
                    },
                    {
                        "name": "expiry",
                        "type": "uint48",
                        "internalType": "uint48"
                    }
                ]
            },
            {
                "name": "signature",
                "type": "bytes",
                "internalType": "bytes"
            }
        ],
        "outputs": [],
        "stateMutability": "nonpayable"
    },
    {
        "type": "function",
        "name": "isInitialized",
        "inputs": [
            {
                "name": "account",
                "type": "address",
                "internalType": "address"
            }
        ],
        "outputs": [
            {
                "name": "",
                "type": "bool",
                "internalType": "bool"
            }
        ],
        "stateMutability": "view"
    },
    {
        "type": "function",
        "name": "isModuleType",
        "inputs": [
            {
                "name": "typeID",
                "type": "uint256",
                "internalType": "uint256"
            }
        ],
        "outputs": [
            {
                "name": "",
                "type": "bool",
                "internalType": "bool"
            }
        ],
        "stateMutability": "pure"
    },
    {
        "type": "function",
        "name": "name",
        "inputs": [],
        "outputs": [
            {
                "name": "",
                "type": "string",
                "internalType": "string"
            }
        ],
        "stateMutability": "pure"
    },
    {
        "type": "function",
        "name": "onInstall",
        "inputs": [
            {
                "name": "data",
                "type": "bytes",
                "internalType": "bytes"
            }
        ],
        "outputs": [],
        "stateMutability": "nonpayable"
    },
    {
        "type": "function",
        "name": "onUninstall",
        "inputs": [
            {
                "name": "",
                "type": "bytes",
                "internalType": "bytes"
            }
        ],
        "outputs": [],
        "stateMutability": "nonpayable"
    },
    {
        "type": "function",
        "name": "pause",
        "inputs": [
            {
                "name": "account",
                "type": "address",
                "internalType": "address"
            }
        ],
        "outputs": [],
        "stateMutability": "nonpayable"
    },
    {
        "type": "function",
        "name": "resume",
        "inputs": [
            {
                "name": "account",
                "type": "address",
                "internalType": "address"
            },
            {
                "name": "signers",
                "type": "address[]",
                "internalType": "address[]"
            },
            {
                "name": "signatures",
                "type": "bytes[]",
                "internalType": "bytes[]"
            }
        ],
        "outputs": [],
        "stateMutability": "nonpayable"
    },
    {
        "type": "function",
        "name": "resumeDigest",
        "inputs": [
            {
                "name": "account",
                "type": "address",
                "internalType": "address"
            },
            {
                "name": "intentHash",
                "type": "bytes32",
                "internalType": "bytes32"
            }
        ],
        "outputs": [
            {
                "name": "",
                "type": "bytes32",
                "internalType": "bytes32"
            }
        ],
        "stateMutability": "view"
    },
    {
        "type": "function",
        "name": "stateOf",
        "inputs": [
            {
                "name": "account",
                "type": "address",
                "internalType": "address"
            }
        ],
        "outputs": [
            {
                "name": "",
                "type": "uint8",
                "internalType": "enum GradualVeto.State"
            }
        ],
        "stateMutability": "view"
    },
    {
        "type": "function",
        "name": "version",
        "inputs": [],
        "outputs": [
            {
                "name": "",
                "type": "string",
                "internalType": "string"
            }
        ],
        "stateMutability": "pure"
    },
    {
        "type": "event",
        "name": "RecoveryAborted",
        "inputs": [
            {
                "name": "account",
                "type": "address",
                "indexed": true,
                "internalType": "address"
            },
            {
                "name": "intentHash",
                "type": "bytes32",
                "indexed": true,
                "internalType": "bytes32"
            }
        ],
        "anonymous": false
    },
    {
        "type": "event",
        "name": "RecoveryExecuted",
        "inputs": [
            {
                "name": "account",
                "type": "address",
                "indexed": true,
                "internalType": "address"
            },
            {
                "name": "intentHash",
                "type": "bytes32",
                "indexed": true,
                "internalType": "bytes32"
            },
            {
                "name": "newEpoch",
                "type": "uint256",
                "indexed": false,
                "internalType": "uint256"
            }
        ],
        "anonymous": false
    },
    {
        "type": "event",
        "name": "RecoveryInitiated",
        "inputs": [
            {
                "name": "account",
                "type": "address",
                "indexed": true,
                "internalType": "address"
            },
            {
                "name": "intentHash",
                "type": "bytes32",
                "indexed": true,
                "internalType": "bytes32"
            },
            {
                "name": "epoch",
                "type": "uint256",
                "indexed": false,
                "internalType": "uint256"
            }
        ],
        "anonymous": false
    },
    {
        "type": "event",
        "name": "RecoveryPaused",
        "inputs": [
            {
                "name": "account",
                "type": "address",
                "indexed": true,
                "internalType": "address"
            },
            {
                "name": "intentHash",
                "type": "bytes32",
                "indexed": true,
                "internalType": "bytes32"
            }
        ],
        "anonymous": false
    },
    {
        "type": "event",
        "name": "RecoveryRegistered",
        "inputs": [
            {
                "name": "account",
                "type": "address",
                "indexed": true,
                "internalType": "address"
            },
            {
                "name": "recoveryOwner",
                "type": "address",
                "indexed": true,
                "internalType": "address"
            },
            {
                "name": "epoch",
                "type": "uint256",
                "indexed": false,
                "internalType": "uint256"
            }
        ],
        "anonymous": false
    },
    {
        "type": "event",
        "name": "RecoveryResumed",
        "inputs": [
            {
                "name": "account",
                "type": "address",
                "indexed": true,
                "internalType": "address"
            },
            {
                "name": "intentHash",
                "type": "bytes32",
                "indexed": true,
                "internalType": "bytes32"
            }
        ],
        "anonymous": false
    },
    {
        "type": "error",
        "name": "AlreadyInstalled",
        "inputs": [
            {
                "name": "account",
                "type": "address",
                "internalType": "address"
            }
        ]
    },
    {
        "type": "error",
        "name": "AlreadyTerminal",
        "inputs": []
    },
    {
        "type": "error",
        "name": "AttemptInFlight",
        "inputs": [
            {
                "name": "account",
                "type": "address",
                "internalType": "address"
            }
        ]
    },
    {
        "type": "error",
        "name": "BadSignature",
        "inputs": []
    },
    {
        "type": "error",
        "name": "DuplicateResumeSigner",
        "inputs": [
            {
                "name": "signer",
                "type": "address",
                "internalType": "address"
            }
        ]
    },
    {
        "type": "error",
        "name": "IntentExpired",
        "inputs": []
    },
    {
        "type": "error",
        "name": "InvalidConfig",
        "inputs": [
            {
                "name": "reason",
                "type": "string",
                "internalType": "string"
            }
        ]
    },
    {
        "type": "error",
        "name": "ModuleAlreadyInitialized",
        "inputs": [
            {
                "name": "smartAccount",
                "type": "address",
                "internalType": "address"
            }
        ]
    },
    {
        "type": "error",
        "name": "NoAttempt",
        "inputs": [
            {
                "name": "account",
                "type": "address",
                "internalType": "address"
            }
        ]
    },
    {
        "type": "error",
        "name": "NotAbortAuthority",
        "inputs": []
    },
    {
        "type": "error",
        "name": "NotExecutable",
        "inputs": []
    },
    {
        "type": "error",
        "name": "NotInitialized",
        "inputs": [
            {
                "name": "smartAccount",
                "type": "address",
                "internalType": "address"
            }
        ]
    },
    {
        "type": "error",
        "name": "NotInitiated",
        "inputs": []
    },
    {
        "type": "error",
        "name": "NotInstalled",
        "inputs": [
            {
                "name": "account",
                "type": "address",
                "internalType": "address"
            }
        ]
    },
    {
        "type": "error",
        "name": "NotPauseAuthority",
        "inputs": []
    },
    {
        "type": "error",
        "name": "NotPaused",
        "inputs": []
    },
    {
        "type": "error",
        "name": "NotResumeQuorum",
        "inputs": []
    },
    {
        "type": "error",
        "name": "UnknownIntent",
        "inputs": []
    },
    {
        "type": "error",
        "name": "WrongAccount",
        "inputs": []
    },
    {
        "type": "error",
        "name": "WrongEpoch",
        "inputs": [
            {
                "name": "expected",
                "type": "uint256",
                "internalType": "uint256"
            },
            {
                "name": "supplied",
                "type": "uint256",
                "internalType": "uint256"
            }
        ]
    },
    {
        "type": "error",
        "name": "WrongNonce",
        "inputs": [
            {
                "name": "expected",
                "type": "uint256",
                "internalType": "uint256"
            },
            {
                "name": "supplied",
                "type": "uint256",
                "internalType": "uint256"
            }
        ]
    },
    {
        "type": "error",
        "name": "ZeroValidator",
        "inputs": []
    }
] as const;

/** ABI of `GradualVeto`, from the Forge build artifact. */
export const gradualVetoAbi = [
    {
        "type": "error",
        "name": "AlreadyTerminal",
        "inputs": []
    },
    {
        "type": "error",
        "name": "InvalidConfig",
        "inputs": [
            {
                "name": "reason",
                "type": "string",
                "internalType": "string"
            }
        ]
    },
    {
        "type": "error",
        "name": "NotExecutable",
        "inputs": []
    },
    {
        "type": "error",
        "name": "NotInitiated",
        "inputs": []
    },
    {
        "type": "error",
        "name": "NotPaused",
        "inputs": []
    }
] as const;
