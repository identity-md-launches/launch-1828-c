import { useState } from "react";
import type { Abi } from "viem";
import { ADDR } from "../config";
import { CardPoolAbi } from "../abi/CardPool";
import { MockUSDCAbi } from "../abi/MockUSDC";
import { parseUsd, usd, dateTime } from "../format";
import { useLoans, useNow, usePoolHistory, useWallet, type Protocol } from "../data";
import { Num, Slab, TxNote, readSrc } from "../ui";
import { useTx, type Step } from "../tx";
import { askConnect } from "../Wallet";
import { TicketCard } from "./Tickets";

function ShareChart({ pts }: { pts: { t?: number; price: number }[] }) {
  if (pts.length < 2) return <p className="fine">Share price history appears after two deposits or withdrawals.</p>;
  const W = 320, H = 80;
  const ys = pts.map((p) => p.price);
  const lo = Math.min(...ys) * 0.999, hi = Math.max(...ys) * 1.001;
  const d = pts.map((p, i) => `${i ? "L" : "M"}${(i / (pts.length - 1)) * W},${H - ((p.price - lo) / (hi - lo || 1)) * H}`).join(" ");
  return (
    <svg className="chart" viewBox={`0 0 ${W} ${H}`} role="img" aria-label={`Share price from ${ys[0].toFixed(6)} to ${ys[ys.length - 1].toFixed(6)}`}>
      <path d={d} fill="none" stroke="currentColor" strokeWidth="1.5" />
    </svg>
  );
}

export function Vault({ p }: { p?: Protocol }) {
  const now = useNow();
  const tx = useTx();
  const w = useWallet(tx.account, p?.imd);
  const hist = usePoolHistory();
  const loans = useLoans(p?.nextLoanId);
  const [dep, setDep] = useState("");
  const [wd, setWd] = useState("");
  const depAmt = parseUsd(dep), wdAmt = parseUsd(wd);

  const deposit = () => {
    if (!depAmt || !tx.account) return;
    const steps: Step[] = [];
    if ((w.data?.poolAllow ?? 0n) < depAmt) steps.push({ label: "Approve AUREON", address: ADDR.usdc, abi: MockUSDCAbi as Abi, functionName: "approve", args: [ADDR.pool, depAmt] });
    steps.push({ label: "Deposit", address: ADDR.pool, abi: CardPoolAbi as Abi, functionName: "deposit", args: [depAmt, tx.account] });
    tx.run(steps, "Deposited. Your shares are in your wallet.").then((ok) => ok && setDep(""));
  };
  const withdraw = () => {
    if (!wdAmt || !tx.account) return;
    tx.run([{ label: "Withdraw", address: ADDR.pool, abi: CardPoolAbi as Abi, functionName: "withdraw", args: [wdAmt, tx.account, tx.account] }], "Withdrawn to your wallet.").then((ok) => ok && setWd(""));
  };

  const util = p && p.totalAssets > 0n ? Number(((p.totalAssets - p.available) * 10_000n) / p.totalAssets) / 100 : 0;
  const sp = p ? Number(p.sharePrice) / 1e6 : 1;
  const history = hist.data?.points ?? [];
  const pts = history.filter((x) => x.shares > 0n).map((x) => ({ t: x.t, price: Number(x.assets * 10n ** 12n / x.shares) / 1e6 }));
  const realised = hist.data?.complete && hist.data.deposits > 0n ? Number(hist.data.earnings * 1_000_000n / hist.data.deposits) / 10_000 : undefined;
  if (p) pts.push({ t: now, price: sp });
  const book = (loans.data?.loans ?? []).filter((l) => l.state === 1 || l.state === 2);
  const maxW = w.data?.maxWithdraw ?? 0n;

  return (
    <>
      <h1>The vault</h1>
      <p className="lede">Lend AUREON (a test dollar) to the pool. Share price includes unpaid interest and auction marks. No promised APY.</p>
      {p && (
        <dl className="facts six">
          <div><dt>Total assets</dt><dd><Num src={readSrc("Total assets", "CardPool.totalAssets()", ADDR.pool, [["Rule", "available cash + netReceivable + covered reserve"]])}>{usd(p.totalAssets)}</Num></dd></div>
          <div><dt>Available cash</dt><dd><Num src={readSrc("Available liquidity", "CardPool.availableLiquidity()", ADDR.pool)}>{usd(p.available)}</Num></dd></div>
          <div><dt>Reserve</dt><dd><Num src={readSrc("Reserve", "CardPool.reserve()", ADDR.pool, [["Covered", usd(p.covered)]])}>{usd(p.reserve)} · {usd(p.covered)} covered</Num></dd></div>
          <div><dt>Utilisation</dt><dd><Num src={readSrc("Utilisation", "(totalAssets − availableLiquidity) / totalAssets", ADDR.pool)}>{util.toFixed(2)}%</Num></dd></div>
          <div><dt>Share price</dt><dd><Num className="brass" src={readSrc("Share price", "CardPool.convertToAssets(1e12)", ADDR.pool)}>{sp.toFixed(6)}</Num></dd></div>
          <div><dt>Share price return</dt><dd><Num className="brass" src={readSrc("Share price return", "share price / initial price (1.000000) − 1", ADDR.pool, [["Includes", "Unpaid accrued interest and current auction marks; not a realised return"]])}>{((sp - 1) * 100).toFixed(4)}%</Num></dd></div>
          <div><dt>Realised since inception</dt><dd><Num className="brass" src={readSrc("Realised yield", "CardPool.Settled + CardLending.Borrowed/Repaid/Extended/Purchased + CardPool.Deposit events", ADDR.pool,
            [["Net realised", usd(hist.data?.earnings)], ["Cumulative deposits", usd(hist.data?.deposits)], ["Settlements", hist.data?.settlements ?? "…"],
              ["Rule", "(settlement cash + reserve used − reserve held back − principal closed) / cumulative deposited assets"],
              ["Basis", "Pool-wide cash-flow return since deployment; not annualised or an individual lender return. Unpaid receivables and borrower surplus excluded."]])}>{realised === undefined ? "…" : `${realised.toFixed(4)}%`}</Num></dd></div>
        </dl>
      )}
      <ShareChart pts={pts} />
      <div className="vault-forms">
        {!tx.account ? (
          <div className="panel"><p>Connect to deposit or withdraw. AUREON has no faucet: only its owner can mint it.</p><button type="button" className="primary" onClick={askConnect}>Connect</button></div>
        ) : (
          <>
            <form className="panel" onSubmit={(e) => { e.preventDefault(); deposit(); }}>
              <h2>Deposit</h2>
              <label>Amount <span className="fine">Wallet {usd(w.data?.usdc)}</span>
                <input inputMode="decimal" autoComplete="off" name="deposit" value={dep} onChange={(e) => setDep(e.target.value)} placeholder="0.00" />
              </label>
              <button type="submit" className="primary" disabled={!tx.ready || !!tx.busy || !depAmt}>Deposit</button>
              <p className="fine">Two prompts if needed: approve, then deposit. AUREON has no faucet.</p>
            </form>
            <form className="panel" onSubmit={(e) => { e.preventDefault(); withdraw(); }}>
              <h2>Withdraw</h2>
              <label>Amount <span className="fine">Your shares {usd(w.data?.assets)} · now {usd(maxW)}</span>
                <input inputMode="decimal" autoComplete="off" name="withdraw" value={wd} onChange={(e) => setWd(e.target.value)} placeholder="0.00" />
              </label>
              <button type="button" className="link" onClick={() => setWd((Number(maxW) / 1e6).toFixed(6).replace(/\.?0+$/, ""))}>Max {usd(maxW)}</button>
              <button type="submit" className="primary" disabled={!tx.ready || !!tx.busy || !wdAmt || wdAmt > maxW}>Withdraw</button>
              <p className="fine">Lent cash comes back as tickets are repaid or sold, so part of a withdrawal may have to wait.</p>
            </form>
          </>
        )}
      </div>
      <TxNote tx={tx} />
      <h2 className="sect">The book</h2>
      <p className="lede">Every card backing the pool, with its ticket.{p ? <> Receivable <Num src={readSrc("Net receivable", "CardLending.netReceivable()", ADDR.lending, [["Expected shortfall", usd(p.shortfall)]])}>{usd(p.receivable)}</Num>.</> : null}</p>
      {loans.data && book.length === 0 && <p className="empty">No cards in custody. The book fills as collectors open tickets.</p>}
      {(["Active", "At auction"] as const).map((g) => {
        const rows = book.filter((l) => (g === "Active" ? l.state === 1 : l.state === 2));
        if (!rows.length) return null;
        return (
          <section key={g}>
            <h3>{g} <span className="mono">{rows.length}</span></h3>
            <div className="book">
              {rows.map((l) => (
                <div className="pair" key={l.id.toString()}>
                  <Slab card={l.card} tokenId={l.tokenId} badge={l.mark !== undefined ? <span className="mono">Mark {usd(l.mark)}</span> : undefined} />
                  {p && <TicketCard l={l} p={p} now={now} />}
                </div>
              ))}
            </div>
          </section>
        );
      })}
      {history.length > 0 && <p className="fine">Last pool event {history[history.length - 1].t ? dateTime(history[history.length - 1].t!) : ""}.</p>}
    </>
  );
}
