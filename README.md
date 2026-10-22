# CardVault

CardVault is a Sepolia lending prototype for mock vaulted trading-card NFTs. Five non-upgradeable application contracts are delivered, with vendored dependencies and offline Foundry tests. The owner is `0xd58dcd4594087c2758717a59f44a5ac09db65105`.

The application contracts have **not been broadcast from this worker**. The IdentityMD launch service deploys them after acceptance and supplies their confirmed addresses. No application addresses, successful live callback, or live borrowing transaction are claimed here. The supplied smoke script performs the real request and borrowing steps after deployment; its entire sequence is also exercised locally with a mock Intake and signed attestations.

## Build and checks

```sh
forge build
FOUNDRY_FUZZ_SEED=0xa99e62958597bb59a9e282d986a3db72f02d663f4b0c643629d7eba2336756d3 forge test
forge fmt --check
python3 -m unittest discover -s test -p 'test_*.py' -v
```

`foundry.toml` pins Solidity **0.8.26**, Cancun, optimizer 200 runs, and `bytecode_hash = "none"`. The same fuzz seed is pinned in configuration. No network, environment variables, FFI, filesystem cheatcode permissions, compiler binary, package installation, or submodule is required by the Solidity tests. Python helpers use only the standard library and Foundry's `cast`.

Dependencies are ordinary source files: OpenZeppelin Contracts v5.5.0 and forge-std v1.9.7. See [THIRD_PARTY.md](THIRD_PARTY.md). The canonical `OracleAttestation.sol` was copied from the supplied protocol reference without protocol changes. `src/base/USDC4626.sol` is a small, documented adaptation of OpenZeppelin's ERC-4626 that fixes the underlying decimals at six and removes its constructor's external metadata probe. This permits factory construction when dependency addresses have no code yet.

## Contracts and deployment inputs

Deploy in this order. `$owner` below denotes the **named owner above**, never the factory or transaction origin. This table is the handoff; it is not a launch manifest.

| Contract | Constructor arguments, in order | Purpose |
| --- | --- | --- |
| `MockUSDC` | `$owner` | Six-decimal test settlement token |
| `MockCardNFT` | `$owner` | Owner-issued ERC-721 cards |
| `CardPool` | `$owner`, deployed `MockUSDC` | ERC-4626 liquidity and segregated reserve |
| `CardOracle` | `$owner`, Sepolia Intake, Sepolia test IMD, oracle signer | Requests, signature verification, cached prices |
| `CardLending` | `$owner`, deployed `MockCardNFT`, deployed `CardPool`, deployed `CardOracle`, deployed `MockUSDC` | Loans, custody and auctions |

Every constructor is nonpayable, takes at most six static arguments, and makes no external contract call. There are no proxies, upgrade hooks, linked external libraries, delegated execution, factory-owned roles, or administrator collateral-sweep functions. The deployer's later manifest step supplies the actual references; this repository intentionally contains no `launch.json`.

### Sepolia addresses

| Role | Address / value |
| --- | --- |
| Chain ID | `11155111` |
| Owner and initial guardian | `0xd58dcd4594087c2758717a59f44a5ac09db65105` |
| Intake v2 | `0xa43e6f75ee006411f79ac1c84120606c2330de82` |
| Test IMD | `0x44a1cd38474fb1748400e7deb5f8d786cce3f89a` |
| Oracle signer | `0x5598aa9146215bc13eb26f2c692ad1461fd32982` |
| Action | `bytes32("oracle.request@oracle-1")` |
| Action, hex | `0x6f7261636c652e72657175657374406f7261636c652d31000000000000000000` |
| Initial fee | `500000000000000000` test IMD units (0.5 IMD) |
| Application addresses | Supplied by the confirmed launch handoff; not deployed during this assignment |

Read-only verification on 2026-10-15 found Sepolia chain ID 11155111, 7,384 bytes of code at Intake, symbol `IMD` at the test token, and `Intake.priceOf(action,testIMD) == 500000000000000000`. The public oracle API reported the signer above. Recheck all four before use; a later service migration can change them. Sources: [IdentityMD oracle/onchain documentation](https://imd.fun/docs/#intake), [oracle request API](https://api.imd.fun/oracle/requests?limit=1).

### After launch

1. Verify all five `owner()` values and the dependency getters against the handoff. Call `CardPool.setLending(CardLending)` as owner. This binding is **one-time**, checks the lending contract points back to this pool, and cannot be replaced. Deposits can exist beforehand, but borrowing fails until wiring is complete.
2. Review the oracle signer from the public service and call `CardOracle.setSigner` if it changed. The constructor takes the published signer; there is no fabricated fallback signer. Configure classes using the runbook below, then run preflight before paying.
3. Deposit mock USDC into the pool. The owner receives the initial **1,000,000 tokens**, with name **C** and symbol **AUREON** as requested. This is the `MockUSDC` asset itself; no extra launch/reward token is created. The supply is **initial**, not a cap: owner-only `mint` remains available because the requested token is mintable. All protocol amounts treat this test asset as one US dollar per whole token; it has no real redemption backing.
4. Set a guardian on `CardPool`, `CardOracle`, and `CardLending` using `setGuardian`. Initially each guardian is the owner. The owner may also pause; only the owner unpauses. `transferOwnership(next)` followed by `next.acceptOwnership()` is required on each contract. If the outgoing owner still holds the guardian seat, acceptance moves that seat to the new owner, so a former owner keeps no pause power; a separately appointed guardian is unaffected and must be rotated explicitly. Renouncing ownership is disabled.
5. Monitor pending oracle requests, prices, loans, reserve balance, auctions, and successful delivery. The owner maintains the catalog and service settings; permissionless keepers can request prices, clear timed-out requests, start auctions, and buy collateral. There is no protocol-paid keeper reward.

Owner settings on the oracle are `setIntake`, `setPayment(asset,fee)`, `setAction`, `setSigner`, `setPanel(size,quorum)`, `setObservationChain`, and `setClass`. Get their operational values from current IdentityMD capabilities/deployment documentation, not an arbitrary relayer. Addresses and action/payment settings are checked for zero; requests check the live Intake price and exact transfer amounts. Each pending request snapshots its Intake, observation chain, class version, panel, and quorum. Signer rotation applies immediately, including to pending requests. A signer rotation can therefore require timeout and retry. No cross-chain `IntakeDelivery` path is used by this same-chain application.

## Oracle behavior and preflight

`requestPrice(classId)` pulls exactly the configured fee from its caller, gives Intake an exact allowance, calls **v2 `requestWithFailure`**, then clears the allowance. One request can be pending per class. Its deadline is two days; `clearExpired(intakeId)` is permissionless strictly after that deadline. The payment is spent even if the panel fails or the callback is lost. There are no refunds.

The body uses the requested PriceCharting question, explicit term/period/unit/rounding definitions, a product-page source prefix, public `panel` evidence, **30 seats / 21 quorum**, tolerance **500 bps**, and validity **86,400 seconds**. The protocol name for a numeric answer is **`"uint256"`**, not `"number"`. An answer is whole USD, rounded down by the panel; the consumer multiplies it by `1e6`. The definitions require the panel to report inability if a column is unavailable, rather than invent zero, and the body's guard sets `"min":"1"` so the door refuses a zero reading before it is signed (the request then ends in `onFailure`, which clears the class). A signed zero that still reaches the callback is refused with `BadAttestation` and never stored: zero is an unavailable column, not a valuation, and must not make healthy loans liquidatable. Answers above **1 trillion USD** are refused as a scaling/sanity bound, not a valuation estimate.

The question's observation chain defaults to **Ethereum (1)** and supplies the relative **24-hour block window**. The **consumer domain remains Sepolia (11155111), verifyingContract = the deployed CardOracle**. These are separate protocol fields: `a.chainId` describes the observation window, while the EIP-712 domain identifies the consumer. This choice is necessary because the public checker currently reports **no oracle RPC for Sepolia**. The check with observation chain 1 returned **no blockers**, but retained **wording and answerability suggestions**. These are not a guarantee that a paid question will be accepted or answered. An owner can change the observation chain when the service supports another one.

Recorded checks are [the submitted draft](docs/oracle-check-input.json), [the response](docs/oracle-check-response.json), and [the rejected Sepolia-window response](docs/oracle-check-sepolia-response.json). [The complete body without its deployment-specific consumer field](docs/charizard-body.json) records the definitions and source guards. The PriceCharting page was reachable and contained a PSA 10 column during this assignment; no scraped price is used on chain.

`POST /requests/check` accepts a **draft subset** of the paid JSON; it rejects full paid-body fields such as `definitions`, `guards`, `window`, and `quorum`. `tools/check_oracle.py` reads the exact `requestBody` from the deployed contract, checks its Sepolia consumer domain, posts the supported draft fields, and saves both forms and the response. It fails on service errors or blockers. Review suggestions and full definitions before calling `open`; the tool does not bypass the wording screen or set `allowAmbiguous`. The absent `oracle-assess` file was not part of the delivered read set; the supplied canonical consumer/reference and the public protocol API/documentation determine the integration.

### Attestation and replay rules

`onPrice(intakeId, attestation, signature)` accepts only the **Intake snapshotted on an open request**. It verifies the unchanged 15-field protocol struct under EIP-712 name **IdentityMD Oracle**, version **2**, current consumer chain, and this oracle's address. It requires at least the request's panel and quorum, `agreed >= quorum`, consistent counts, a correct observation chain, a numeric 32-byte answer, and the expected validity limits. Issuance must be no earlier than the request and no more than 24 hours before the current block; the base library's five-minute tolerance for an issuance stamped slightly ahead of the block clock is kept, so an honest clock skew does not burn the fee or lock the class. `freshPrice` refuses to serve such a price until the chain clock reaches its `issuedAt`. A strictly later issuance is required to overwrite a class price.

The callback ID is Intake's ID; `attestation.requestId` is a different oracle UUID. Both the local request and the signed UUID are consumed. Failure callbacks accept only the recorded Intake and open ID, clear it, emit the unsigned failure details, and move no value. Callbacks and repayment remain usable while paused.

For a lost callback, the owner can call **`bindRelay(intakeId, oracleUUID, questionHash)` once** while that request is pending. Verify the API record, original body hash, panel, consumer domain and UUID belong to that exact paid request first. Then **any address** may call `submit(attestation,signature)`. It enforces the binding and the same signature/panel/freshness/replay checks. A relayer cannot introduce its own question or map an arbitrary oracle UUID onto a pending card. This recovery step adds an explicit admin responsibility because the protocol does not sign the Intake ID and a relative window's question hash cannot be computed before resolution. It does not permit submission of unsolicited quotes.

## Adding a card class

1. Choose the exact edition, language, variant, grader and grade. Inspect its PriceCharting product page and actual grade-column heading. For the smoke class: game `Pokemon`, set `Pokemon Base Set`, name `Charizard`, number `4`, grader `PSA`, grade `10`; slugs `pokemon-base-set` / `charizard-4`; column `PSA 10`. Do not use these for first-edition or shadowless variants.
2. Compute `MockCardNFT.computeClassId(Card)`. The class is `keccak256(abi.encode(game,set,cardName,cardNumber,grader,grade))`; **certNumber is excluded**. Text is case-sensitive and exact. Every different edition/grade must have distinct metadata. The owner ensures oracle-template semantics match the hashed NFT metadata.
3. As owner, call `CardOracle.setClass(classId, Template(cardName,cardNumber,setName,setSlug,cardSlug,gradeColumn), true)`. Labels must be nonempty bounded printable ASCII with no quotes or backslashes; use a reviewed transliteration for non-ASCII names. Slugs allow lowercase letters, digits and hyphens only. Updating or disabling a class clears its cached price and is refused while a request is pending. Settle it or wait for `clearExpired` first.
4. Read `requestBody(classId)` and run `python3 tools/check_oracle.py --rpc-url "$SEPOLIA_RPC" --oracle "$CARD_ORACLE" --class-id "$CLASS_ID"`. Review its saved JSON, blockers, and suggestions before spending IMD. Repeat after a template or protocol change.
5. Mint a mock NFT as owner with the full `Card` metadata and a unique certificate. `(grader,certNumber)` cannot be reused. NFT fields are immutable and available from `cardData(tokenId)`; `classId(tokenId)` is derived at mint, never supplied by a borrower. This mock has no real vault/custodian integration or off-chain token URI hosting.
6. The requester mints/acquires test IMD, approves CardOracle for the request fee, and calls `requestPrice`. After a callback or bound relay, check `freshPrice`. A borrower approves CardLending for the NFT and calls `borrow(tokenId,grossUSDCAmount)`. **Do not transfer NFTs directly to CardLending**; only `borrow` records a recoverable loan. There is no administrator rescue mechanism.

## Lending, pool accounting and liquidation

- **Borrow:** principal must be positive, cover its rounded-up fee, and be at most **45%** of the fresh class price. The borrower must own the NFT. The pool sends principal minus a **1%** fee; the borrower owes full principal. The fee stays inside the pool as segregated reserve. A 400 USDC loan sends 396 USDC and reserves 4 USDC.
- **Interest:** simple, non-compounding, `ceil(principal * APR_bps * elapsed / (10000 * 365 days))`, rounded up so a tiny or short loan never owes less than its exact interest. Initial APR is **12%**. Owner `setAPR` accepts 0–100% and changes new loans and extensions only; existing rates are snapshotted. Interest continues after maturity until repayment or auction start; a matured loan is carried at its contractual value until someone calls the permissionless `liquidate`, which any lender may do. Terms last **30 days**.
- **Repay:** anyone can pay the entire current debt; the NFT returns to the original borrower. Partial repayment is not implemented. Full repayment can also cancel an auction before a purchase, at its frozen debt. A closed loan ID cannot be reused; another loan against the same returned NFT gets a new ID.
- **Extend:** `extend(loanId, maxAprBps)`, only the borrower, before maturity, with a fresh price issued strictly after the price used for the previous borrow/extension. The borrower pays the accrued interest in the same call, so the debt that survives the renewal is the principal alone, and that principal must pass the same **45%** check; a loan drawn at the maximum can be renewed at an unchanged price. The call reverts `RateAboveLimit` if the live APR exceeds `maxAprBps`, so a rate change mined first cannot silently reprice the new 30-day term. There is no repeat origination fee.
- **Start liquidation:** anyone, at `timestamp >= maturity` even without an oracle; or before maturity with a newer, fresh price making current debt **strictly greater than 60%** of valuation. Exactly 60% is not liquidatable. Auction debt is frozen; interest stops.
- **Auction:** 24 hours, continuous linear price from **120% of frozen debt to 50%**, rounding up to one USDC base unit. The floor remains available after 24 hours until sale or repayment; there is no automatic giveaway. `buy(loanId,maxPrice,receiver)` enforces a price ceiling, pulls USDC, pays the pool up to debt, and safely transfers the NFT. Failed receiver callbacks revert the entire sale. Sale surplus is credited to the borrower and withdrawn with `claimSurplus(receiver)` so a failed payout cannot block an auction.
- **Losses:** the reserve absorbs the shortfall up to the part of it that NAV already counted as covering that shortfall (see the next two items). Any excess reduces lender NAV; a 1% reserve cannot guarantee coverage of a 50% auction outcome. Anyone can add reserve funds with `fundReserve`; they receive no shares and there is no admin withdrawal of reserves. Example: a 400 USDC zero-interest debt sold for 200, with only its 4 USDC fee reserved, realizes a **196 USDC lender loss**, recognised gradually while the auction price descends, not at the sale.
- **Settlement never moves NAV:** every repayment, extension and purchase hands the pool exactly how far `netReceivable()` fell (`settle(payment, debt, receivableReleased, shortfallReleased)`), and the pool rebalances so `totalAssets()` is identical before and after the call. Reserve that NAV counted as covering the loan's shortfall is spent on it. Whatever the payment collects **above the loan's current mark** (a floor sale of a written-off loan, a full repayment of an auctioned loan, a purchase after the mark decayed below the floor) is **held back as reserve** instead of becoming unreserved cash, less any counted reserve the settlement leaves without a shortfall to back. A same-block deposit/settle/redeem therefore captures nothing, and a lender exiting just before a settlement forgoes nothing. The held-back recovery reaches lenders only by covering later mark-downs, never as an atomic gain; there is no admin release.
- **Counted reserve:** the pool adds to NAV `coveredReserve()`, the part of the reserve expected to cover the current marked shortfall. It grows one for one with the expected shortfall since the last checkpoint, capped by the reserve and by the shortfall, and a checkpoint is taken whenever the reserve changes for a reason other than a mark-down (`draw` fees, `fundReserve`, settlement). Reserve added after a loss was recognised therefore covers only mark-downs that come later; it never re-rates a loss lenders have already carried, so adding reserve is never a sandwichable gain either.
- **Auction marks in NAV:** an auction loan is never carried at face value while its sale price is below the debt. `netReceivable()` marks each open auction at `min(frozen debt, current Dutch price)`: par for the first `PAR_WINDOW` (24,685 seconds, while the price is still at or above the debt), then down the curve to **50%** at 24 hours; an auction unsold at the floor is then written down **linearly from 50% to zero** over `WRITE_OFF_DELAY` (**1 day**, so it is carried at zero from 48 hours after the auction opened). The mark is continuous in time: there is no step at the floor or at the write-off that a lender could time an exit around, and the price a buyer pays stays at the 50% floor throughout. A lender who exits mid-auction takes their share of the expected loss with them; a sale or repayment that collects more than the mark is held back as reserve (see "Settlement never moves NAV"). The written-off loan remains purchasable at the floor and repayable in full. Marks are kept as aggregates: auctions open in time order, so phase changes are walked lazily from three queue heads (par to descent, descent to decay, decay to written off) in every NAV read and recorded on the next state change; the permissionless `syncAuctions()` records them early to keep later reads cheap. The descending and decaying aggregates are each rounded once and can differ from the sum of per-loan `auctionMark(id)` values by under one base unit per such auction.
- **ERC-4626:** `totalAssets = (USDC cash - reserve) + accrued active debt + auction marks + coveredReserve()`. Aggregate exact interest numerators prevent late depositors from capturing already accrued interest, and the aggregate is rounded up like each loan's own interest, so NAV never exceeds what settlement collects; it can trail the sum of per-loan debts by under one base unit per active loan, and settlement passes the exact drop so even that unit is held back rather than realised. Shares have **12 decimals**, six virtual offset decimals, one virtual asset and `1e6` virtual shares. Deposits/redeems round down, mints/withdrawals round up. Donation/inflation, slippage and loss risk remain; integrations should use atomic share/asset limits where needed.
- **Utilisation:** no fixed fractional utilisation cap; lending can use all unreserved cash. `maxWithdraw` and `maxRedeem` cap exits to available cash, and `maxRedeem` returns zero rather than a dust amount that `redeem` would refuse. Outstanding loans are receivables, not cash, so withdrawals may wait for repayment/sale. Zero/dust transactions that cannot produce assets or shares are refused, including `withdraw(0)` and `redeem(0)`.
- **Pause:** lending pause stops new loans, extensions and new liquidations; pool pause stops deposits/mints/draws; oracle pause stops new requests. Repayment, surplus claims, existing auction purchases, callback settlement, reserve donations and cash-backed lender exits remain live. Each contract has its own pause switch. Pausing does not freeze time or extend maturities/auctions.

## Sepolia smoke run

The launch operator runs this after obtaining the five actual contract addresses. Shell variables below are **operator-supplied confirmed deployment values**, not addresses invented by this project. `OWNER_KEYSTORE` names the operator's existing Foundry signing account; no key is loaded by source or tests. The worker did not execute these broadcast commands.

```sh
# 1. Wire the pool, allowlist Charizard PSA 10, and deposit 1,000 initial mock USDC.
forge script script/SepoliaSmoke.s.sol:SepoliaSmoke \
  --sig 'configure(address,address,address,address,address)' \
  "$MOCK_USDC" "$MOCK_CARD_NFT" "$CARD_POOL" "$CARD_ORACLE" "$CARD_LENDING" \
  --rpc-url "$SEPOLIA_RPC" --account "$OWNER_KEYSTORE" --broadcast
# Record CLASS_ID from the output.

# 2. Check the exact class body and review the response before paying.
python3 tools/check_oracle.py --rpc-url "$SEPOLIA_RPC" \
  --oracle "$CARD_ORACLE" --class-id "$CLASS_ID"

# 3. Mint one card and 0.5 test IMD, then open exactly one real oracle request.
# MOCK_CERT_NUMBER is a new identifier for this mock card, chosen by the operator.
forge script script/SepoliaSmoke.s.sol:SepoliaSmoke \
  --sig 'open(address,address,address,address,address,string)' \
  "$MOCK_USDC" "$MOCK_CARD_NFT" "$CARD_POOL" "$CARD_ORACLE" "$CARD_LENDING" "$MOCK_CERT_NUMBER" \
  --rpc-url "$SEPOLIA_RPC" --account "$OWNER_KEYSTORE" --broadcast
# Record TOKEN_ID, the Intake ID and the transaction hash; the signed UUID is different.

# 4. A bounded watcher waits only for a real, fresh on-chain price.
python3 tools/watch_price.py --rpc-url "$SEPOLIA_RPC" --oracle "$CARD_ORACLE" \
  --class-id "$CLASS_ID" --interval 15 --timeout 600

# 5. Once delivery succeeds, borrow a chosen gross amount in six-decimal units.
# 100000000 below is a 100 USDC example; it must fit the actual price and pool cash.
forge script script/SepoliaSmoke.s.sol:SepoliaSmoke \
  --sig 'finish(address,uint256,uint256)' "$CARD_LENDING" "$TOKEN_ID" 100000000 \
  --rpc-url "$SEPOLIA_RPC" --account "$OWNER_KEYSTORE" --broadcast
```

The scripts verify Sepolia, the named owner, dependency wiring, and expected oracle endpoints. `finish` reverts until there is a fresh attestation and verifies resulting custody and debt. A real callback may take minutes to days or never arrive. A watcher timeout does not cancel the request or authorize paying again. Inspect Intake's completion and the public oracle result; recover a missed callback with a correctly verified `bindRelay`/`submit`, or clear after two days. An unsigned failure is never permission to borrow. Record the live transaction hashes and deployed addresses in the deployment handoff after execution.

## Validation and operational limits

The Solidity suite covers all five applications, protocol vector digest/signature conformance, canonical callback selectors, mocked EOA and ERC-1271 signatures, callback gas stipend, unsolicited/wrong/replayed requests, wrong domains/chains, weak panels, expiry, timeouts, catalog changes, pausing, two-step ownership, NFT certificates, ERC-4626 rounding/utilisation/inflation, loan and extension failures, extension at the LTV cap and under a rate bound, simultaneous debt accounting, auction boundaries, NAV marks down the Dutch curve to the floor and linearly through the write-off, hourly NAV continuity across both, NAV-neutral settlement under a same-block deposit/settle/redeem sandwich for both a floor purchase of a written-off loan and a full repayment of an auctioned loan, held-back recoveries and donated reserve covering only later shortfalls, fair pro-rata exit during an unsold auction, aggregate-versus-per-loan marks with removals from the middle of the auction queue, zero-answer refusal, clock-skew acceptance, guardian handover, dust `maxRedeem`, reserves, surplus, failed transfers and reentrancy. Fuzz tests use the assignment's seed for interest conservation, auction monotonicity, auction mark bounds, and share round trips. The smoke script is tested end to end with local mocks; the Python watcher is tested with a simulated short clock, not a real wait.

This is a testnet prototype, **not an audited production lending system**. The panel and signer can be wrong; the writer can withhold or mispair results; catalog and signer administrators are trusted. PriceCharting estimates are not executable bids, and a class price does not prove a physical card exists, its authenticity, custody or redemption rights. Oracle liveness and sparse NFT liquidity can cause losses. Auction loans are marked down the Dutch curve in NAV, so an exiting lender carries their share of an expected loss, but an active loan whose collateral has collapsed is carried at contractual value until someone starts its auction, and the mark of a descending auction is an estimate of a sale that may not happen. Recoveries above the mark and reserve added after a loss are kept as reserve for later shortfalls rather than returned to the lenders who carried that loss; with no further auctions they stay in the pool. The auction design itself is a trust assumption for lenders: there is no keeper reward for `liquidate`, a borrower may buy back their own collateral, the opening price of 120% of debt is only 54% of collateral value for a loan drawn at 45%, and a strategic default that buys back at the 50% floor is profitable on a thin market while the 1% origination reserve covers only a small part of that shortfall. Owners should size the pool, the reserve top-ups and the catalog with that in mind. One pending request per class and a two-day timeout can temporarily impede refreshes. Unsolicited NFT transfers can become stuck. No full market, custodian, keeper or frontend is delivered. An independent adversarial review and a successful live Sepolia smoke are operational prerequisites before considering use beyond this mock deployment. Slither and Mythril were not run.

## Web app

The CardVault site lives in [`site/`](site/README.md): a static Vite + React export in `site/dist/`, with
install, preview, rebuild, env and e2e instructions in `site/README.md`. Design tokens and components are in
[`DESIGN.md`](DESIGN.md).

## Static web app

The CardVault frontend lives in `site/`, with its production export at repository-root `dist/`.
See [site/README.md](site/README.md) for setup, preview, build-time addresses and Anvil interaction tests,
[DESIGN.md](DESIGN.md) for the implemented interface, and [site/VALIDATION.md](site/VALIDATION.md)
for the revision checks. The web revision leaves contract source, Foundry configuration and dependencies unchanged.
