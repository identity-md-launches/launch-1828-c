# CardVault test suite

These tests extend the accepted implementation without changing application code or configuration. Run from the repository root:

```sh
forge build
FOUNDRY_FUZZ_SEED=0xa99e62958597bb59a9e282d986a3db72f02d663f4b0c643629d7eba2336756d3 forge test
```

The default suite is offline. It uses the repository's existing Solidity dependencies and local Intake/payment/signature mocks. No package installation, FFI, signing account, or environment mutation is required. Fuzz and invariant settings are inline in the test files.

## Added coverage

| File | Main checks |
| --- | --- |
| `CardAdminEdges.t.sol` | Zero constructor inputs, replacement of an ownership nominee, authority before acceptance, guardian rotation, repeated pause/unpause |
| `CardOracleAdversarial.t.sol` | All 15 signed fields, chain domain separation, malformed/high-S signatures, signer rotation and ERC-1271 failures, invalid signed fields, exact deadline settlement, UUID replay across classes, relay collisions, old callbacks after replacement, fee/allowance failures, duplicate/zero Intake IDs, admin access |
| `CardLendingEdges.t.sol` | Tiny origination fees, maximum USD scaling/LTV, dependency mismatch, rollback on failed draws/extensions/purchases, exact maturity, terminal loan states, auction rounding, surplus authorization, exact guard rejection for six reentrant value paths |
| `CardPoolEdges.t.sol` | Invalid debt hooks, failed funding/deposits, donation-induced dust, delegated redemptions, reserve isolation, repeated round trips, executable exit quotes under utilisation |
| `CardRevisionEdges.t.sol` | Edges of the revised implementation: guardian seat set during a pending nomination, nominee already seated as guardian, renewal APR cap at the exact rate and one point below, LTV on principal after interest is paid, one-second interest on a one-unit loan rounding up, aggregate-versus-per-loan interest rounding, the auction mark at every phase boundary (last par second, first descent second, midpoint, floor, last marked second, write-off), repayment and sale after write-off leaving an empty book, out-of-order closure of a staggered auction pair, and a future `issuedAt` inside the five-minute tolerance that settles but cannot be borrowed against until the clock catches up |
| `CardSettlementEdges.t.sol` | Edges of the NAV-neutral settlement: purchase at par, mid-descent, and during the linear write-down; the branch where counted cover is released because no shortfall survives; fees and one-unit donations reserved after a loss covering only later mark-downs; the rounding unit an extension holds back; liquidation moving NAV by at most one unit; the held-back recovery that no lender can withdraw; fuzzed sandwiches of purchases and repayments in every phase; NAV never rising and counted cover never falling with time alone |
| `CardCatalogEdges.t.sol` | Every NFT metadata field, certificate rollback after rejected safe mint, class separation, all template label fields, slug injection, JSON parsing of generated catalog text |
| `invariant/CardVault.invariant.t.sol` | Pool, USDC, shares, loans, NFT custody, reserves, surplus, and exit liveness over random economic sequences |
| `invariant/CardOracle.invariant.t.sol` | Pending/settled state, fees, cached prices, relay bindings, replay protection, timeout, configuration rotation, and donated IMD over random sequences |
| `SepoliaFork.t.sol` | Optional live-code request integration and borrowing against an already delivered live quote |

The existing unit tests, canonical protocol vector in `OracleConformance.t.sol`, and local end-to-end smoke-script tests remain part of the suite. The new arithmetic and structured-input fuzz tests each run 1,000 cases.

## Stateful properties and their models

The vault campaign runs **256 sequences of 96 calls** with four actors and twelve pre-minted cards. Its handler calls the actual five applications. Only the external Intake and test IMD are stand-ins. Random actions include deposits/mints, withdrawals/redemptions, transfers, donations/reserve funding, borrowing, extension, repayment, liquidation, purchase, claims, time progression, APR changes, pausing, immediate round trips, and sandwiched settlements (a deposit, a purchase or repayment of any loan in any phase, and a full redemption by the same actor in one block).

Cash-flow ghosts independently accumulate actual operation inputs: deposits, withdrawals, net loan disbursements, repayments, auction payments, reserve fees/funding, reserve spent on losses, recoveries held back as reserve, and borrower surplus. After every action the invariant checks:

- Pool cash equals tracked inflows minus outflows; reserve cash is fully backed and equals fees plus funding plus held-back recoveries minus loss coverage.
- Every settlement (repayment, extension, purchase, sandwiched or not) leaves `totalAssets()` exactly unchanged, hands the pool exactly its payment, collects at least the receivable it releases, spends at most the reserve the pool counted as cover before the call, holds back at most the recovery above the released mark, and leaves every lender's redeemable claim unchanged. A sandwiching actor ends with at most their balance less the settlement's cost.
- Draws and reserve funding move no NAV and do not change the counted reserve; opening an auction moves NAV by at most one rounding unit of interest; time alone lifts NAV by at most the interest accrued and lowers it by at most the mark-down, with the counted reserve never falling.
- USDC balances sum to the known minted supply; shares sum to tracked lender balances.
- Principal, rate weights, and frozen debt equal the sums over outstanding loans. Aggregate interest is the summed per-loan accrual numerator rounded up once; it never exceeds the sum of individually rounded-up loan debts, and falls short of it by at most one unit per extra active loan.
- Every auction loan's mark is independently recomputed as min(frozen debt, current Dutch quote) for the first day, then a straight line from half the debt to zero over the second day, and zero afterwards; it never exceeds the sale price. The receivable the book reports never exceeds the sum of those marks and is within one unit per extra descending or decaying auction of it; marks plus expected shortfall partition the frozen debt; quotes are at or above debt through the last par second and at or below it afterwards.
- Pool NAV equals unreserved cash plus the receivable plus the counted reserve, where the counted reserve never exceeds the reserve or the expected shortfall; NAV never exceeds the par value and never falls below cash plus marks. Materialising the lazy book with `syncAuctions` changes nothing the projection already reported. These are accounting properties, not a promise that illiquid collateral will cover its debt.
- Every renewal is first attempted with a cap one point below the live rate and must be refused without touching the loan; price-based liquidation uses the largest whole-dollar quote that still leaves debt above 60%, since zero is no longer a valuation.
- Every outstanding loan has its unique NFT in custody; released cards follow the borrower or auction receiver, and closed loan IDs stay closed.
- Surplus credits match both their aggregate and the lending contract's cash; pool settlement leaves no token allowance.

After each random sequence, `afterInvariant` pays off every remaining loan, claims every surplus, and executes each lender's advertised maximum withdrawal. The handler funds the payer through authorized mock minting only if necessary, tracks that extra supply, and checks that no debt, interest accumulator, collateral, or surplus remains stranded. This tests exits while pauses and arbitrary earlier operations remain in effect.

The oracle campaign runs **256 sequences of 64 calls** with three classes, three payers, and two Intake contracts. It maintains an independent outcome model for every opened request and price cache. Every sequence checks fee conservation, zero residual allowances, single settlement, UUID consumption only on successful delivery, immutable per-request Intake/class identity, unchanged prices on failure/timeout, and preservation of donated IMD. Rotation tests use the request's original observation chain and panel requirements. A dedicated action delivers a correctly signed zero or oversize dollar figure through both the callback and the relay and checks that it is refused, leaves the request open, and does not consume the UUID; delivered prices are drawn from one dollar upward because zero is now refused by design.

Both campaigns explicitly select handler actions and set `fail-on-revert = true`. Inputs are bounded to useful domains; state-dependent actions return when their prerequisites are absent. Expected negative paths use exact revert checks. Deterministic witness tests exercise the economic and request lifecycles so an unreachable handler cannot be hidden by a passing random campaign. The vault witness includes profitable and loss-making auction sales, extension, third-party repayment, claims, reserve use, and repeated rounding cycles.

The properties follow the supplied conservation, state-transition, round-trip, and non-vacuity guidance from the Pashov, Trail of Bits, and Ethereum testing references. They do not assume constant share price, constant supply for a mintable token, a fully funded reserve, or a permanently fresh oracle.

## Optional Sepolia forks and live callback run

`SepoliaFork.t.sol` skips cleanly when `CARDVAULT_SEPOLIA_RPC_URL` is absent. Supplying it enables `testFork_requestCharizardAgainstRealIntakeCode`, which checks actual code at:

| Dependency | Sepolia address |
| --- | --- |
| Intake v2 | `0xa43e6f75ee006411f79ac1c84120606c2330de82` |
| Test IMD | `0x44a1cd38474fb1748400e7deb5f8d786cce3f89a` |
| Oracle signer, from the supplied protocol reference | `0x5598aa9146215bc13eb26f2c692ad1461fd32982` |

That test deploys applications **inside the fork**, requests Charizard #4 / Pokemon Base Set / PSA 10 through the live Intake code, checks payment and pending state, and verifies borrowing is rejected without a quote. It never broadcasts; its locally created request cannot receive a subsequent service callback.

The second fork test uses an actual deployment and an existing fresh quote. In addition to the RPC URL, supply:

- `CARDVAULT_SEPOLIA_LENDING`: confirmed deployed CardLending address. If absent, this test also skips.
- `CARDVAULT_SEPOLIA_TOKEN_ID`: an unencumbered minted card from that deployment.
- `CARDVAULT_SEPOLIA_BORROW_AMOUNT`: gross amount in six-decimal USDC units, within the quote's 45% LTV and available pool cash.

```sh
forge test --match-contract SepoliaForkTest -vv
```

This second test neither writes a price nor impersonates the oracle. It reads the quote already stored on Sepolia, impersonates the NFT holder only within the fork, and checks the resulting debt, net payout, and custody. Configured but invalid deployment inputs fail rather than silently skip.

For a genuinely paid, live request followed by a real callback, use the existing `script/SepoliaSmoke.s.sol` configure/open/finish phases and the root README's runbook. Adding a card class requires matching the NFT metadata's computed `classId` to a reviewed PriceCharting template, running the existing request-body checker before payment, minting a unique certificate, requesting a price, and waiting for real delivery before borrowing. Confirmed application addresses come from the launch handoff; this test assignment deploys no applications on Sepolia.

## Validation limits

`forge build` succeeded. The full suite with the specified seed finished with **164 passed, 0 failed, 2 skipped**, including **40,960 randomized handler calls** and the end-of-sequence exit checks; the invariant campaigns also pass under a second seed. This revision retargeted the suite at the implementation's latest revision, which answered the previous round's sandwich finding: the four-argument `settle`, the linear write-down of an unsold auction from half its debt to zero over the second day, the counted-reserve checkpoint, and NAV-neutral settlement with recoveries above the mark held back as reserve. The earlier expectations that a floor sale after write-off was a gain, that a fee or donation lifted NAV where it newly covered a shortfall, and that the reserve equalled funding minus coverage were replaced by the properties listed above; the repository's `floorMark`/`floorHead` accessors were renamed `decayDebt`/`decayWeight`/`decayHead` and the tests follow.

The previous round's finding (a written-off loan's floor sale lifting NAV in one step so a same-block deposit/redeem took part of the recovery) is fixed: the reproduction now costs the sandwicher the full price, and that is asserted in every phase by unit, fuzz and invariant tests. No new defect with a failing input was found in the revised code. One design consequence is recorded as an informational note in `.imd-findings.json` rather than asserted as desirable: recoveries above the mark and reserve added after a loss stay in the reserve with no release path, so lenders who carried a write-down never receive a later floor sale of that loan unless another auction marks down while they are still invested. The suite asserts the behaviour as implemented and documented (`test_heldBackReserveIsNeverLenderCashAndHasNoRelease`) because it is the stated design and the fix for the earlier finding, not a correctness defect. Two one-base-unit effects remain and are bounded by the tests rather than reported: opening an auction can lift NAV by one unit of rounded interest, and a phase change of the aggregate book can move the mark by one unit. The optional forks and a live paid-request/callback/borrow sequence have not been executed in this assignment. The generated-JSON checks validate structure and escaping; they do not replace the live `POST /requests/check` screen or prove that PriceCharting can answer a particular question. Existing recorded preflight responses remain in `docs/`.

Coverage instrumentation was exploratory: ordinary `forge coverage` encountered a stack-depth compiler error; `forge coverage --ir-minimum` produced a local LCOV report but failed the existing bytecode-size check because that mode changes optimization and runtime size. The normal configured build and its bytecode-size test pass. No application or configuration was changed to accommodate coverage instrumentation.

The protected constructor/opcode checks were read as inputs; their launch-specific environment is supplied by the verifier. Files under `test/scratch/` are disposable local logs/scaffolding and are not required by any delivered test.
