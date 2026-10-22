import { useState } from "react";
import type { Abi } from "viem";
import { ADDR } from "../config";
import { CardLendingAbi } from "../abi/CardLending";
import { MockUSDCAbi } from "../abi/MockUSDC";
import { auctionPriceAt, dur, parseUsd, usd, usd6 } from "../format";
import { useLoans, useNow, useWallet, type Loan, type Protocol } from "../data";
import { Num, Slab, Stamp, TxNote, readSrc } from "../ui";
import { useTx } from "../tx";
import { askConnect } from "../Wallet";
import { liveDebt } from "./Tickets";

function Curve({ l, now }: { l: Loan; now: number }) {
  const W = 300, H = 90, span = 86_400 * 1.25;
  const el = Math.min(now - Number(l.auctionStartedAt), span);
  const y = (bps: number) => H - 6 - ((bps - 4_000) / 9_000) * (H - 12);
  const x = (s: number) => (s / span) * W;
  const cur = Number(auctionPriceAt(10_000n, l.auctionStartedAt, BigInt(now)));
  return (
    <svg className="chart" viewBox={`0 0 ${W} ${H}`} role="img" aria-label={`Dutch price: 120% of debt falling to 50% over 24 hours, now ${(cur / 100).toFixed(1)}%`}>
      <line x1={0} x2={W} y1={y(10_000)} y2={y(10_000)} className="debtline" />
      <polyline points={`0,${y(12_000)} ${x(86_400)},${y(5_000)} ${W},${y(5_000)}`} fill="none" stroke="currentColor" strokeWidth="1.5" />
      <circle cx={x(el)} cy={y(cur)} r="4" className="dot" />
    </svg>
  );
}

function Lot({ l, now, p }: { l: Loan; now: number; p: Protocol }) {
  const tx = useTx();
  const w = useWallet(tx.account, p.imd);
  const price = auctionPriceAt(l.auctionDebt, l.auctionStartedAt, BigInt(now));
  const [max, setMax] = useState("");
  const maxAmt = parseUsd(max) ?? price;
  const toFloor = Number(l.auctionStartedAt) + 86_400 - now;
  const buy = () => {
    if (!tx.account) return askConnect();
    const steps = [];
    if ((w.data?.lendAllow ?? 0n) < maxAmt) steps.push({ label: "Approve AUREON", address: ADDR.usdc, abi: MockUSDCAbi as Abi, functionName: "approve", args: [ADDR.lending, maxAmt] });
    steps.push({ label: "Buy", address: ADDR.lending, abi: CardLendingAbi as Abi, functionName: "buy", args: [l.id, maxAmt, tx.account] });
    tx.run(steps, "Bought. The card is in your wallet.");
  };
  return (
    <article className="lot">
      <Slab card={l.card} tokenId={l.tokenId} />
      <div className="lot-body">
        <dl className="q-rows">
          <div><dt>Ticket</dt><dd className="mono">No. {l.id.toString().padStart(5, "0")}</dd></div>
          <div><dt>Frozen debt</dt><dd><Num src={readSrc("Frozen debt", `CardLending.loan(${l.id}).auctionDebt`, ADDR.lending)}>{usd(l.auctionDebt)}</Num></dd></div>
          <div><dt>Price now</dt><dd><Num className="tick red" src={readSrc("Auction price", `CardLending.auctionPrice(${l.id})`, ADDR.lending, [["Rule", "debt × (120% − 70% × elapsed/24h), floor 50%"]])}>{usd6(price)}</Num></dd></div>
          <div><dt>To floor</dt><dd className="mono">{toFloor > 0 ? dur(toFloor) : "At floor"}</dd></div>
        </dl>
        <Curve l={l} now={now} />
        <label>Max price <input inputMode="decimal" autoComplete="off" name={`max-${l.id}`} value={max} onChange={(e) => setMax(e.target.value)} placeholder={(Number(price) / 1e6).toFixed(2)} /></label>
        <button type="button" className="primary" disabled={(!!tx.account && !tx.ready) || !!tx.busy} onClick={buy}>Buy for {usd(price)}</button>
        <p className="fine">The card goes to the connected wallet. The price only falls, so your max covers it.</p>
        <TxNote tx={tx} />
      </div>
    </article>
  );
}

export function Auctions({ p }: { p?: Protocol }) {
  const now = useNow();
  const tx = useTx();
  const loans = useLoans(p?.nextLoanId);
  const all = loans.data?.loans ?? [];
  const live = all.filter((l) => l.state === 2);
  const ready = all.filter((l) => {
    if (l.state !== 1) return false;
    if (BigInt(now) >= l.maturity) return true;
    const cls = p?.classes.find((c) => c.classId === l.classId);
    return !!cls?.fresh && cls.fresh.issuedAt > l.priceIssuedAt && liveDebt(l, now) * 10_000n > cls.fresh.price * 6_000n;
  });
  const past = all.filter((l) => l.state === 3 && loans.data?.auctioned.has(l.id));
  return (
    <>
      <h1>The floor</h1>
      <p className="lede">Defaulted cards, priced in AUREON (a test dollar): 120% of debt falling to 50% over 24 hours, then held at the floor.</p>
      <TxNote tx={tx} />
      {loans.isLoading && <p className="empty">Reading the floor…</p>}
      {loans.data && live.length === 0 && <p className="empty">Nothing on the floor. Defaults land here for 24 hours.</p>}
      <div className="lots">{p && live.map((l) => <Lot key={l.id.toString()} l={l} now={now} p={p} />)}</div>
      {ready.length > 0 && (
        <>
          <h2 className="sect">Ready for auction</h2>
          <div className="lots">
            {ready.map((l) => (
              <article className="lot" key={l.id.toString()}>
                <Slab card={l.card} tokenId={l.tokenId} badge={<Stamp text={BigInt(now) >= l.maturity ? "MATURED" : "UNDERWATER"} />} />
                <div className="lot-body">
                  <p>Ticket {l.id.toString()} owes <span className="mono">{usd(liveDebt(l, now))}</span>. Anyone can start its auction.</p>
                  <button type="button" className="primary" disabled={(!!tx.account && !tx.ready) || !!tx.busy}
                    onClick={() => tx.account ? tx.run([{ label: "Start auction", address: ADDR.lending, abi: CardLendingAbi as Abi, functionName: "liquidate", args: [l.id] }], `Auction started for ticket ${l.id}.`) : askConnect()}>Start auction</button>
                </div>
              </article>
            ))}
          </div>
        </>
      )}
      {past.length > 0 && (
        <>
          <h2 className="sect">Past auctions</h2>
          <ul className="past">
            {past.map((l) => {
              const o = loans.data?.outcome.get(l.id);
              return <li key={l.id.toString()}><span>{l.card?.cardName ?? `Token ${l.tokenId}`}</span><span className="mono">No. {l.id.toString()} · {o?.kind === "Sold" ? `sold ${usd(o.amount)}` : `repaid ${usd(o?.amount ?? 0n)}`}</span></li>;
            })}
          </ul>
        </>
      )}
    </>
  );
}
