import { createConfig, http } from "wagmi";
import { injected } from "wagmi/connectors";
import { defineChain, getAddress, type Address } from "viem";

const env = import.meta.env;

export const SITE_NAME = "CardVault";
export const SITE_DESCRIPTION = "Borrow test dollars against a graded card slab, or lend into the pool that holds them. Sepolia testnet.";
export const SITE_URL = typeof location !== "undefined" ? location.origin + location.pathname : "";
export const SITE_ICON_URL = SITE_URL ? new URL("favicon.svg", SITE_URL).href : "";

// Chain facts from network.json (Sepolia, 11155111).
const RPCS: string[] = (env.VITE_RPC_URLS as string | undefined)?.split(",").map((s) => s.trim()).filter(Boolean) ?? [
  "https://ethereum-sepolia-rpc.publicnode.com",
  "https://rpc.sepolia.ethpandaops.io",
  "https://sepolia.rpc.sentio.xyz",
];
export const PUBLIC_RPC_URLS = RPCS;
export const CHAIN_ID = Number(env.VITE_CHAIN_ID ?? 11155111);
export const EXPLORER = "https://sepolia.etherscan.io";
export const FROM_BLOCK = BigInt(env.VITE_FROM_BLOCK ?? 11920137);

export const chain = defineChain({
  id: CHAIN_ID,
  name: "Sepolia",
  nativeCurrency: { name: "Sepolia Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: RPCS } },
  blockExplorers: { default: { name: "Etherscan", url: EXPLORER } },
  contracts: { multicall3: { address: "0xcA11bde05977b3631167028862bE2a173976CA11" } },
  testnet: true,
});

export const WALLET_ADD_CHAIN = {
  chainId: "0xaa36a7",
  chainName: "Sepolia",
  rpcUrls: ["https://ethereum-sepolia-rpc.publicnode.com", "https://rpc.sepolia.ethpandaops.io", "https://sepolia.rpc.sentio.xyz"],
  nativeCurrency: { name: "Sepolia Ether", symbol: "ETH", decimals: 18 },
  blockExplorerUrls: ["https://sepolia.etherscan.io"],
};

const addr = (v: string | undefined, fallback: string): Address => getAddress(v && v.length === 42 ? v : fallback);

// Defaults are the verified addresses in deployment.json. Override with VITE_* (see .env.example).
export const ADDR = {
  usdc: addr(env.VITE_MOCK_USDC, "0x79d4f28dbcd48836f80fe3e851419e67c6ce639a"),
  nft: addr(env.VITE_MOCK_CARD_NFT, "0x4d1dd1082e3841dc9b6f900252a15b5ef11ec4ac"),
  pool: addr(env.VITE_CARD_POOL, "0x225e41fed68048d95a0c5f7d3a04f792c23cf585"),
  oracle: addr(env.VITE_CARD_ORACLE, "0xa981bb206daf2ceb22b879ed6c62519f37332756"),
  lending: addr(env.VITE_CARD_LENDING, "0xecd0992da58c974f4fa882b2ec8bde44d3bce7db"),
};

export const ORACLE_EXPLORER = "https://explorer.imd.fun/oracle";
export const ORACLE_API = "https://api.imd.fun/oracle/requests";
export const IMD_FAUCET = "https://imd.fun";

export const walletConnectProjectId = (env.VITE_WALLETCONNECT_PROJECT_ID as string | undefined) ?? "";

export const wagmiConfig = createConfig({
  chains: [chain],
  // Restore persisted accounts after the prerendered disconnected shell has hydrated.
  ssr: true,
  multiInjectedProviderDiscovery: true,
  // Public reads and injected discovery need no wallet SDK. Load optional connectors on Connect.
  connectors: [injected()],
  transports: { [chain.id]: http(RPCS[0]) },
});

let walletLoad: Promise<void> | undefined;
export function loadWallets() {
  return walletLoad ??= import("./wallet-connectors").then(({ registerWallets }) => registerWallets())
    .catch((error) => { walletLoad = undefined; throw error; });
}
