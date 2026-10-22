import { useState } from "react";
import type { Hex } from "viem";
import { useAccount } from "wagmi";
import { ADDR } from "../config";
import { usd } from "../format";
import { useLoans, useNow, type Protocol } from "../data";
import { Num, PriceTag, Slab, readSrc } from "../ui";
import { Quote } from "../Quote";
import { askConnect } from "../Wallet";

export function Counter({ p }: { p?: Protocol }) {
  const now = useNow();
  const { isConnected } = useAccount();
  const [sel, setSel] = useState<Hex | null>(null);
  const loans = useLoans(p?.nextLoanId);
  const cls = p?.classes.find((c) => c.classId === sel) ?? p?.classes.find((c) => c.fresh) ?? p?.classes[0];
  const custody = loans.data?.loans.filter((l) => l.state === 1 || l.state === 2).length;
  const last = p?.events.find((e) => e.kind === "PriceStored")?.stored;

  const open = () => {
    if (!cls) return;
    location.hash = `#/borrow?class=${cls.classId}`;
    if (!isConnected) askConnect();
  };

  return (
    <>
      <div className="intro">
        <h1>Borrow against a graded card</h1>
        <p>Lock a slab, get AUREON (a test dollar) for 30 days: up to 45% of its attested price.</p>
      </div>
      {!p && <p className="empty">Reading the counter from Sepolia…</p>}
      {p && p.classes.length === 0 && (
        <p className="empty counter-empty">No card classes listed yet.</p>
      )}
      {p && cls && (
        <div className="counter">
          <Slab template={cls.template} grey={!cls.fresh} selected />
          <Quote cls={cls} p={p} now={now}>
            {cls.fresh && <button type="button" className="primary" onClick={open}>Open a ticket</button>}
          </Quote>
          {p.classes.length > 1 && <section className="catalog" aria-label="Choose another card">
            <h2>Other cards</h2>
            <div className="slabs" role="list" aria-label="Listed cards">
            {p.classes.filter((c) => c.classId !== cls.classId).map((c) => (
              <div role="listitem" key={c.classId}>
                <Slab template={c.template} grey={!c.fresh} onClick={() => setSel(c.classId)}
                  badge={<span>{c.fresh ? "Get a quote" : "No fresh price"}</span>} />
              </div>
            ))}
            </div>
          </section>}
        </div>
      )}
      {p && (
        <dl className="facts" aria-label="From the chain">
          <div><dt>Pool size</dt><dd><Num src={readSrc("Pool size", "CardPool.totalAssets()", ADDR.pool)}>{usd(p.totalAssets)}</Num></dd></div>
          <div><dt>Cards in custody</dt><dd><Num src={readSrc("Cards in custody", "CardLending.loan(1..nextLoanId-1), state Active or Auction", ADDR.lending)}>{custody ?? "…"}</Num></dd></div>
          <div><dt>Last price</dt><dd>{last ? (
            <PriceTag price={last} stored={last} now={now} classId={last.classId} compact stale={BigInt(p.now) > last.expiresAt || p.now - Number(last.issuedAt) > 86_400} />
          ) : <span className="mono">None yet</span>}</dd></div>
        </dl>
      )}
    </>
  );
}
