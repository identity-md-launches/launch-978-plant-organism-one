# Oracle wire format

Use the full `OracleAttestation.Attestation` in `src/OracleAttestation.sol`, copied from the supplied protocol library. Its EIP-712 type is:

```text
OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint16 panelSize,uint16 quorum,uint16 agreed,uint64 issuedAt,uint64 expiresAt)
```

Domain: name `IdentityMD Oracle`, version `2`, chain ID `4663`, verifying contract **the deployed PlantOrganism**. The contract computes the domain using the execution chain and refuses bound settlement on a chain other than 4663. `attestationDigest(a)` exposes the digest. EOA signatures are 65-byte `r || s || v`, with `v` 27/28 and canonical low `s`. No ERC-1271 callback is used. `issuedAt <= block.timestamp <= expiresAt` is exact, as required by the brief; the generic reference consumer's five-minute future tolerance does not apply. If the block clock lags the attester, the relayer must wait until `issuedAt` and resubmit before `expiresAt`.

`a.chainId` must also be 4663 and `a.questionHash` must equal the once-bound `QUESTION_HASH`. `a.answerType` is **5**. `a.answer` must be canonical `abi.encode(bytes32[])` for exactly three entries: offset 32, length 3, then 96 bytes of words (160 bytes altogether). A fixed-size array encoding is not interchangeable.

| Word | Bits | Meaning |
| --- | --- | --- |
| 0 | 0–23 | Sun, hour 0 in bit 0 |
| 0 | 24–47 | Rain, hour 0 in bit 24 |
| 0 | 48 | Challenger validity |
| 0 | 64–95 | Challenger cell |
| 0 | 96–127 | Unix day index |
| 1–2 | all | Temperature and wind payloads, emitted unchanged |

Unused bits in word 0 are ignored. `Settled.sips` counts sunny hours that consume water (0–24), including those where integer `pot / 10` is zero. The contract does not infer a temperature/wind schema beyond the brief. The frozen question must define those encodings, weather sources, sun/rain classification, candidate validity, and daily observation timing before binding. Settlement requires `agreed >= quorum`; a signature on a below-quorum answer cannot settle weather. The frozen question must fix the requested panel size and quorum, and the signer remains responsible for enforcing those values; no separate numeric minimum is invented on chain. A valid flag on a malformed/out-of-range cell cannot move the organism.

Example caller after obtaining `a` and the oracle signature:

```solidity
PlantOrganism(organismAddress).settle(a, signature);
```

Each day can settle once because the signed day must advance the cursor by exactly one. Request IDs are metadata rather than replay keys; a signature cannot be reused for another day. The first required day is the day after deployment (or after the last unbound cursor advance). Binding starts a fresh 30-day death clock but preserves the cursor; call unbound `settle` just before binding to skip days spent waiting for the second launch, otherwise those days still require in-order attestations. A signed current day is allowed; production operators should submit only when the frozen question's complete daily weather is available. Backlogged days use the location and parking state at execution; pending parking activates after the first successful catch-up settlement. No historic token balance reconstruction is claimed.

Obtain the signature with this contract as consumer, then relay directly. This contract does not purchase answers or implement the Intake's callback. In particular, the protocol's 200,000-gas delivery callback stipend is insufficient for the full settlement budget. The relayer should estimate gas and maintain liveness within 30 days of the last success. The deployer must verify the frozen canonical question hash with the oracle service before binding; a service that changes the question document/window hash each day is incompatible with the brief's immutable hash unless it supports the agreed frozen question.

Rotation uses the same v2 domain and this exact type:

```text
RotateSigner(address organism,address newSigner,uint256 nonce)
```

The message names this organism, the new nonzero address, and the current `rotationNonce()`. Sign `rotationDigest(newSigner)` with the **current** key and relay `rotateSigner(newSigner, sig)`. The nonce increments atomically, preventing replay even if keys later rotate back. There is no expiry field or successor acknowledgement in this API: the authorization remains usable until a rotation advances its nonce, and the new key takes rotation authority immediately. Before signing, key operators must verify the successor address and control of its key off chain; losing that key cannot be repaired by the retired key or an administrator. Avoid unused pre-signed authorizations; another valid rotation is needed to invalidate their nonce. Each retired key's independent `signerValidUntil` is inclusive at the 30-day boundary; rapid rotations do not shorten earlier keys' promised grace. Key operators must account for that grace before discarding keys or treating a compromised key as revoked.
