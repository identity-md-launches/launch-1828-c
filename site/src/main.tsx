import { StrictMode } from "react";
import { createRoot, hydrateRoot } from "react-dom/client";
import { WagmiProvider } from "wagmi";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { wagmiConfig } from "./config";
import { App } from "./App";
import "./styles.css";

const qc = new QueryClient({ defaultOptions: { queries: { staleTime: 10_000, retry: 2 } } });

export const root = (
  <StrictMode>
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={qc}>
        <App />
      </QueryClientProvider>
    </WagmiProvider>
  </StrictMode>
);

if (typeof document !== "undefined") {
  const el = document.getElementById("root")!;
  // The checked-in counter shell paints before the RPC/wallet code arrives. Other hash routes
  // render normally so a static gateway needs no rewrites or server rendering.
  if ((!location.hash || location.hash === "#/") && el.hasChildNodes()) hydrateRoot(el, root);
  else createRoot(el).render(root);
}
