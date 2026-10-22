import { getAddress, type Abi } from "viem";
import { ADDR } from "../config";
import { CardLendingAbi } from "../abi/CardLending";
import { MockUSDCAbi } from "../abi/MockUSDC";
import { date, dur, interestFor, pct, usd } from "../format";
import { useLoans, useNow, useWallet, type Loan, type Protocol } from "../data";
import { Num, Slab, Ticket, TxNote, readSrc, useUi } from "../ui";
import { useTx, type Step } from "../tx";
import { askConnect } from "../Wallet";

export function ticketStatus(l: Loan, now: number, outcome?: { kind: string }) {
  if (l.state === 2) return { text: "AT AUCTION", tone: "red" as const };
  if (l.state === 3) return outcome?.kind === "Sold" ? { text: "SOLD", tone: "ink" as const } : { text: "REPAID", tone: "brass" as const };
  if (BigInt(now) >= l.maturity) return { text: "MATURED", tone: "red" as const };
  return { text: "ACTIVE", tone: "ink" as const };
}
export const liveDebt = (l: Loan, now: number) =>
  l.state === 2 ? l.auctionDebt : l.state === 1 ? l.principal + interestFor(l.principal, l.aprBps, BigInt(now) - l.startedAt) : 0n;

export function TicketCard({ l, p, now, outcome, actions }: { l: Loan; p: Protocol; now: number; outcome?: { kind: string; amount: bigint }; actions?: React.ReactNode }) {
  const st = ticketStatus(l, now, outcome);
  const fee = (l.principal * 100n + 9_999n) / 10_000n;
  const debt = liveDebt(l, now);
  const left = Number(l.maturity) - now;
  return (
    <Ticket no={l.id} status={st.text} tone={st.tone} land={l.state === 3}
      rows={[
        ["Card", l.card ? `${l.card.cardName} · ${l.card.grader} ${l.card.grade}` : `Token ${l.tokenId}`],
        ["Principal", usd(l.principal)],
        ["Fee", usd(fee)],
        ["APR", pct(l.aprBps, 0)],
        ["Issued", date(l.startedAt)],
        ["Due", `${date(l.maturity)}${l.state === 1 ? (left > 0 ? ` · ${dur(left)} left` : " · past due") : ""}`],
        [l.state === 3 ? (outcome?.kind === "Sold" ? "Sold for" : "Repaid") : "Debt now",
          l.state === 3 ? usd(outcome?.amount ?? 0n) : <Num key="d" className="tick" src={readSrc("Live debt", `CardLending.debtOf(${l.id})`, ADDR.lending, [["Rule", "principal + ceil(principal × APR × elapsed / (10000 × 365d))"]])}>{usd(debt)}</Num>],
      ]}>
      {actions}
    </Ticket>
  );
}

export function Tickets({ p }: { p?: Protocol }) {
  const now = useNow();
  const tx = useTx();
  const { openDesk } = useUi();
  const loans = useLoans(p?.nextLoanId);
  const w = useWallet(tx.account, p?.imd);
  if (!tx.account) {
    return (<><h1>Your tickets</h1><p className="empty">Connect a wallet to see your tickets.</p><button type="button" className="primary" onClick={askConnect}>Connect</button></>);
  }
  const mine = (loans.data?.loans ?? []).filter((l) => getAddress(l.borrower) === tx.account).reverse();
  const allowance = w.data?.lendAllow ?? 0n;

  const repay = (l: Loan) => {
    // Approve the debt plus one hour of interest so the approval still covers it when the repay lands.
    const need = l.state === 2 ? l.auctionDebt : liveDebt(l, now) + interestFor(l.principal, l.aprBps, 3600n);
    const steps: Step[] = [];
    if (allowance < need) steps.push({ label: "Approve AUREON", address: ADDR.usdc, abi: MockUSDCAbi as Abi, functionName: "approve", args: [ADDR.lending, need] });
    steps.push({ label: "Repay", address: ADDR.lending, abi: CardLendingAbi as Abi, functionName: "repay", args: [l.id] });
    tx.run(steps, `Ticket ${l.id} repaid. The card is back in your wallet.`);
  };
  const extend = (l: Loan) => {
    const need = interestFor(l.principal, l.aprBps, BigInt(now) - l.startedAt + 3600n);
    const steps: Step[] = [];
    if (allowance < need) steps.push({ label: "Approve interest", address: ADDR.usdc, abi: MockUSDCAbi as Abi, functionName: "approve", args: [ADDR.lending, need] });
    steps.push({ label: "Extend 30 days", address: ADDR.lending, abi: CardLendingAbi as Abi, functionName: "extend", args: [l.id, Number(p!.aprBps)] });
    tx.run(steps, `Ticket ${l.id} renewed for 30 days.`);
  };

  return (
    <>
      <h1>Your tickets</h1>
      <p className="lede">Debt in AUREON (a test dollar), accruing by the second.</p>
      {(w.data?.surplus ?? 0n) > 0n && (
        <div className="panel">
          <p>An auction sold your card above its debt. <span className="mono">{usd(w.data!.surplus)}</span> is yours.</p>
          <button type="button" className="primary" disabled={!tx.ready || !!tx.busy}
            onClick={() => tx.run([{ label: "Claim surplus", address: ADDR.lending, abi: CardLendingAbi as Abi, functionName: "claimSurplus", args: [tx.account] }], "Surplus claimed.")}>Claim surplus</button>
        </div>
      )}
      <TxNote tx={tx} />
      {loans.isLoading && <p className="empty">Reading tickets…</p>}
      {loans.data && mine.length === 0 && <p className="empty">No tickets yet. Your binder is at <a href="#/borrow">Borrow</a>.</p>}
      <div className="tickets">
        {mine.map((l) => {
          const cls = p?.classes.find((c) => c.classId === l.classId);
          const newer = !!cls?.fresh && cls.fresh.issuedAt > l.priceIssuedAt;
          const matured = l.state === 1 && BigInt(now) >= l.maturity;
          return (
            <div className="pair" key={l.id.toString()}>
            <Slab card={l.card} tokenId={l.tokenId} />
            <TicketCard l={l} p={p!} now={now} outcome={loans.data?.outcome.get(l.id)} actions={
              l.state === 1 || l.state === 2 ? (
                <>
                  {matured && <p className="warn">Anyone can send this card to auction now.</p>}
                  <button type="button" className="primary" disabled={!tx.ready || !!tx.busy} onClick={() => repay(l)}>Repay in full</button>
                  {l.state === 1 && !matured && (newer
                    ? <button type="button" className="secondary" disabled={!tx.ready || !!tx.busy} onClick={() => extend(l)}>Extend 30 days</button>
                    : <button type="button" className="secondary" onClick={() => openDesk(l.classId)}>Request a price (0.5 IMD)</button>)}
                  <p className="fine">Repay approves the debt plus one hour of interest, so the approval still covers it if the block lands later.{l.state === 1 && !matured && !newer ? " Extending needs a price newer than the one this ticket was written on." : ""}</p>
                </>
              ) : undefined
            } />
            </div>
          );
        })}
      </div>
    </>
  );
}
