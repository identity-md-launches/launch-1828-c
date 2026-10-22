# CardVault site

The existing five-screen Sepolia app: the counter, binder, tickets, vault and auction floor, plus the price desk. Vite, React, TypeScript and wagmi/viem; public RPC reads use Multicall3. Hash routes and relative asset URLs work at an IPFS gateway subpath.

## Install, preview and rebuild

```sh
cd site
npm ci
npm run dev
npm run typecheck
npm run build       # writes ../dist/ at the repository root
npm run preview     # serves that same export
```

The checked-in `dist/` at the **repository root** is the static export to pin. `site/dist/` is not an output. No runtime backend is needed. The publishing plane pins the export after review.

The counter's initial, unpriced shell is rendered from the same React components into `site/index.html`. After changing its header, intro, loading markup or styles, regenerate it before the build:

```sh
node scripts/prerender.mjs
npm run build
```

This script runs locally at build time and performs no price request. It embeds no prices, wallet state or chain snapshots. The same source stylesheet is also embedded in that shell so its first paint does not wait for app CSS. The small bootstrap starts hydration after the shell records its first contentful paint, with a frame-based fallback, then reads the RPC. Persisted wallet accounts restore after hydration, using wagmi SSR mode. Borrow, tickets, vault, auctions, price desk and transaction helpers are separate chunks. Coinbase and optional WalletConnect connector setup/load starts only when Connect opens; EIP-6963 injected discovery stays available.

## ABIs and deployment

```sh
forge build --offline      # repository root; contracts are unchanged
cd site
npm run abi
```

Typed `src/abi/*.ts` come from this repository's Foundry output. `reads.ts` contains only the generated functions/events used by the public read path; full exports remain available to lazy transaction pages. `hashes.json` records all five matching canonical deployment ABI hashes. Default addresses remain those of the supplied Sepolia deployment; this revision deploys nothing on a public chain.

## Configuration and repointing

Use the existing `.env.example` as the build-time configuration reference. Set the values in your local Vite environment and rebuild; no secrets belong in the export.

| Variable | Default / purpose |
| --- | --- |
| `VITE_MOCK_USDC` | `0x79d4f28dbcd48836f80fe3e851419e67c6ce639a` |
| `VITE_MOCK_CARD_NFT` | `0x4d1dd1082e3841dc9b6f900252a15b5ef11ec4ac` |
| `VITE_CARD_POOL` | `0x225e41fed68048d95a0c5f7d3a04f792c23cf585` |
| `VITE_CARD_ORACLE` | `0xa981bb206daf2ceb22b879ed6c62519f37332756` |
| `VITE_CARD_LENDING` | `0xecd0992da58c974f4fa882b2ec8bde44d3bce7db` |
| `VITE_RPC_URLS` | Publicnode, Ethpandaops, Sentio Sepolia RPCs, comma separated |
| `VITE_FROM_BLOCK` | `11920137`; include deployment so constructor signer events and all cash flows are in the history |
| `VITE_WALLETCONNECT_PROJECT_ID` | Empty by default; an existing project ID adds the optional WalletConnect row |

Wallets include EIP-6963 extensions, mobile links to MetaMask/Coinbase/Rabby/Phantom, and Coinbase Smart Wallet. Optional WalletConnect is retained. Wrong-network transactions wait for Sepolia. An alternative deployment needs all five addresses, its correct starting block and a compatible chain/multicall configuration; replacing addresses alone does not configure another chain.

The earlier live deployment check found no listed classes and no pool-to-lending binding. Those owner actions are required before live borrowing is available. The UI never substitutes fixture prices. AUREON is owner-minted and has no faucet. Oracle requests spend test IMD even if no valid answer arrives.

## Price provenance and lender returns

Each cached price retains the `OracleSignerSet` setting in effect at its `PriceStored` log, including rotations in the same block. It never uses today's signer to label an old price. For a registry signer, this is the historical verification registry address. Matching successful `submit`/`onPrice` calldata supplies signed panel counts; otherwise the immutable request snapshot supplies an explicitly labelled lower bound, with the full attestation linked. Incomplete scan history is labelled unavailable.

Last price, class prices and price history reuse the same tag. Compact tags open full provenance; expired prices remain explicitly stale. The attestation URL uses the first 16 bytes of the matching `oracleId` as a UUID.

Realised return is pool-wide net cash earnings divided by cumulative ERC-4626 deposited assets. For each settlement, earnings are **cash payment + reserve used − reserve held back − principal closed**. Extensions close no principal. Unpaid interest, auction marks and borrower surplus are excluded. The denominator includes repeated deposits and does not shrink on withdrawals; this is neither annualised nor an individual lender return. Share-price return remains separately labelled and includes accrued receivables. A missing cash-flow history is not displayed as zero yield.

## Interaction tests

```sh
forge build --offline      # repository root
cd site
npm run e2e               # requires the Chromium matching the installed Playwright
```

`e2e/setup.mjs` starts a disposable Anvil Sepolia chain, deploys the five original contracts plus the repository's TestIMD/MockIntake test helpers, lists three classes, issues real requests and accepts EIP-712 signed synthetic prices through `submit`. It rotates the signer after storage. There is no direct price-storage injection. Only Anvil's public synthetic accounts are used.

The fixture export and state live in `test/scratch/`, outside the delivered source/export. The original five flows cover disconnected quotes, two-transaction borrowing, repayment, deposit/withdrawal and auction start/buy. Seven revision tests cover the phone layout, provenance and signer/panel rotation, stale prices, skip/modal focus, slabs and realised returns, invalid bid ceilings and a clock-ahead auction buy. Snapshots isolate the regression scenarios. The synthetic wallet estimates gas with 25% headroom for next-block accrual; no transaction or amount validation is bypassed.

Actual commands, measurements, Better Interface coverage and limitations are recorded in [VALIDATION.md](VALIDATION.md). The implemented design system is [DESIGN.md](../DESIGN.md).
