import type { Abi, Hex } from "viem";
import { ADDR, ORACLE_API } from "./config";
import { CardOracleAbi } from "./abi/CardOracle";
import { imdAbi } from "./abi/erc20";
import { oracleUuid } from "./chain";
import { age, dateTime, usd } from "./format";
import { useNow, useWallet, type Protocol } from "./data";
import { Drawer, PriceTag, TxNote, txLink } from "./ui";
import { useTx, type Step } from "./tx";
import { askConnect } from "./Wallet";

const fmtImd = (v: bigint) => `${(Number(v) / 1e18).toFixed(2)} IMD`;

export function PriceDesk({ p, focus, onClose }: { p?: Protocol; focus?: Hex; onClose: () => void }) {
  const now = useNow();
  const tx = useTx();
  const w = useWallet(tx.account, p?.imd);
  const rows = p ? [...p.classes].sort((a, b) => (a.classId === focus ? -1 : b.classId === focus ? 1 : 0)) : [];
  const request = (classId: Hex) => {
    if (!tx.account) return askConnect();
    const steps: Step[] = [];
    if ((w.data?.imdAllow ?? 0n) < p!.requestFee) steps.push({ label: "Approve test IMD", address: p!.imd, abi: imdAbi as Abi, functionName: "approve", args: [ADDR.oracle, p!.requestFee] });
    steps.push({ label: "Request price", address: ADDR.oracle, abi: CardOracleAbi as Abi, functionName: "requestPrice", args: [classId] });
    tx.run(steps, "Requested. A panel of 30 reads PriceCharting; the answer usually lands within minutes.");
  };
  return (
    <Drawer title="Price desk" onClose={onClose} side>
      <p className="fine">Each request costs {p ? fmtImd(p.requestFee) : "0.5 IMD"} of test IMD and asks {p?.panelSize ?? 30} oracle nodes to read PriceCharting; {p?.quorum ?? 21} must agree.</p>
      {tx.account && (
        <p className="fine">Your test IMD: <span className="mono">{fmtImd(w.data?.imdBal ?? 0n)}</span>{" "}
          <button type="button" className="link" disabled={!tx.ready || !!tx.busy}
            onClick={() => tx.run([{ label: "Mint test IMD", address: p!.imd, abi: imdAbi as Abi, functionName: "mint", args: [tx.account, 5n * 10n ** 17n] }], "0.5 test IMD minted to your wallet.")}>Get 0.5 test IMD</button>
        </p>
      )}
      <TxNote tx={tx} />
      {p && rows.length === 0 && <p className="empty">No card classes on the oracle's list yet.</p>}
      {rows.map((c) => (
        <section className="desk-row" key={c.classId}>
          <h3>{c.template.cardName} <span className="mono">#{c.template.cardNumber}</span></h3>
          <p className="fine">{c.template.setName} · {c.template.gradeColumn} · <a href={`https://www.pricecharting.com/game/${c.template.setSlug}/${c.template.cardSlug}`} target="_blank" rel="noreferrer">PriceCharting</a></p>
          <PriceTag price={c.last} stored={c.stored} stale={!c.fresh} now={now} classId={c.classId} />
          {c.pending !== "0x0000000000000000000000000000000000000000000000000000000000000000"
            ? <p className="fine">Request open: <span className="mono">{c.pending.slice(0, 10)}…</span></p>
            : <button type="button" className="secondary" disabled={!!p?.paused.oracle || (!!tx.account && !tx.ready) || !!tx.busy} onClick={() => request(c.classId)}>Request price (0.5 IMD)</button>}
          {c.history.length > 0 && (
            <ol className="hist">
              {c.history.slice(0, 6).map((e) => (
                <li key={e.tx + e.kind}>
                  <span>{e.kind === "PriceStored" ? "Price stored" : e.kind === "TimedOut" ? "Timed out" : e.kind}</span>
                  {e.stored ? <PriceTag price={e.stored} stored={e.stored} now={now} classId={c.classId} compact /> : <span>{e.detail}</span>}
                  <span>
                    <a href={txLink(e.tx)} target="_blank" rel="noreferrer">Tx</a>
                    {e.stored && <> · <a href={`${ORACLE_API}/${oracleUuid(e.stored.oracleId)}`} target="_blank" rel="noreferrer">Attestation</a></>}
                  </span>
                </li>
              ))}
            </ol>
          )}
        </section>
      ))}
      <p className="fine">AUREON has no faucet: only its owner can mint it.</p>
    </Drawer>
  );
}
