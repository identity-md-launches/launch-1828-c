# CardVault revision validation

Run date: 2026-10-22. This is a targeted revision of the accepted site. Contract source, dependency manifests/lockfiles and existing build configuration were preserved. No public-chain transaction or publishing command was sent.

## Reproduction

The unchanged export was saved in temporary scratch space before edits. The local fixture deployed this repository's contracts, configured three fresh classes ($2,000 / $1,500 / $1,000), created actual oracle request records, accepted synthetic EIP-712 submissions, then rotated the signer. All eleven reports reproduced:

- At 390×844, the original three-class quote began at y=565.30; Open a ticket occupied y=1013.52–1057.52.
- Last price opened a generic contract drawer; the price desk had zero `.tag` elements. An old price was relabelled with the newly configured signer.
- A $400 active loan produced zero slabs on Tickets and six-place debt. With no settlement, one elapsed day changed the alleged realised return from 0.0000% to 0.0001%.
- The skip link changed the route to `#main`; focus escaped both modal implementations. `1.0000000` left auction Buy enabled, and a blank ceiling failed when the browser clock led the latest block by 30 seconds.
- Baseline Lighthouse mobile performance was 60 with uncompressed responses (FCP 5.3s / LCP 7.3s), and 85 with gzip. Accessibility was 100. Approximately 977 kB of decoded scripts loaded before any wallet action.

Scratch evidence and browser reports are intentionally excluded from delivery. The repeatable scenarios are in `site/e2e/flows.spec.ts` and `site/e2e/revisions.spec.ts`; each finding's disposition is in root `.imd-responses.json`.

## Final implementation and regression results

| Finding | Source | Fix and check |
| --- | --- | --- |
| Performance | `site/src/config.ts:58`, `wallet-connectors.ts`, `bootstrap.ts`, `chain.ts`, `scripts/gen-abi.mjs` | SDK registration/loading waits for Connect. Other pages, price desk and transaction helpers are lazy. A prerendered unpriced shell embeds the canonical styles; the bootstrap observes its first contentful paint before starting hydration, avoiding an early frame racing the app download. Only needed public RPC actions and generated read ABI entries load initially. Browser test confirms no wallet chunk before Connect. |
| Phone quote | `site/src/pages/Counter.tsx:37`, `styles.css` | Selected slab and quote lead; other classes follow. The range control and complete 44px action fit inside 390×844 with all three classes, after fonts load and after changing class. The measured final action spans y=783.95–827.95, wholly inside the viewport. |
| Repeated prices | `site/src/pages/Counter.tsx:60`, `PriceDesk.tsx`, `ui.tsx:84` | Last price and both desk/history amounts reuse receipt-backed tags. Compact variants open issue/expiry, agreement, historical signer and both oracle links. Stale prices retain their provenance. |
| Signer rotation | `site/src/data.ts:98`, `ui.tsx:95` | Replay immutable signer events in log order and retain the verification signer on each PriceStored. Match signed submission data to the price. Rotation of both signer and current panel leaves old attribution/counts unchanged. |
| Realised return | `site/src/data.ts:190`, `pages/Vault.tsx:52` | Match pool settlements to loan cash-flow events. Divide net realised earnings by cumulative deposited assets. One unpaid day changes share price but leaves realised return at 0.0000%; repayment produces $0.13 net realised cash and a positive return on $100,000 deposited. Share-price return has its own label. |
| Ticket slabs | `site/src/pages/Tickets.tsx:90` | Reuse the existing slab/ticket pair with card metadata and tokenId. The connected ticket shows grader, grade, name, set, number and cert. |
| Skip link | `site/src/App.tsx:55` | Prevent hash navigation and focus `main[tabindex=-1]`. Tested from all four non-counter routes. |
| Modal focus | `site/src/ui.tsx:160`, `Wallet.tsx` | Shared native modal, initial focus, inert background, explicit Tab/Shift+Tab cycling and trigger restoration. Tested for wallet, provenance and nested provenance above price desk. |
| Invalid ceiling | `site/src/pages/Auctions.tsx:38` | Only empty input uses the default. Invalid/nonpositive entries expose an inline error and disable Buy without sending an approval or purchase. A valid $1 ceiling remains $1 and cannot buy the lot. |
| Clock-ahead buy | `site/src/pages/Auctions.tsx:34` | Default max is the authoritative `auctionPrice()` read; browser interpolation is display-only. With a 30-second clock lead, blank-max buy succeeds. |
| Amount precision | `site/src/pages/Tickets.tsx:35`, `pages/Auctions.tsx:58` | Debt and auction display use the existing two-place `usd()`. Approvals and calculations keep all six base-unit decimals. |

A separate 390px browser visit measured a signed local quote ready in 312ms. That is a local integration measurement, not a public-RPC latency promise.

A post-purchase run also exposed a cached block head lagging behind latest loan reads, briefly labelling a sold card as repaid at zero. Event scans now fetch an uncached head so their outcomes include the confirmed transaction.

The original five interaction scenarios and seven revision scenarios passed together: **12 passed**, final run 39.7s. Revision scenarios assert zero console/page errors. The disconnected original flow also checks every page. The fixture is served beneath `/app/`, exercising relative assets and hash routes.

The injected test wallet adds 25% gas headroom to the node estimate, to cover next-block accrual changes instead of forwarding an exact old-block estimate. It still simulates errors normally and sends only the original approval/action transactions. The repayment scenario advances the synthetic chain by one minute before paying so it tests an accrued-interest payment, rather than racing the opening block's zero-interest boundary. Snapshots isolate the seven revision scenarios. Prices are accepted by the actual contract signature checks; they are not written directly into storage.

## Commands and measured results

| Check | Command / setup | Result |
| --- | --- | --- |
| Solidity build for ABI generation | `forge build --offline` at root | Passed, Solidity 0.8.26; no contract changes |
| Typed ABIs | `cd site && npm run abi` | Five full ABI hashes match the supplied deployment; read-only runtime subsets generated from the same artifacts |
| Typecheck | `cd site && npm run typecheck` | Passed |
| Production export | `cd site && npm run build` | Passed; repository-root `dist/`, relative asset paths |
| Shell generation | `cd site && node scripts/prerender.mjs` | Passed; only unpriced initial markup is embedded |
| Playwright | `PLAYWRIGHT_BROWSERS_PATH=/opt/imd-tools/ms-playwright node site/node_modules/@playwright/test/cli.js test --config test/scratch/playwright-running-fixture.config.ts` | 12 passed. Temporary config retains the committed test paths and names the preinstalled headless Chromium explicitly; setup is the same committed helper, either run globally or started separately for the final fixture checks. |
| Mobile Lighthouse, final public-address export | Lighthouse 12.8.2, default mobile simulation, only performance/accessibility, no injected wallet, plain static HTTP with no compression | **100 performance / 100 accessibility**; FCP 1.1s, LCP 1.4s, TBT 20ms, CLS 0 |
| Mobile Lighthouse, gzip | Same final export/settings, gzip static responses | **100 / 100**; FCP 0.9s, LCP 1.2s, TBT 20ms, CLS 0 |
| Mobile Lighthouse, populated | Same source rebuilt against Anvil, three fresh signed classes, uncompressed static responses, no wallet | **100 / 100**; FCP 1.1s, LCP 1.4s, TBT 50ms, CLS 0.041 |
| Submission size | Source and static export, excluding dependencies/caches and scratch outputs | Under 8 MiB; approximately 6.26 MB |
| Design probe, production export | Command below | **16/16 checks passed** on both production and populated exports, 320/390/1440px and reduced motion |

The final compact-tag repair was checked again with the populated probe: all 16 checks pass, including the previously flagged wrapping. A connected counter reload exposed a persisted-account hydration race; wagmi SSR mode now defers account restoration until after hydration, and the eager counter sits outside the lazy routes’ Suspense boundary so that restoration cannot interrupt an unhydrated boundary. The zero-console-error regression includes that reload.

The temporary Playwright configuration was needed because the supplied browser installation and package-lock's browser revision differ. No additional browser was installed and the dependency lockfile was left unchanged. Normal `npm run e2e` works with its matching Chromium. Intermediate development runs exposed a test whitespace assertion and the synthetic zero-interest timing boundary; both were repaired before the final passing run.

Lighthouse used a plain static server with extension-based content types, without caching headers, a service worker or mocked public RPC responses. The gzip run changed only response compression. The final public export fetched real public Sepolia state; the populated run used only the disposable Anvil contracts. Scores vary with browser/runtime/network load; the measured settings and data state matter. No continuous score guarantee is claimed.

Final public startup scripts total 419,351 decoded bytes (2,737-byte bootstrap plus 416,614-byte app), versus approximately 977 kB before. Wallet SDK chunks remain in the complete export for Connect, but are absent from disconnected startup requests. The read ABI subsets retain generated typing; full ABIs remain available to transaction pages.

The pinned probe ran from the repository root:

```sh
IMD_PLAYWRIGHT=/opt/imd-tools/playwright-mcp/node_modules/playwright/index.mjs \
PLAYWRIGHT_BROWSERS_PATH=/opt/imd-tools/ms-playwright \
node .imd/reads/skills/design-critic/scripts/taste.mjs --out test/scratch/taste
```

## Better Interface coverage

The pinned core principles of all six domains informed the changes. `DESIGN.md` records the final source's tokens and component behavior.

| Domain | Coverage, findings and disposition |
| --- | --- |
| Accessibility | Fixed skip-route loss (`App.tsx:55`), modal escape/focus restoration (`ui.tsx:160`) and the invalid auction field (`Auctions.tsx:62`). Keyboard tests cover forward/backward cycling, Escape, nested dialogs and restored triggers. Lighthouse accessibility 100 on public and populated counters; probe text contrast meets its measured 4.5:1/3:1 thresholds. This is not a manual screen-reader certification. |
| Layout | Fixed catalogue order (`Counter.tsx:37`) and compacted the selected slab's phone body. Checked the complete quote action at 390×844 after font loading; inspected its screenshot. Preserved shared alignment and the existing breakpoints. Production probe found no horizontal overflow, text overlaps, floating-control obstruction or clipping at its three widths. A populated probe flagged the compact Last price age wrapping into a multi-line box; the compact tag now wraps price and an indivisible age as separate flex items. Browser checks across all five populated/connected screens at 320/390/1440 found no horizontal overflow or console errors; ticket and auction screenshots were inspected. |
| Writing | Preserved the short shop-counter voice and existing terms. Ceiling errors explain the correction next to the field; default-vs-estimated prices and the realised-return denominator are explicit. Empty and stale states do not invent data. |
| Typography | Retained the five sizes, three families and 400/600 weights. The fonts are local and preloaded. Monetary outputs now consistently use two places, with precise base units retained. Slab identity and cert remain readable rather than truncated away. |
| Colors | Existing paper/ink/red/brass tokens preserved. Production probe passed all measured contrast pairs. Stale, invalid, paused and ticket statuses have text as well as color. No new palette or gradients. |
| UI | Shared modal behavior replaces the two incomplete overlays. Disabled/loading/error states remain visible. No transition-all or endless animation was added; reduced-motion probe passed. Initial content paints without loading wallet SDKs or making up a price. |

## Limits

- The public deployment needs owner configuration and listed classes before a live loan/attestation can be demonstrated. Local signed submissions prove the integration path, not a live IdentityMD panel outcome. No production signature or account was used.
- Matching direct submissions provide exact signed agreement counts. Internal callback transactions fall back to the request's minimum panel/quorum and say so; missing historical evidence is explicitly unavailable. The linked request remains the complete off-chain evidence source.
- Realised return is an aggregate cash-flow statistic with the documented deposit denominator. It is not annualised, time-weighted or a personal lender return.
- External wallet app handoffs, real Coinbase/WalletConnect signing, live price-request delivery, extension/claim-surplus transactions, Safari, a manual assistive-technology walkthrough, RTL and 200% browser zoom were **not verified** in this revision.
- Lighthouse still reports optional optimization opportunities for compression/caching and unused code; some existing number controls also trigger its best-practice accessible-name diagnostic. The requested performance/accessibility category scores above are the actual results.
- IPFS publication is performed by the publishing plane after review. This revision delivers the complete static export and does not claim a new live URL.
