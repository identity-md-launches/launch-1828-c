import { useCallback, useEffect, useState } from "react";
import type { Hex } from "viem";
import { useAccount, useSwitchChain } from "wagmi";
import { CHAIN_ID } from "./config";
import { useProtocol } from "./data";
import { Drawer, SourceView, UiCtx, type Source } from "./ui";
import { ConnectSheet, switchToSepolia } from "./Wallet";
import { PriceDesk } from "./PriceDesk";
import { Counter } from "./pages/Counter";
import { Borrow } from "./pages/Borrow";
import { Tickets } from "./pages/Tickets";
import { Vault } from "./pages/Vault";
import { Auctions } from "./pages/Auctions";

const NAV = [["#/", "Counter"], ["#/borrow", "Borrow"], ["#/tickets", "Tickets"], ["#/vault", "Vault"], ["#/auctions", "Auctions"]] as const;
const TITLES: Record<string, string> = { "": "The counter", borrow: "Your binder", tickets: "Your tickets", vault: "The vault", auctions: "The floor" };

function useRoute() {
  const read = () => {
    const h = location.hash.replace(/^#\/?/, "");
    const [path, q] = h.split("?");
    return { path: path ?? "", query: new URLSearchParams(q ?? "") };
  };
  const [r, set] = useState(read);
  useEffect(() => {
    const f = () => { set(read()); window.scrollTo(0, 0); };
    addEventListener("hashchange", f);
    return () => removeEventListener("hashchange", f);
  }, []);
  return r;
}

export function App() {
  const { path, query } = useRoute();
  const proto = useProtocol();
  const p = proto.data;
  const { isConnected, chainId } = useAccount();
  const { switchChainAsync } = useSwitchChain();
  const [source, setSource] = useState<Source | null>(null);
  const [desk, setDesk] = useState<{ open: boolean; focus?: Hex }>({ open: false });
  const openDesk = useCallback((focus?: Hex) => setDesk({ open: true, focus }), []);
  const wrong = isConnected && chainId !== CHAIN_ID;
  useEffect(() => { document.title = `${TITLES[path] ?? "CardVault"} · CardVault`; }, [path]);

  const page = path === "borrow" ? <Borrow p={p} query={query} />
    : path === "tickets" ? <Tickets p={p} />
    : path === "vault" ? <Vault p={p} />
    : path === "auctions" ? <Auctions p={p} />
    : <Counter p={p} />;

  return (
    <UiCtx.Provider value={{ showSource: setSource, openDesk }}>
      <a className="skip" href="#main">Skip to content</a>
      <header className="top">
        <a className="brand" href="#/" aria-label="CardVault, the counter">
          <svg width="20" height="26" viewBox="0 0 20 26" aria-hidden="true"><rect x="1" y="1" width="18" height="24" rx="2" fill="none" stroke="currentColor" strokeWidth="2" /><rect x="1" y="1" width="18" height="7" fill="currentColor" /></svg>
          <span>CardVault</span>
        </a>
        <nav aria-label="Pages">
          {NAV.map(([h, t]) => <a key={h} href={h} aria-current={(h.slice(2) === path) ? "page" : undefined}>{t}</a>)}
        </nav>
        <button type="button" className="ghost desk-btn" onClick={() => openDesk()}>Price desk</button>
        <ConnectSheet />
      </header>
      {wrong && (
        <div className="banner" role="alert">This wallet is on another network. <button type="button" className="primary sm" onClick={() => switchToSepolia(switchChainAsync)}>Switch to Sepolia</button></div>
      )}
      {p?.paused.pool && <div className="banner">The pool is paused: deposits and borrowing wait. Withdrawals and repayment still work.</div>}
      {p?.paused.lending && <div className="banner">Lending is paused: new tickets, extensions and auctions wait. Repayment still works.</div>}
      {p?.paused.oracle && <div className="banner">The oracle is paused: price requests wait.</div>}
      {proto.error && <div className="banner">Could not reach Sepolia: {(proto.error as Error).message.split("\n")[0]}. Retrying.</div>}
      <main id="main" className={wrong ? "inert" : ""} {...((wrong ? { inert: "" } : {}) as object)}>{page}</main>
      <footer className="foot">
        <p>Sepolia testnet. AUREON is a test dollar.</p>
      </footer>
      {source && <Drawer title={source.title} onClose={() => setSource(null)}><SourceView s={source} /></Drawer>}
      {desk.open && <PriceDesk p={p} focus={desk.focus} onClose={() => setDesk({ open: false })} />}
    </UiCtx.Provider>
  );
}
