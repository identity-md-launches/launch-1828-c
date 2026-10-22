import { useQuery } from "@tanstack/react-query";
import { useEffect, useState } from "react";
import { getAddress, type Address, type Hex } from "viem";
import { ADDR } from "./config";
import { client, scanLogs, blockTime } from "./chain";
import { CardOracleAbi } from "./abi/CardOracle";
import { CardLendingAbi } from "./abi/CardLending";
import { CardPoolAbi } from "./abi/CardPool";
import { MockCardNFTAbi } from "./abi/MockCardNFT";
import { MockUSDCAbi } from "./abi/MockUSDC";
import { imdAbi } from "./abi/erc20";

const safe = async <T,>(p: Promise<T>): Promise<T | undefined> => {
  try { return await p; } catch { return undefined; }
};

export type Template = { cardName: string; cardNumber: string; setName: string; setSlug: string; cardSlug: string; gradeColumn: string };
export type Price = { price: bigint; issuedAt: bigint; expiresAt: bigint };
export type Stored = { classId: Hex; oracleId: Hex; price: bigint; issuedAt: bigint; expiresAt: bigint; tx: Hex; block: bigint };
export type ClassRow = {
  classId: Hex; version: number; template: Template; fresh?: Price; last?: Price; pending: Hex;
  stored?: Stored; history: OracleEvent[];
};
export type OracleEvent = { kind: "Requested" | "PriceStored" | "Failed" | "TimedOut"; classId?: Hex; intakeId?: Hex; tx: Hex; block: bigint; detail: string; stored?: Stored };

/** Seconds since epoch, ticking. */
export function useNow(ms = 1000) {
  const [now, set] = useState(() => Math.floor(Date.now() / 1000));
  useEffect(() => { const t = setInterval(() => set(Math.floor(Date.now() / 1000)), ms); return () => clearInterval(t); }, [ms]);
  return now;
}

/** Oracle catalogue, prices with their attestations, and the pool and lending state the counter needs. */
export function useProtocol() {
  return useQuery({
    queryKey: ["protocol"],
    refetchInterval: 30_000,
    queryFn: async () => {
      const o = { address: ADDR.oracle, abi: CardOracleAbi } as const;
      const l = { address: ADDR.lending, abi: CardLendingAbi } as const;
      const p = { address: ADDR.pool, abi: CardPoolAbi } as const;
      const [scan, block, aprBps, nextLoanId, totalAssets, available, reserve, covered, totalSupply, sharePrice, net,
        pPool, pOracle, pLending, wired, panelSize, quorum, signer, requestFee, paymentAsset] = await Promise.all([
        scanLogs(ADDR.oracle, CardOracleAbi),
        client.getBlock(),
        client.readContract({ ...l, functionName: "aprBps" }),
        client.readContract({ ...l, functionName: "nextLoanId" }),
        client.readContract({ ...p, functionName: "totalAssets" }),
        client.readContract({ ...p, functionName: "availableLiquidity" }),
        client.readContract({ ...p, functionName: "reserve" }),
        client.readContract({ ...p, functionName: "coveredReserve" }),
        client.readContract({ ...p, functionName: "totalSupply" }),
        client.readContract({ ...p, functionName: "convertToAssets", args: [10n ** 12n] }),
        client.readContract({ ...l, functionName: "netReceivable" }),
        client.readContract({ ...p, functionName: "paused" }),
        client.readContract({ ...o, functionName: "paused" }),
        client.readContract({ ...l, functionName: "paused" }),
        client.readContract({ ...p, functionName: "lending" }),
        client.readContract({ ...o, functionName: "panelSize" }),
        client.readContract({ ...o, functionName: "quorum" }),
        client.readContract({ ...o, functionName: "oracleSigner" }),
        client.readContract({ ...o, functionName: "requestFee" }),
        client.readContract({ ...o, functionName: "paymentAsset" }),
      ]);
      const latest = new Map<Hex, { version: number; enabled: boolean }>();
      const intakeClass = new Map<Hex, Hex>();
      const events: OracleEvent[] = [];
      const storedBy = new Map<Hex, Stored>();
      for (const e of scan.logs) {
        const a = e.args as Record<string, any>;
        const tx = e.transactionHash as Hex, block = e.blockNumber as bigint;
        if (e.eventName === "ClassSet") latest.set(a.classId, { version: Number(a.version), enabled: a.enabled });
        if (e.eventName === "Requested") {
          intakeClass.set(a.intakeId, a.classId);
          events.push({ kind: "Requested", classId: a.classId, intakeId: a.intakeId, tx, block, detail: `requested by ${a.payer}` });
        }
        if (e.eventName === "PriceStored") {
          const s: Stored = { classId: a.classId, oracleId: a.oracleId, price: a.price, issuedAt: a.issuedAt, expiresAt: a.expiresAt, tx, block };
          storedBy.set(a.classId, s);
          events.push({ kind: "PriceStored", classId: a.classId, tx, block, detail: "", stored: s });
        }
        if (e.eventName === "Failed") events.push({ kind: "Failed", intakeId: a.intakeId, classId: intakeClass.get(a.intakeId), tx, block, detail: `${a.agreed} of ${a.answered} agreed, status ${a.status}` });
        if (e.eventName === "TimedOut") events.push({ kind: "TimedOut", intakeId: a.intakeId, classId: intakeClass.get(a.intakeId), tx, block, detail: "no answer within two days" });
      }
      const ids = [...latest].filter(([, v]) => v.enabled).map(([k]) => k);
      const classes: ClassRow[] = await Promise.all(ids.map(async (classId) => {
        const [template, fresh, last, pending] = await Promise.all([
          client.readContract({ ...o, functionName: "template", args: [classId] }),
          safe(client.readContract({ ...o, functionName: "freshPrice", args: [classId] })),
          client.readContract({ ...o, functionName: "prices", args: [classId] }),
          client.readContract({ ...o, functionName: "pendingForClass", args: [classId] }),
        ]);
        return {
          classId, version: latest.get(classId)!.version, template: template as Template, fresh: fresh as Price | undefined,
          last: { price: last[0], issuedAt: last[1], expiresAt: last[2] }, pending: pending as Hex,
          stored: storedBy.get(classId), history: events.filter((e) => e.classId === classId).reverse(),
        };
      }));
      return {
        now: Number(block.timestamp), head: scan.head, classes, events: events.reverse(),
        aprBps: BigInt(aprBps), nextLoanId, totalAssets, available, reserve, covered, totalSupply, sharePrice,
        receivable: net[0], shortfall: net[1], wired: wired !== "0x0000000000000000000000000000000000000000" && getAddress(wired) === ADDR.lending,
        paused: { pool: pPool, oracle: pOracle, lending: pLending },
        panelSize: Number(panelSize), quorum: Number(quorum), signer: signer as Address, requestFee, imd: paymentAsset as Address,
      };
    },
  });
}
export type Protocol = NonNullable<ReturnType<typeof useProtocol>["data"]>;

export type Card = { game: string; set: string; cardName: string; cardNumber: string; grader: string; grade: string; certNumber: string };
export type Loan = {
  id: bigint; borrower: Address; tokenId: bigint; classId: Hex; principal: bigint; startedAt: bigint; maturity: bigint;
  priceIssuedAt: bigint; aprBps: bigint; state: number; auctionStartedAt: bigint; auctionDebt: bigint; card?: Card; mark?: bigint;
};
export const STATE = ["None", "Active", "Auction", "Closed"] as const;

/** Every loan 1..nextLoanId-1, read in one multicall round, with each card's label. */
export function useLoans(nextLoanId: bigint | undefined) {
  return useQuery({
    queryKey: ["loans", nextLoanId?.toString()],
    enabled: nextLoanId !== undefined,
    refetchInterval: 30_000,
    queryFn: async () => {
      const n = Number(nextLoanId!) - 1;
      const ids = Array.from({ length: n }, (_, i) => BigInt(i + 1));
      const [rows, events] = await Promise.all([
        Promise.all(ids.map((id) => client.readContract({ address: ADDR.lending, abi: CardLendingAbi, functionName: "loan", args: [id] }))),
        scanLogs(ADDR.lending, CardLendingAbi),
      ]);
      const loans: Loan[] = rows.map((r, i) => ({
        id: ids[i], borrower: r.borrower, tokenId: r.tokenId, classId: r.classId, principal: r.principal, startedAt: BigInt(r.startedAt),
        maturity: BigInt(r.maturity), priceIssuedAt: BigInt(r.priceIssuedAt), aprBps: BigInt(r.aprBps), state: Number(r.state),
        auctionStartedAt: BigInt(r.auctionStartedAt), auctionDebt: r.auctionDebt,
      }));
      await Promise.all(loans.map(async (ln) => {
        ln.card = (await safe(client.readContract({ address: ADDR.nft, abi: MockCardNFTAbi, functionName: "cardData", args: [ln.tokenId] }))) as Card | undefined;
        if (ln.state === 2) ln.mark = await safe(client.readContract({ address: ADDR.lending, abi: CardLendingAbi, functionName: "auctionMark", args: [ln.id] }));
      }));
      const outcome = new Map<bigint, { kind: string; amount: bigint; who?: Address; tx: Hex }>();
      for (const e of events.logs) {
        const a = e.args as Record<string, any>;
        if (e.eventName === "Repaid") outcome.set(a.loanId, { kind: "Repaid", amount: a.debt, who: a.payer, tx: e.transactionHash as Hex });
        if (e.eventName === "Purchased") outcome.set(a.loanId, { kind: "Sold", amount: a.price, who: a.receiver, tx: e.transactionHash as Hex });
      }
      const auctioned = new Set(events.logs.filter((e) => e.eventName === "AuctionStarted").map((e) => (e.args as any).loanId as bigint));
      return { loans, outcome, auctioned };
    },
  });
}

/** Pool events: share price history from ERC-4626 Deposit and Withdraw. */
export function usePoolHistory() {
  return useQuery({
    queryKey: ["poolHistory"],
    refetchInterval: 60_000,
    queryFn: async () => {
      const { logs } = await scanLogs(ADDR.pool, CardPoolAbi);
      const pts: { block: bigint; t?: number; kind: string; assets: bigint; shares: bigint }[] = [];
      for (const e of logs) {
        const a = e.args as Record<string, any>;
        if (e.eventName === "Deposit" || e.eventName === "Withdraw") pts.push({ block: e.blockNumber as bigint, kind: e.eventName, assets: a.assets, shares: a.shares });
      }
      await Promise.all(pts.slice(-40).map(async (p) => { p.t = await safe(blockTime(p.block)); }));
      return pts;
    },
  });
}

/** The wallet's cards: CardMinted and Transfer events, then ownerOf, cardData and classId. */
export function useBinder(owner: Address | undefined) {
  return useQuery({
    queryKey: ["binder", owner],
    enabled: !!owner,
    refetchInterval: 30_000,
    queryFn: async () => {
      const { logs } = await scanLogs(ADDR.nft, MockCardNFTAbi);
      const ids = new Set<bigint>();
      for (const e of logs) {
        const a = e.args as Record<string, any>;
        if (e.eventName === "CardMinted" && getAddress(a.holder) === owner) ids.add(a.tokenId);
        if (e.eventName === "Transfer" && a.to && getAddress(a.to) === owner) ids.add(a.tokenId);
      }
      const cards = await Promise.all([...ids].map(async (tokenId) => {
        const n = { address: ADDR.nft, abi: MockCardNFTAbi } as const;
        const [who, card, classId] = await Promise.all([
          client.readContract({ ...n, functionName: "ownerOf", args: [tokenId] }),
          client.readContract({ ...n, functionName: "cardData", args: [tokenId] }),
          client.readContract({ ...n, functionName: "classId", args: [tokenId] }),
        ]);
        return { tokenId, owner: who, card: card as Card, classId: classId as Hex };
      }));
      return cards.filter((c) => getAddress(c.owner) === owner).sort((a, b) => Number(a.tokenId - b.tokenId));
    },
  });
}

/** Balances and allowances for the connected wallet. */
export function useWallet(account: Address | undefined, imd: Address | undefined) {
  return useQuery({
    queryKey: ["wallet", account, imd],
    enabled: !!account,
    refetchInterval: 15_000,
    queryFn: async () => {
      const u = { address: ADDR.usdc, abi: MockUSDCAbi } as const;
      const [usdc, shares, maxWithdraw, surplus, imdBal, imdAllow, poolAllow, lendAllow] = await Promise.all([
        client.readContract({ ...u, functionName: "balanceOf", args: [account!] }),
        client.readContract({ address: ADDR.pool, abi: CardPoolAbi, functionName: "balanceOf", args: [account!] }),
        client.readContract({ address: ADDR.pool, abi: CardPoolAbi, functionName: "maxWithdraw", args: [account!] }),
        client.readContract({ address: ADDR.lending, abi: CardLendingAbi, functionName: "surplus", args: [account!] }),
        imd ? safe(client.readContract({ address: imd, abi: imdAbi, functionName: "balanceOf", args: [account!] })) : undefined,
        imd ? safe(client.readContract({ address: imd, abi: imdAbi, functionName: "allowance", args: [account!, ADDR.oracle] })) : undefined,
        client.readContract({ ...u, functionName: "allowance", args: [account!, ADDR.pool] }),
        client.readContract({ ...u, functionName: "allowance", args: [account!, ADDR.lending] }),
      ]);
      const assets = await client.readContract({ address: ADDR.pool, abi: CardPoolAbi, functionName: "convertToAssets", args: [shares] });
      return { usdc, shares, assets, maxWithdraw, surplus, imdBal: imdBal ?? 0n, imdAllow: imdAllow ?? 0n, poolAllow, lendAllow };
    },
  });
}
