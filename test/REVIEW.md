Reviewed starting commit `0f0b3c17ba4273b18d807de17bd2ff3479ed2a98` for the bounded tests assignment. All production contracts, dependencies and configuration remain unchanged. The added files are tests, test fixtures and this report. The explicitly requested findings report is `.imd-findings.json`.

The existing unit suite had 111 passing tests. This contribution adds 42 tests: boundary and failure scenarios, 11 fuzz properties, a stateful invariant campaign and a single-call deployment rehearsal. It builds on the existing fixtures and tests rather than replacing them.

| Added file | What it checks |
| --- | --- |
| `JudgeProperties.t.sol` | All 15 signed attestation fields; chain separation; malformed and malleable signatures; malformed booleans; panel minimums; exact deadlines; failed delivery followed by timeout; token pull rollback; one-wei and full-balance payments; canonical question hash vector. |
| `JudgeQuestionProperties.t.sol` | Generated ASCII through an independent JSON parser, every ASCII byte, maximum lengths and escaping, preserved printable evidence, delimiter isolation, body fields and size limits. |
| `JudgePaymentFailures.t.sol` | False-returning tokens at each transfer hop, failed approval, no-return tokens, allowance reset, and a reverting Intake. Failure must roll back balances, approvals and case/request counters. |
| `JudgeEthDoorProperties.t.sol` | Real v4 exact-output swaps, exact refunds, one wei below the quote, partial liquidity, reverted refunds and invalid text after a swap, forced ETH/token donations, nested refund calls. Pool balances and price must roll back on failure. |
| `JudgedAdversarial.t.sol` | Actual Judge/Intake/v4 calls through a funded inheritor: hostile refund and payout receivers, another completed case during reentry, recipient refusal and retry, other users' progress, budget conservation and beneficiary versus relayer. |
| `JudgeInvariant.t.sol`, `support/JudgeInvariantHandler.sol` | Four funded actors and a value-holding Judged inheritor over randomly ordered asks, price changes, time advances, answers, failures, bad callbacks, settlements and donations. |
| `LaunchBatch.t.sol` | Judge then JudgeEthDoor in a single helper call using the exact launch arguments, no live dependency code, no ETH at construction, correct dependency references and no additional constructor-created contracts. |

The five discovery passes from the supplied Pashov reference were applied directly to these contracts. The Trail of Bits reference informed the independent parser oracle, explicit edge examples and non-vacuity checks.

| Discovery pass | Property and source basis | Implementation |
| --- | --- | --- |
| 1. Conservation | `Judge.ask` (91–116) forwards one price; `JudgeEthDoor.ask/unlockCallback` (44–80) buys that output and refunds the rest; `Judged.ask` (54–84) preserves preexisting funds and the explicit stake. | Ghost accounting for actor ETH/tokens, successful fees, pool ETH, stakes, donations and payouts. Exact balance equalities after every action. |
| 2. Round trips and rounding | A completed swap plus refund must debit only actual cost. The serialized question must decode without changing its printable content or allowing new delimiters (`Judge.question/_plain`, 159–181 and 218–230). | Independent JSON parse round trips; prices down to one wei; quoted cost and cost minus one; nested refunds; full token balance payment. There are no vault shares or deposit/redemption conversions in these targets. |
| 3. State transitions | `Judge.caseCount/caseOfRequest` (74–77), callbacks (132–155), timeout (119–123), and `Judged.settle` (89–101) define consecutive cases and terminal outcomes with one hook execution. | Model of every opened case, independent expected outcomes, immutable request/hash/timestamp snapshots, and per-case hook counts. Rejected actions leave the model unchanged. |
| 4. Adversarial value extraction and liveness | Callback authorization (`Judge._open`, 184–188), spending bound (`JudgeEthDoor`, 74), and settlement/refund guards (`Judged`, 55, 81–83, 90–100). | Wrong sender/question/signature/panel, underfunding, refusing receivers, reentry, timeout and retry paths; funds reach the stored beneficiary even when someone else settles. |
| 5. Protocol-specific properties | Oracle EIP-712 domain and canonical vectors; one-shot Intake completion; signed panel minimums and unsigned failure semantics; v4 unlock/sync/settle/take. | Existing conformance tests retained; new canonical question vector, every signed-field mutation, real Intake fixture under its callback stipend, real PoolManager, failure and deadline transitions. |

The invariant campaign uses 256 runs of 64 calls, for 16,384 generated handler calls. Each actor starts with fixed ETH and token funds; the handler does not replenish them. The real PoolManager starts with bounded liquidity. Price changes stay between one wei and 0.5 tokens so a 64-call sequence remains liquid; separate unit tests exercise insufficient liquidity and exact spending boundaries. Donations are accounted for explicitly rather than assuming contract balances must always be zero.

Unexpected handler outcomes persist in a failure field checked by the invariant. Expected target reverts are caught and checked for rollback. No `vm.assume` or environment mutation is used. A deterministic witness drives every payment route, yes/no/failure/timeout outcomes and successful/repeated settlements to demonstrate that the harness can reach the important branches. The campaign completed with zero handler reverts and zero discarded inputs.

`OracleAttestation.sol` and `OracleQuestion.sol` exactly match the supplied canonical reference after trimming surrounding whitespace. The original independent digest/signature vectors are retained. Generated signatures use local fixture keys; the tests do not access any deployment key or claim to validate a real panel's factual judgment.

No critical or high defect was found in the reviewed paths. The informational finding in `.imd-findings.json` reproduces the already documented Ethereum integration gap in `Judged._judge()` at line 125. A minimal inheritor on chain 1 reverts in its constructor with `Judged: Judge isn't on this chain`. A standalone failing proof was executed under `test/scratch/` and its full source is embedded in the finding. Its executable file is not part of the submitted passing suite. The funded inheritor used by these tests explicitly points at the local Judge/door pair; completing production routing still needs the confirmed deployment addresses.

Other constraints remain part of the accepted design: the signer and Intake are trusted immutable dependencies, an unsigned failure never authorizes payment, a case can end without an answer, the ETH attached is the swap's spending bound, and inheritors choose their own payout rules. Review of the base class cannot establish the correctness of arbitrary inheritors. These tests exercise the original contracts with local dependencies; live dependency state and an actual oracle response are outside this offline test result.

Validation used Forge 1.8.5, the repository's Solidity 0.8.26 configuration, and the required seed `0xd17e95d28d14190cc2a1234655b6769019397b6ce3666166049ed3959122af0d`. Build artifacts and logs were directed into disposable `test/scratch/` to keep generated files within the assigned paths:

```sh
forge build --out test/scratch/out --cache-path test/scratch/cache
FOUNDRY_FUZZ_SEED=0xd17e95d28d14190cc2a1234655b6769019397b6ce3666166049ed3959122af0d forge test --no-match-path "test/fork/*" --out test/scratch/out --cache-path test/scratch/cache
FOUNDRY_FUZZ_SEED=0xd17e95d28d14190cc2a1234655b6769019397b6ce3666166049ed3959122af0d forge test --out test/scratch/out --cache-path test/scratch/cache
```

Unit result: **153 passed, 0 failed, 0 skipped**, including 10,256 fuzz cases and the invariant campaign. No dependency installation is required; every import resolves to ordinary files already in the repository.

`forge build` passes. The complete `forge test` run finishes with **153 passed, 0 failed, 2 skipped**. The two existing Ethereum/Sepolia fork tests skip because their `JUDGE_FORK_RPC_1` and `JUDGE_FORK_RPC_11155111` inputs are empty; no new test skips. This assignment names no pinned fork block, and the new suite requires no RPC. The supplied protected checks were read; their environment-dependent deployment setup is represented locally by the existing launch checks and the new single-call batch rehearsal.

Deployment status: **neither Judge nor JudgeEthDoor was broadcast by this tests assignment**. There are no confirmed deployed addresses to report from this work. The source and configuration match the starting commit; comparison of deployed runtime bytecode with that commit remains pending the actual launch. The local batch rehearsal uses the requested constructor arguments and order, and creates no additional application contracts.
