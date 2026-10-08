# PLANT test suite

Run `forge build` and `forge test` from the repository root. Everything uses vendored dependencies and local token/hook mocks; no network, keys, environment variables, FFI, or live deployment are needed. Fuzz counts and invariant settings live in the Solidity tests.

## Rules under test

IMD deposits enter the pot. Water starts at 50. Each settled day processes 24 weather bits: rain adds three water up to 100; otherwise sunshine consumes one water and one tenth of the remaining pot. Two thirds of each sip, plus rounding dust, become redemption backing. Gardeners behind the old location share the rest; if nobody is active there, it also becomes backing. Parking counts for movement immediately and begins earning after the next settlement. Unparking removes pending tokens first, then active tokens. Claims pay accumulated IMD without moving PLANT.

A valid challenger must beat the incumbent's support and reach 5% of the fixed supply. Birth starts nowhere, with no weather until a move; three empty settlements choose Lisbon. Live redemption pays 90% of proportional backing and keeps redeemed PLANT forever. After 30 days without a successful settlement, the pot becomes backing and redemption pays 100%, preserving gardener debts. The tests check that floor never falls and custody agrees with deposits, redemptions, donations, and payments.

Only the explicit deployer may bind the hook, token, and frozen question hash, once. Only a signature from the current oracle signer authorizes rotation; retired keys can attest for another 30 days. There is no administrator after binding.

## Calling settle

Obtain an IdentityMD Oracle v2 EIP-712 signature for chain **4663**, with the deployed organism as `verifyingContract`, then call `settle(attestation, signature)` from any account. Use the full 15-field `OracleAttestation.Attestation`, the bound question hash, `answerType = 5`, and `abi.encode(bytes32[])` containing exactly three words. In word 0, sun occupies bits 0–23, rain 24–47, challenger validity bit 48, cell 64–95, and Unix day 96–127. Words 1 and 2 carry temperature/wind data. The day must be `lastSettledDay + 1`, no later than today, and the signature must be within its validity window. The caller receives 1% of the remaining pot.

Launch inputs from the assignment: IMD `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127`; signer `0x5598aa9146215bc13eb26f2c692ad1461fd32982`; fallback `10223579` (`0x009BFFDB`, quarter-degrees `155, -37`); deployer `$owner`. The organism and second-launch PLANT/hook addresses are deployment outputs, not invented here. Test signers and holder addresses are confined to fixtures.

## Coverage and limits

| File | Purpose |
| --- | --- |
| `PlantOrganism.t.sol` | Existing weather, pending/active rewards, moves, death, authority, failure paths, and arithmetic fuzzing. |
| `OracleConformance.t.sol` | Unchanged published digest/signature vector and canonical settlement selector. |
| `PlantAdversarial.t.sol` | Transfer rollback, full signature-field authentication, all mutators' reentrancy guards, rounding edges, claim isolation, and rotation replay domains. |
| `PlantInvariant.t.sol` | Eager per-holder reward model, exact liabilities, conservation, floor, and complete reward exits. |
| `PlantLifecycleInvariant.t.sol` | Four holders, four cells including nowhere, 1,001 indivisible PLANT units, independent cash-flow/custody ledgers, birth/moves/death, signer rotation, donations, and full exits. |
| `PlantSettlementGas.t.sol` | Cold 24-sip settlement, fractional debt, activation, and movement with both one and 129 active holders, capped at 400,000 gas including intrinsic calldata cost. |

Each invariant runs 256 sequences of 96 calls, fails on unexpected reverts, and checks full exit afterward. A deterministic lifecycle scenario confirms that rewards, movement, rotation, and death are reachable. Fuzz properties run 1,000 cases each. Mocks cover exact, false-returning, no-return, fee-taking, and callback transfers. Live Robinhood token/hook behavior and oracle weather availability remain unverified by this offline suite; gas measurements use the local exact-transfer mock.
