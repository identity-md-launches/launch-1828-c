import { useEffect, useState } from "react";
import { useAccount, useConnect, useDisconnect, useSwitchChain, type Connector } from "wagmi";
import { WALLET_ICONS } from "./wallet-icons";
import { OPEN_IN, isMobileBrowser } from "./open-in";
import { CHAIN_ID, WALLET_ADD_CHAIN, loadWallets } from "./config";
import { short } from "./format";
import { Drawer } from "./ui";

const svg = (s: string) => `data:image/svg+xml;utf8,${encodeURIComponent(s)}`;

export async function switchToSepolia(switchChainAsync: (a: { chainId: number }) => Promise<unknown>) {
  try {
    await switchChainAsync({ chainId: CHAIN_ID });
  } catch {
    const eth = (window as any).ethereum;
    if (eth) {
      await eth.request({ method: "wallet_addEthereumChain", params: [WALLET_ADD_CHAIN] }).catch(() => {});
      await switchChainAsync({ chainId: CHAIN_ID }).catch(() => {});
    }
  }
}

/** One connect control and its sheet. Opens on demand from anywhere via the `cv-connect` event. */
export function ConnectSheet() {
  const mobile = isMobileBrowser();
  const { address, isConnected, chainId } = useAccount();
  const { connectors, connect, isPending, variables, error } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChainAsync } = useSwitchChain();
  const [open, setOpen] = useState(false);
  const [menu, setMenu] = useState(false);
  const [loading, setLoading] = useState(false);
  const [loadError, setLoadError] = useState(false);
  useEffect(() => {
    const o = () => setOpen(true);
    addEventListener("cv-connect", o);
    return () => removeEventListener("cv-connect", o);
  }, []);
  useEffect(() => {
    if (!open) return;
    let active = true;
    setLoading(true); setLoadError(false);
    loadWallets().catch(() => { if (active) setLoadError(true); })
      .finally(() => { if (active) setLoading(false); });
    return () => { active = false; };
  }, [open]);
  useEffect(() => { if (isConnected) setOpen(false); }, [isConnected]);

  const named = connectors.some((c) => c.type === "injected" && c.id !== "injected");
  const listed = [...connectors.filter((c) => c.type === "injected"), ...connectors.filter((c) => c.type !== "injected")]
    .filter((c) => !(c.id === "injected" && named));
  const label = (c: Connector) => (c.id === "injected" ? "Browser wallet" : c.id === "coinbaseWalletSDK" && mobile ? "Coinbase Smart Wallet" : c.name);
  const icon = (c: Connector) => c.icon ?? (WALLET_ICONS[c.id] ? svg(WALLET_ICONS[c.id]!) : undefined);

  if (isConnected && address) {
    if (chainId !== CHAIN_ID) return <button type="button" className="cta" onClick={() => switchToSepolia(switchChainAsync)}>Switch to Sepolia</button>;
    return (
      <div className="acct">
        <button type="button" className="ghost mono" aria-expanded={menu} onClick={() => setMenu(!menu)}>{short(address)}</button>
        {menu && <button type="button" className="ghost" onClick={() => { setMenu(false); disconnect(); }}>Disconnect</button>}
      </div>
    );
  }
  return (
    <>
      <button type="button" className="cta" onClick={() => setOpen(true)}>Connect</button>
      {open && (
        <Drawer title="Connect a wallet" onClose={() => setOpen(false)}>
            {mobile && OPEN_IN.map((w) => (
              <a key={w.id} className="row" href={w.href(location.href)}>
                <span className="ic"><img width={28} height={28} src={svg(WALLET_ICONS[w.id]!)} alt="" /></span>
                <span>Open in {w.name}</span>
              </a>
            ))}
            {listed.filter((c) => !mobile || c.type !== "injected").map((c) => (
              <button type="button" className="row" key={c.uid} onClick={() => connect({ connector: c })} disabled={isPending}>
                <span className="ic">{icon(c) ? <img width={28} height={28} src={icon(c)} alt="" /> : null}</span>
                <span>{label(c)}{isPending && variables?.connector === c ? " · opening…" : ""}</span>
              </button>
            ))}
            {error && <p className="txnote err">{/rejected|denied/i.test(error.message) ? "You closed the wallet prompt. Pick a wallet to try again." : error.message.split("\n")[0]}</p>}
            {loading && <p className="fine" role="status">Loading more wallets…</p>}
            {loadError && <p className="err" role="status">Could not load more wallets. Close Connect and try again.</p>}
        </Drawer>
      )}
    </>
  );
}

export const askConnect = () => dispatchEvent(new Event("cv-connect"));
