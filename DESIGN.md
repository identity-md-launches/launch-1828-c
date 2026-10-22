# CardVault design

## Overview

CardVault is a Sepolia card-backed lending counter for collectors and lenders. The existing paper, ink, red stamp and brass palette stays in place. The three recurring objects are a typographic graded slab, a perforated loan ticket and an oracle price tag. There is no card artwork, marketing hero or extra page.

`site/src/styles.css` is the source of the design tokens. `site/src/ui.tsx` contains the shared objects. The counter starts with its selected slab and full quote; other classes follow below. Tickets and the vault book pair each ticket with its actual NFT slab.

## Colors

| Token | Value | Role |
| --- | --- | --- |
| `--paper` | `#f6f3ec` | Page and dialog surface |
| `--paper-2` | `#ece7dc` | Slab label, neutral hover |
| `--clear` | `#fbfaf6` | Slab body, ticket, price tag, inputs |
| `--ink` | `#1a1916` | Primary text, structural borders, focus outline |
| `--muted` | `#57534a` | Supporting text and labels |
| `--line` | `#c9c2b2` | Internal separators and perforation |
| `--red` | `#b0251c` | Primary actions, selected slab, status and input errors |
| `--brass` | `#7a5a10` | Lender return figures and repaid stamp |

Primary buttons use white text; their hover and pressed fills are `#8f1d16` and `#741711`. Disabled controls have 0.6 opacity and a disabled cursor. Text accompanies statuses and errors. The light palette is the only theme. Contrast coverage and measured results are in `site/VALIDATION.md`.

## Typography

The existing five-step scale is `--s1: 12px`, `--s2: 14px`, `--s3: 16px`, `--s4: 20px`, `--s5: 28px`.

- `--label`: local Barlow Condensed, weight 600; fallback Arial Narrow/sans-serif. Headings, slab labels and controls. Heading line-height is 1.1; labels use 1.3.
- `--mono`: local IBM Plex Mono, weight 400; fallback ui-monospace/Menlo/monospace. Amounts, dates, IDs and inputs use tabular numbers. AUREON amounts display two decimals; all calculations and approvals retain base-unit precision. Share price is a dimensionless six-place ratio.
- `--body`: system-ui with platform fallbacks, weight 400; 16px and line-height 1.45. Supporting copy is 14px. Prose is capped at 62ch.

The counter bootstrap observes its actual first contentful paint before starting hydration, with a frame-based fallback in older browsers. The unpriced initial shell embeds the canonical source styles through `site/scripts/prerender.mjs`; `main.tsx` also imports that stylesheet for ordinary Vite development/builds. The two WOFF2 faces are preloaded from local assets. Fontsource CSS also supplies WOFF fallbacks. Headings balance and prose uses pretty wrapping; long card metadata and provenance values can wrap. Inputs stay at 16px on phones. Letter spacing remains natural apart from lettering inside the existing SVG status stamps.

## Layout

`main` has a 1180px maximum width and 12px phone padding, increasing to 24px at 760px. The header wraps the navigation onto its own row on phones. Controls have a 44px primary height; small source links keep the established compact treatment with visible underlining.

The counter uses a single column below 900px: selected slab, quote, then the other-class catalogue. Its selected slab has a 12px clear body on phones to keep the slider, costs and complete primary button visible at 390×844. At 900px the selected slab and quote occupy adjacent columns, with the catalogue spanning both; that slab body becomes 180px. Catalogue grids use two columns on phones and three at 900px. The existing binder uses three columns, increasing to four at 900px.

Tickets and the vault book share `.pair`: stacked slab and ticket on phones, then a 220px slab column and flexible ticket column from 760px. Ticket pairs occupy the available row rather than nesting the desktop pair inside a narrow two-column ticket grid. Auction lots and deposit/withdraw forms use two columns from 760px.

Dialogs sit at the phone's lower edge; from 640px they are centered, or align to the right for the price desk. The sheet is at most 88vh on phones and scrolls independently. The modal is in the native top layer, so it cannot be covered by the page.

## Elevation & Depth

Confirmed transaction outcomes are read through an uncached latest event-scan head, keeping closed-ticket stamps aligned with their actual repayment or sale.

The system is flat: hairline borders and paper tones carry structure, with no shadows, gradients or blur. Slab selection uses a 2px red outline. Tickets have a dotted left edge and dashed inner perforation. A modal uses an ink overlay at 0.45 opacity. Nested provenance dialogs appear above the price desk through native modal stacking.

## Shapes

`--r` is 4px. Buttons, inputs, slabs and tags use that radius; small eligibility chips use 2px. The ticket's left corners are square. The circular punched hole on the price tag is decorative. No pill-shaped navigation or rounded dashboard cards are added.

## Components

- `Slab` in `site/src/ui.tsx` accepts actual `card`/`tokenId` or catalogue `template`, plus selected, grey, badge and click states. It keeps grader, grade, name, set, card number and certificate visible when an NFT supplies them.
- `Quote` in `site/src/Quote.tsx` groups a complete `PriceTag`, borrowing limit, labelled range input, proceeds, repayment, due date, cost and action. It calculates with integers. A stale price stays visible and tagged, while borrowing waits for a fresh one.
- `PriceTag` in `site/src/ui.tsx` accepts the matching price and `Stored` receipt. Its full presentation shows issue/expiry, historical verification signer, agreement and oracle links. Compact variants on Last price and history open the same complete provenance. Their price and indivisible age text wrap as separate flex items to keep narrow fact columns readable. A stale tag explicitly says stale. Missing evidence is labelled unavailable rather than attributed to the current settings.
- `Ticket` and `TicketCard` in `site/src/ui.tsx` and `site/src/pages/Tickets.tsx` show the numbered stub, status stamp, loan terms and repayment controls. `Tickets` pairs each one with `Slab`, as the vault book does.
- `Num` is an underlined source button. `SourceView` shows its calculation or chain evidence in a `Drawer`.
- `Drawer` is a portalled native `<dialog>`: opening focuses Close, the background becomes inert, Tab/Shift+Tab wrap, Escape/backdrop/Close dismiss, and focus returns to the trigger. It also supports a provenance dialog above the price desk. `ConnectSheet` reuses it and loads optional wallet connectors when opened.
- Auction ceilings have a persistent label, an adjacent hint/error linked with `aria-describedby`, and `aria-invalid`. Invalid or nonpositive input disables Buy. The blank default comes from `auctionPrice()`; the per-second curve is a separate display estimate.

The wagmi configuration defers persisted-account restoration until after the static shell hydrates, so a connected counter reload matches its initial markup. The eager counter hydrates directly; Suspense is reserved for the lazy routes and price desk. The skip link preserves the current hash route and focuses `main[tabindex="-1"]`. Empty, reading, paused, wrong-network and transaction states use plain text. Motion is limited to live numbers/curve and the existing 420ms closing stamp. Reduced motion reduces animations and transitions to 1ms.

## Do's and Don'ts

Reuse `Slab`, `TicketCard`, `PriceTag`, `.pair` and the existing tokens before adding a new visual primitive. Use the primary red fill for the main action and neutral secondary controls for alternatives. Retain the distinction between realised cash-flow return and share-price return. Every repeated oracle amount needs the same receipt-backed provenance, including history and stale amounts.

For another view, start from the existing main spacing and heading scale, compose the shared objects, then check long values and keyboard operation at 320, 390 and 1440px. Keep artwork, gradients, extra font sizes and marketing sections out of this counter. Do not expand the catalogue above the selected quote or load a wallet SDK merely to show public prices.
