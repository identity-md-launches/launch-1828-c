import { useEffect, useState } from "react";
import { getAddress, type Abi } from "viem";
import { ADDR } from "../config";
import { client } from "../chain";
import { MockCardNFTAbi } from "../abi/MockCardNFT";
import { CardLendingAbi } from "../abi/CardLending";
import { date, quote, TERM, usd, pct } from "../format";
import { useBinder, useNow, type Protocol } from "../data";
import { Slab, Ticket, TxNote, useUi } from "../ui";
import { Quote } from "../Quote";
import { useTx, type Step } from "../tx";
import { askConnect } from "../Wallet";

export function Borrow({ p, query }: { p?: Protocol; query: URLSearchParams }) {
  const now = useNow();
  const tx = useTx();
  const { openDesk } = useUi();
  const binder = useBinder(tx.account);
  const [sel, setSel] = useState<bigint | null>(null);
  const [amount, setAmount] = useState(0n);
  const [review, setReview] = useState(false);
  const [opened, setOpened] = useState<{ amount: bigint; name: string } | null>(null);
  const want = query.get("class");

  const cards = (binder.data ?? []).map((c) => {
    const cls = p?.classes.find((k) => k.classId === c.classId);
    const status = !cls ? "Not listed" : cls.fresh ? "Eligible" : "Needs price";
    return { ...c, cls, status };
  });
  useEffect(() => {
    if (sel === null && want) {
      const hit = cards.find((c) => c.classId === want && c.status === "Eligible");
      if (hit) setSel(hit.tokenId);
    }
  }, [want, cards.length]); // eslint-disable-line react-hooks/exhaustive-deps
  const chosen = cards.find((c) => c.tokenId === sel);

  async function borrow() {
    if (!chosen || !tx.account) return;
    const steps: Step[] = [];
    const [approved, all] = await Promise.all([
      client.readContract({ address: ADDR.nft, abi: MockCardNFTAbi, functionName: "getApproved", args: [chosen.tokenId] }),
      client.readContract({ address: ADDR.nft, abi: MockCardNFTAbi, functionName: "isApprovedForAll", args: [tx.account, ADDR.lending] }),
    ]);
    if (!all && getAddress(approved) !== ADDR.lending)
      steps.push({ label: "1 of 2 · Let the counter hold this card", address: ADDR.nft, abi: MockCardNFTAbi as Abi, functionName: "approve", args: [ADDR.lending, chosen.tokenId] });
    steps.push({ label: `${steps.length + 1} of ${steps.length + 1} · Open the ticket`, address: ADDR.lending, abi: CardLendingAbi as Abi, functionName: "borrow", args: [chosen.tokenId, amount] });
    const ok = await tx.run(steps, "Ticket opened. The card is in custody; the AUREON is in your wallet.");
    if (ok) { setOpened({ amount, name: chosen.card.cardName }); setReview(false); setSel(null); }
  }

  if (!tx.account) {
    return (
      <>
        <h1>Your binder</h1>
        <p className="empty">Connect a wallet to see your cards. Quotes work without one on <a href="#/">the counter</a>.</p>
        <button type="button" className="primary" onClick={askConnect}>Connect</button>
      </>
    );
  }
  const q = quote(amount, p?.aprBps ?? 0n);
  return (
    <>
      <h1>Your binder</h1>
      {p && !p.wired && <p className="banner">Borrowing is closed: the pool is not yet bound to the lending contract (owner's one-time setLending).</p>}
      {opened && (
        <Ticket no={(p?.nextLoanId ?? 1n) - 1n} status="ACTIVE" tone="red" land
          rows={[["Card", opened.name], ["Principal", usd(opened.amount)], ["Due", date(BigInt(now) + TERM)]]}>
          <p className="fine" role="status">{tx.done}</p>
          <a className="secondary" href="#/tickets">See your tickets</a>
        </Ticket>
      )}
      {binder.isLoading && <p className="empty">Reading your cards…</p>}
      {binder.data && cards.length === 0 && <p className="empty">No cards in this wallet. Cards are issued by the card contract's owner on this testnet.</p>}
      <div className="binder" role="list" aria-label="Your cards">
        {cards.map((c) => (
          <div role="listitem" key={c.tokenId.toString()}>
            <Slab card={c.card} tokenId={c.tokenId} grey={c.status !== "Eligible"} selected={c.tokenId === sel}
              onClick={() => { setSel(c.tokenId); setReview(false); tx.reset(); }}
              badge={<span className={`chip ${c.status === "Eligible" ? "ok" : ""}`}>{c.status}</span>} />
          </div>
        ))}
      </div>
      {chosen && p && chosen.cls && chosen.status === "Eligible" && (
        <div className="panel">
          <Quote cls={chosen.cls} p={p} now={now} onAmount={setAmount}>
            {!review ? (
              <button type="button" className="primary" onClick={() => setReview(true)} disabled={amount === 0n}>Review ticket</button>
            ) : (
              <div className="review">
                <p>Ticket for <strong>{chosen.card.cardName}</strong>, token {chosen.tokenId.toString()}: borrow <span className="mono">{usd(amount)}</span>, receive <span className="mono">{usd(q.receive)}</span>, repay <span className="mono">{usd(q.repay)}</span> by {date(BigInt(now) + TERM)} at {pct(p.aprBps, 0)} APR. At most two wallet prompts: approve the card, then borrow.</p>
                <button type="button" className="primary" disabled={!tx.ready || !!tx.busy} onClick={borrow}>Open the ticket</button>
              </div>
            )}
            <TxNote tx={tx} />
          </Quote>
        </div>
      )}
      {chosen && chosen.status === "Needs price" && (
        <div className="panel"><p>No price for this card in the last 24h. <button type="button" className="link" onClick={() => openDesk(chosen.classId)}>Request one (0.5 IMD).</button></p></div>
      )}
      {chosen && chosen.status === "Not listed" && <div className="panel"><p>This card's class is not on the oracle's list, so the counter cannot lend on it.</p></div>}
    </>
  );
}
