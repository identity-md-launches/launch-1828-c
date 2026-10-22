# CardVault site

Static web app for CardVault on Sepolia (11155111): the counter (quote without a wallet), your binder (borrow),
your tickets (repay, extend, claim surplus), the vault (deposit, withdraw, the book) and the floor (Dutch
auctions), plus a price desk drawer. Vite + React + TypeScript, wagmi/viem for the wallet, reads over public
Sepolia RPCs batched into Multicall3. Hash routing (`#/borrow`, `#/tickets`, `#/vault`, `#/auctions`), relative
asset URLs (`base: "./"`), so `dist/` works from any IPFS gateway subpath or ENS name.

## Install, preview, rebuild

```sh
cd site
npm ci
npm run dev          # local dev server
npm run build        # tsc --noEmit, then vite build into site/dist
npm run preview      # serve the built dist/
```

The committed `site/dist/` is the export to pin; rebuild it after any source change.

## ABIs

`src/abi/*.ts` are generated from this repository's contracts:

```sh
forge build            # at the repo root
cd site && npm run abi # writes src/abi/<Contract>.ts and src/abi/hashes.json
```

`hashes.json` records keccak256 of each ABI against the `abiHash` in the launch's deployment record; all five match.

## Env and repointing addresses

Copy `.env.example` to `.env` and change what you need, then `npm run build`. Defaults are the verified
Sepolia deployment:

| Var | Default |
| --- | --- |
| `VITE_MOCK_USDC` | 0x79d4f28dbcd48836f80fe3e851419e67c6ce639a |
| `VITE_MOCK_CARD_NFT` | 0x4d1dd1082e3841dc9b6f900252a15b5ef11ec4ac |
| `VITE_CARD_POOL` | 0x225e41fed68048d95a0c5f7d3a04f792c23cf585 |
| `VITE_CARD_ORACLE` | 0xa981bb206daf2ceb22b879ed6c62519f37332756 |
| `VITE_CARD_LENDING` | 0xecd0992da58c974f4fa882b2ec8bde44d3bce7db |
| `VITE_RPC_URLS` | publicnode, ethpandaops, sentio Sepolia RPCs (comma separated, tried in order) |
| `VITE_FROM_BLOCK` | 11920137 (deployment block; event scans start here) |
| `VITE_WALLETCONNECT_PROJECT_ID` | empty. Set your own to add a WalletConnect row |

Wallets: EIP-6963 browser extensions (each by name), "Open in MetaMask / Coinbase Wallet / Rabby / Phantom"
on phones, Coinbase Smart Wallet, and WalletConnect only when a project id is supplied. No relay or account is
needed otherwise.

## State of the live deployment (read 2026-10-22)

`CardPool.lending()` is still the zero address and no `ClassSet` event exists, so the live counter shows its
empty state and the binder shows a "borrowing is closed" banner until the owner calls `CardPool.setLending`
and `CardOracle.setClass`. Test IMD's `mint(address,uint256)` is public on Sepolia, so the price desk offers
"Get 0.5 test IMD". AUREON is owner-minted only: there is no faucet.

## e2e against anvil

```sh
forge build                 # repo root
cd site && npx playwright install chromium   # once
npm run e2e
```

`e2e/setup.mjs` starts anvil with chain id 11155111, installs Multicall3, deploys the five contracts from
`out/`, binds pool to lending, lists one class, mints two cards, seeds cash and writes a fresh oracle price
into storage (the real oracle callback needs the IdentityMD signer). It builds the site against those
addresses into `e2e/.dist` and serves it. `e2e/flows.spec.ts` drives an injected test wallet backed by
anvil's unlocked accounts through: quote without a wallet (and zero console errors on all five pages
disconnected), borrow (approve + borrow), repay, deposit/withdraw, and auction start + buy.

## Validation run (2026-10-23)

| Check | Command | Result |
| --- | --- | --- |
| Typecheck | `npx tsc --noEmit` | pass, 0 errors |
| Production build | `npm run build` | pass, `dist/` 2.9 MB (wallet SDKs are lazy chunks) |
| ABI hashes | `npm run abi` | 5/5 match deployment abiHash |
| e2e | `npm run e2e` | 5 passed: quote, borrow, repay, deposit/withdraw, auction buy |
| Design probe | `node .imd/reads/skills/design-critic/scripts/taste.mjs site/dist --out test/scratch/taste` | 16/16 checks passed at 320, 390, 1440 |

Fixes made from these runs: the borrow and auction success notes unmounted with the card or lot they
belonged to (moved the status line outside); e2e seeding used wrong test accounts (now reads `eth_accounts`).

Limitations, stated plainly:
- Lighthouse was not run; no performance or accessibility score is claimed. The main chunk is ~180 kB gzip.
- The probe and e2e see the live Sepolia counter empty (no classes listed), so a real attested price on
  Sepolia could not be shown; the price tag, quote and attestation links were exercised on anvil only, where
  no `PriceStored` event exists, so the attestation uuid link was not exercised end to end.
- "21 of 30 agreed" shows the oracle's configured quorum and panel; the per-attestation agreed count is not
  stored on chain and is in the linked api.imd.fun record.
- The extend, price request and claim-surplus flows are wired but not covered by e2e.
- After a buy, the lot leaves the floor and its outcome appears under past auctions; the per-lot success
  line is not kept.
- Pinning to IPFS is done by the publisher from the committed `dist/`, not by this repository.
