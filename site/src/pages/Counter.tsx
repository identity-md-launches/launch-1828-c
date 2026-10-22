import { useState } from "react";
import type { Hex } from "viem";
import { useAccount } from "wagmi";
import { ADDR } from "../config";
import { age, usd } from "../format";
import { useLoans, useNow, type Protocol } from "../data";
import { Num, Slab, readSrc } from "../ui";
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
        <p className="empty">No cards listed at the counter yet. The owner lists a card class with CardOracle.setClass; it shows here as soon as it does.</p>
      )}
      {p && cls && (
        <div className="counter">
          <div className="slabs" role="list" aria-label="Listed cards">
            {p.classes.map((c) => (
              <div role="listitem" key={c.classId}>
                <Slab template={c.template} grey={!c.fresh} selected={c.classId === cls.classId} onClick={() => setSel(c.classId)}
                  badge={c.fresh ? <span className="mono">{usd(c.fresh.price)}</span> : <span>No fresh price</span>} />
              </div>
            ))}
          </div>
          <Quote cls={cls} p={p} now={now}>
            {cls.fresh && <button type="button" className="primary" onClick={open}>Open a ticket</button>}
          </Quote>
        </div>
      )}
      {p && (
        <dl className="facts" aria-label="From the chain">
          <div><dt>Pool size</dt><dd><Num src={readSrc("Pool size", "CardPool.totalAssets()", ADDR.pool)}>{usd(p.totalAssets)}</Num></dd></div>
          <div><dt>Cards in custody</dt><dd><Num src={readSrc("Cards in custody", "CardLending.loan(1..nextLoanId-1), state Active or Auction", ADDR.lending)}>{custody ?? "…"}</Num></dd></div>
          <div><dt>Last price</dt><dd>{last ? (
            <Num src={readSrc("Last price", "CardOracle PriceStored event", ADDR.oracle, [["Issued", `${age(now - Number(last.issuedAt))} ago`]])}>{usd(last.price)} · {age(now - Number(last.issuedAt))} ago</Num>
          ) : <span className="mono">None yet</span>}</dd></div>
        </dl>
      )}
    </>
  );
}
