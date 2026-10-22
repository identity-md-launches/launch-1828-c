import { useEffect, useState, type ReactNode } from "react";
import { ADDR } from "./config";
import { date, maxBorrow, pct, quote, TERM, usd } from "./format";
import type { ClassRow, Protocol } from "./data";
import { Num, PriceTag, readSrc } from "./ui";

/** Attested price, borrow limit, amount slider and the full cost of a 30-day ticket. */
export function Quote({ cls, p, now, children, onAmount }: { cls: ClassRow; p: Protocol; now: number; children?: ReactNode; onAmount?: (a: bigint) => void }) {
  const limit = cls.fresh ? maxBorrow(cls.fresh.price) : 0n;
  const [share, setShare] = useState(100);
  useEffect(() => setShare(100), [cls.classId]);
  const step = 10_000n; // one cent
  const amount = (((limit * BigInt(share)) / 100n) / step) * step;
  useEffect(() => onAmount?.(amount), [amount]); // eslint-disable-line react-hooks/exhaustive-deps
  const q = quote(amount, p.aprBps);
  const costPct = amount > 0n ? Number((q.cost * 1_000_000n) / amount) / 10_000 : 0;
  return (
    <section className="quote" aria-label="Quote">
      <PriceTag price={cls.fresh} stored={cls.stored} panelSize={p.panelSize} quorum={p.quorum} signer={p.signer} now={now} classId={cls.classId} />
      {cls.fresh && (
        <>
          <div className="q-limit">
            <span>Borrow up to</span>
            <Num src={{ title: "Borrow limit", lines: [["Rule", "price × 4500 / 10000 (MAX_LTV_BPS)"], ["Price", usd(cls.fresh.price)], ["Limit", usd(limit)]] }} className="big">{usd(limit)}</Num>
          </div>
          <label className="q-slider">
            <span>Amount <span className="mono">{usd(amount)}</span></span>
            <input type="range" min={1} max={100} value={share} onChange={(e) => setShare(Number(e.target.value))} aria-valuetext={usd(amount)} />
          </label>
          <dl className="q-rows">
            <div><dt>You receive</dt><dd><Num src={{ title: "You receive", lines: [["Rule", "amount − ceil(amount × 1%) origination fee"], ["Fee", usd(q.fee)], ["Fee goes to", "the pool's loss reserve"]] }}>{usd(q.receive)}</Num></dd></div>
            <div><dt>You repay in 30 days</dt><dd><Num src={readSrc("APR", "CardLending.aprBps()", ADDR.lending, [["Rule", "amount + ceil(amount × APR × 30d / (10000 × 365d))"], ["APR", pct(p.aprBps)], ["Interest", usd(q.interest)]])}>{usd(q.repay)}</Num></dd></div>
            <div><dt>Due</dt><dd className="mono">{date(BigInt(now) + TERM)}</dd></div>
            <div><dt>Cost</dt><dd className="mono">{usd(q.cost)} · {costPct.toFixed(2)}% at {pct(p.aprBps, 0)} APR</dd></div>
          </dl>
        </>
      )}
      {children}
    </section>
  );
}
