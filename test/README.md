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
| `CardCatalogEdges.t.sol` | Every NFT metadata field, certificate rollback after rejected safe mint, class separation, all template label fields, slug injection, JSON parsing of generated catalog text |
| `invariant/CardVault.invariant.t.sol` | Pool, USDC, shares, loans, NFT custody, reserves, surplus, and exit liveness over random economic sequences |
| `invariant/CardOracle.invariant.t.sol` | Pending/settled state, fees, cached prices, relay bindings, replay protection, timeout, configuration rotation, and donated IMD over random sequences |
| `SepoliaFork.t.sol` | Optional live-code request integration and borrowing against an already delivered live quote |

The existing unit tests, canonical protocol vector in `OracleConformance.t.sol`, and local end-to-end smoke-script tests remain part of the suite. The new arithmetic and structured-input fuzz tests each run 1,000 cases.

## Stateful properties and their models

The vault campaign runs **256 sequences of 96 calls** with four actors and twelve pre-minted cards. Its handler calls the actual five applications. Only the external Intake and test IMD are stand-ins. Random actions include deposits/mints, withdrawals/redemptions, transfers, donations/reserve funding, borrowing, extension, repayment, liquidation, purchase, claims, time progression, APR changes, pausing, and immediate round trips.

Cash-flow ghosts independently accumulate actual operation inputs: deposits, withdrawals, net loan disbursements, repayments, auction payments, reserve fees/funding/loss coverage, and borrower surplus. After every action the invariant checks:

- Pool cash equals tracked inflows minus outflows; reserve cash is fully backed and equals funding minus loss coverage.
- USDC balances sum to the known minted supply; shares sum to tracked lender balances.
- Principal, rate weights, and frozen debt equal the sums over outstanding loans. Aggregate interest matches the exact per-loan accrual numerators; the difference from individually rounded debt is bounded by the number of active loans.
- Pool NAV is backed by unreserved cash and loan receivables. This is an accounting property, not a promise that illiquid collateral will cover its debt.
- Every outstanding loan has its unique NFT in custody; released cards follow the borrower or auction receiver, and closed loan IDs stay closed.
- Surplus credits match both their aggregate and the lending contract's cash; pool settlement leaves no token allowance.

After each random sequence, `afterInvariant` pays off every remaining loan, claims every surplus, and executes each lender's advertised maximum withdrawal. The handler funds the payer through authorized mock minting only if necessary, tracks that extra supply, and checks that no debt, interest accumulator, collateral, or surplus remains stranded. This tests exits while pauses and arbitrary earlier operations remain in effect.

The oracle campaign runs **256 sequences of 64 calls** with three classes, three payers, and two Intake contracts. It maintains an independent outcome model for every opened request and price cache. Every sequence checks fee conservation, zero residual allowances, single settlement, UUID consumption only on successful delivery, immutable per-request Intake/class identity, unchanged prices on failure/timeout, and preservation of donated IMD. Rotation tests use the request's original observation chain and panel requirements.

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

`forge build` succeeded. The full suite with the specified seed finished with **125 passed, 0 failed, 2 skipped**, including **40,960 randomized handler calls** and the end-of-sequence exit checks. No implementation defect was reproduced by these tests. The optional forks and a live paid-request/callback/borrow sequence have not been executed in this assignment. The generated-JSON checks validate structure and escaping; they do not replace the live `POST /requests/check` screen or prove that PriceCharting can answer a particular question. Existing recorded preflight responses remain in `docs/`.

Coverage instrumentation was exploratory: ordinary `forge coverage` encountered a stack-depth compiler error; `forge coverage --ir-minimum` produced a local LCOV report but failed the existing bytecode-size check because that mode changes optimization and runtime size. The normal configured build and its bytecode-size test pass. No application or configuration was changed to accommodate coverage instrumentation.

The protected constructor/opcode checks were read as inputs; their launch-specific environment is supplied by the verifier. Files under `test/scratch/` are disposable local logs/scaffolding and are not required by any delivered test.
