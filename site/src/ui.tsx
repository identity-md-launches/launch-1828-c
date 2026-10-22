import { createContext, useContext, useEffect, useRef, type ReactNode } from "react";
import { createPortal } from "react-dom";
import type { Hex } from "viem";
import { ADDR, EXPLORER, ORACLE_API, ORACLE_EXPLORER } from "./config";
import { oracleUuid } from "./chain";
import { age, date, dateTime, short, usd } from "./format";
import type { Card, Price, Stored, Template } from "./data";

export type Source = { title: string; lines: [string, ReactNode][]; links?: [string, string][] };
type Ctx = { showSource: (s: Source) => void; openDesk: (classId?: Hex) => void };
export const UiCtx = createContext<Ctx>({ showSource: () => {}, openDesk: () => {} });
export const useUi = () => useContext(UiCtx);

export const addrLink = (a: string) => `${EXPLORER}/address/${a}`;
export const txLink = (h: string) => `${EXPLORER}/tx/${h}`;

/** A number you can tap to see where it came from. */
export function Num({ children, src, className }: { children: ReactNode; src: Source; className?: string }) {
  const { showSource } = useUi();
  return (
    <button type="button" className={`num ${className ?? ""}`} onClick={() => showSource(src)} aria-label={`${src.title}: where this number comes from`}>
      {children}
    </button>
  );
}
export const readSrc = (title: string, call: string, contract: string, extra: [string, ReactNode][] = []): Source => ({
  title,
  lines: [["Read", <code key="c">{call}</code>], ["Contract", <a key="a" href={addrLink(contract)} target="_blank" rel="noreferrer">{short(contract)}</a>], ...extra],
  links: [["Contract on Etherscan", addrLink(contract)]],
});

/** The graded slab: label strip over a clear body. Typographic only. */
export function Slab({ card, template, tokenId, grey, children, onClick, selected, badge }: {
  card?: Card; template?: Template; tokenId?: bigint; grey?: boolean; children?: ReactNode; onClick?: () => void; selected?: boolean; badge?: ReactNode;
}) {
  const grader = card?.grader ?? template?.gradeColumn.split(" ")[0] ?? "";
  const grade = card ? card.grade : template?.gradeColumn.replace(/^\S+\s?/, "") ?? "";
  const name = card?.cardName ?? template?.cardName ?? "Unknown card";
  const number = card?.cardNumber ?? template?.cardNumber ?? "";
  const set = card?.set ?? template?.setName ?? "";
  const inner = (
    <>
      <div className="slab-label">
        <div className="slab-top">
          <span className="grader">{grader || "Grade"}</span>
          <span className="grade mono">{grade || (template?.gradeColumn ?? "")}</span>
        </div>
        <div className="slab-name">{name}</div>
        <div className="slab-meta">
          <span>{set}</span>
          <span className="mono">#{number}</span>
        </div>
        <div className="slab-meta">
          <span className="mono">{card ? `Cert ${card.certNumber}` : "Class"}</span>
          {tokenId !== undefined && <span className="mono">Token {tokenId.toString()}</span>}
        </div>
      </div>
      <div className="slab-body">
        {badge && <div className="slab-badge">{badge}</div>}
        {children}
      </div>
    </>
  );
  const cls = `slab${grey ? " grey" : ""}${selected ? " selected" : ""}`;
  return onClick ? (
    <button type="button" className={cls} onClick={onClick} aria-pressed={selected}>{inner}</button>
  ) : (
    <div className={cls}>{inner}</div>
  );
}

/** Rubber stamp. Lettering is SVG art so it reads as a stamp, not shouting copy. */
export function Stamp({ text, tone = "red", land }: { text: string; tone?: "red" | "ink" | "brass"; land?: boolean }) {
  const w = Math.max(64, text.length * 9 + 18);
  return (
    <svg className={`stamp ${tone}${land ? " land" : ""}`} width={w} height={26} viewBox={`0 0 ${w} 26`} role="img" aria-label={`Status: ${text.toLowerCase()}`}>
      <rect x="1" y="1" width={w - 2} height="24" rx="3" fill="none" stroke="currentColor" strokeWidth="2" />
      <text x={w / 2} y="18" textAnchor="middle" fill="currentColor" fontSize="14" fontWeight="600" letterSpacing="0.5">{text}</text>
    </svg>
  );
}

/** The price tag: never a price without where it came from. */
export function PriceTag({ price, stored, now, classId, compact = false, stale = false }: {
  price?: Price; stored?: Stored; now: number; classId: Hex; compact?: boolean; stale?: boolean;
}) {
  const { openDesk, showSource } = useUi();
  if (!price || price.issuedAt === 0n) {
    return (
      <div className="tag none">
        <p>No price in the last 24h. <button type="button" className="link" onClick={() => openDesk(classId)}>Request one (0.5 IMD).</button></p>
      </div>
    );
  }
  // A stored event belongs to this exact price. Never attach an earlier class version's receipt.
  const receipt = stored?.price === price.price && stored.issuedAt === price.issuedAt && stored.expiresAt === price.expiresAt ? stored : undefined;
  const uuid = receipt ? oracleUuid(receipt.oracleId) : undefined;
  const signer = receipt?.signer;
  const panel = receipt?.agreed !== undefined ? `${receipt.agreed} of ${receipt.panelSize} agreed`
    : receipt?.quorum !== undefined ? `At least ${receipt.quorum} agreed · panel ≥${receipt.panelSize}` : "See attestation for agreement";
  const old = stale || BigInt(now) > price.expiresAt || now - Number(price.issuedAt) > 86_400;
  const src: Source = {
    title: "Attested price",
    lines: [
      ["Price", usd(price.price)],
      ["Issued", dateTime(price.issuedAt)],
      ["Expires", dateTime(price.expiresAt)],
      ["Status", old ? "Stale · request a new price before borrowing" : "Fresh"],
      ["Panel", panel],
      ["Signer", signer ? <a key="s" href={addrLink(signer)} target="_blank" rel="noreferrer">{short(signer)}</a> : "Unavailable in scanned history"],
      ["Signer source", "OracleSignerSet event preceding this PriceStored (verification signer at acceptance)"],
      ["Read", <code key="r">CardOracle.prices(classId), PriceStored event</code>],
      ...(receipt ? [["Oracle id", <code key="o">{short(receipt.oracleId)}</code>] as [string, ReactNode]] : []),
    ],
    links: [
      ["IdentityMD oracle explorer", ORACLE_EXPLORER],
      ...(uuid ? [[`Attestation ${uuid.slice(0, 8)}`, `${ORACLE_API}/${uuid}`] as [string, string]] : []),
      ...(receipt ? [["PriceStored transaction", txLink(receipt.tx)] as [string, string]] : []),
      ["CardOracle contract", addrLink(ADDR.oracle)],
    ],
  };
  return (
    <div className={`tag${compact ? " compact" : ""}${old ? " stale" : ""}`}>
      <button type="button" className="tag-price num" onClick={() => showSource(src)} aria-label={`Attested price ${usd(price.price)}: where it came from`}>{usd(price.price)}{old && <span className="stale-label"> · stale</span>}</button>
      {compact && <span className="tag-age mono"> · {age(now - Number(price.issuedAt))} ago</span>}
      {!compact && <><dl className="tag-rows">
        <div><dt>Issued</dt><dd className="mono">{dateTime(price.issuedAt)} · {age(now - Number(price.issuedAt))} ago</dd></div>
        <div><dt>Expires</dt><dd className="mono">{dateTime(price.expiresAt)}</dd></div>
        <div><dt>Panel</dt><dd className="mono">{panel}</dd></div>
        <div><dt>Signer</dt><dd className="mono">{signer ? <a href={addrLink(signer)} target="_blank" rel="noreferrer">{short(signer)}</a> : "See attestation"}</dd></div>
      </dl>
      <p className="tag-links">
        <a href={ORACLE_EXPLORER} target="_blank" rel="noreferrer">Oracle explorer</a>
        {uuid && <a href={`${ORACLE_API}/${uuid}`} target="_blank" rel="noreferrer">Attestation {uuid.slice(0, 8)}</a>}
        <button type="button" className="link" onClick={() => openDesk(classId)}>Price desk</button>
      </p></>}
    </div>
  );
}

/** Pawn-style loan ticket with a perforated edge. */
export function Ticket({ no, rows, status, tone, land, children }: {
  no: bigint; rows: [string, ReactNode][]; status: string; tone?: "red" | "ink" | "brass"; land?: boolean; children?: ReactNode;
}) {
  return (
    <article className="ticket" aria-label={`Ticket ${no.toString()}`}>
      <header className="ticket-head">
        <span className="ticket-no mono">No. {no.toString().padStart(5, "0")}</span>
        <Stamp text={status} tone={tone} land={land} />
      </header>
      <dl className="ticket-rows">
        {rows.map(([k, v]) => <div key={k}><dt>{k}</dt><dd className="mono">{v}</dd></div>)}
      </dl>
      {children && <div className="ticket-actions">{children}</div>}
    </article>
  );
}

/** Native modal makes the background inert; Tab wraps inside and close restores the trigger. */
export function Drawer({ title, onClose, children, side }: { title: string; onClose: () => void; children: ReactNode; side?: boolean }) {
  const ref = useRef<HTMLDialogElement>(null);
  const close = useRef(onClose);
  close.current = onClose;
  useEffect(() => {
    const prev = document.activeElement as HTMLElement | null;
    const dialog = ref.current!;
    dialog.showModal();
    dialog.querySelector<HTMLElement>("button")?.focus();
    const key = (e: KeyboardEvent) => {
      if (e.key !== "Tab") return;
      const controls = [...dialog.querySelectorAll<HTMLElement>('button:not(:disabled), a[href], input:not(:disabled), select:not(:disabled), textarea:not(:disabled), [tabindex="0"]')]
        .filter((el) => el.getClientRects().length > 0);
      const first = controls[0], last = controls[controls.length - 1];
      if (!first) { e.preventDefault(); dialog.focus(); }
      else if (e.shiftKey && (document.activeElement === first || document.activeElement === dialog)) { e.preventDefault(); last.focus(); }
      else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
    };
    dialog.addEventListener("keydown", key);
    return () => {
      dialog.removeEventListener("keydown", key); dialog.close();
      if (prev?.isConnected) prev.focus();
      else document.getElementById("main")?.focus();
    };
  }, []);
  return createPortal(
    <dialog ref={ref} className={`sheet-bg${side ? " side" : ""}`} aria-label={title} aria-modal="true"
      onCancel={(e) => { e.preventDefault(); close.current(); }} onClick={(e) => { if (e.target === e.currentTarget) onClose(); }}>
      <div className="sheet">
        <div className="sheet-head"><h2>{title}</h2><button type="button" className="x" aria-label="Close" onClick={onClose}>×</button></div>
        {children}
      </div>
    </dialog>, document.body,
  );
}

export function SourceView({ s }: { s: Source }) {
  return (
    <>
      <dl className="src-rows">{s.lines.map(([k, v]) => <div key={k}><dt>{k}</dt><dd className="mono">{v}</dd></div>)}</dl>
      {s.links && <ul className="src-links">{s.links.map(([t, h]) => <li key={h}><a href={h} target="_blank" rel="noreferrer">{t}</a></li>)}</ul>}
    </>
  );
}

export function TxNote({ tx }: { tx: { busy: string | null; error: string | null; done: string | null } }) {
  return (
    <p className="txnote" role="status" aria-live="polite">
      {tx.busy ? `${tx.busy}: confirm in your wallet…` : tx.error ? <span className="err">{tx.error}</span> : tx.done ?? ""}
    </p>
  );
}

export const dateCell = (t: bigint) => date(t);
