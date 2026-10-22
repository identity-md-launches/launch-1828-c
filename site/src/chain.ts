import { createPublicClient, fallback, http, parseEventLogs, type Abi, type Address, type Hex } from "viem";
import { chain, FROM_BLOCK, PUBLIC_RPC_URLS } from "./config";

// Reads go over the public RPCs; viem batches concurrent reads into Multicall3 aggregate calls.
export const client = createPublicClient({
  chain,
  transport: fallback(PUBLIC_RPC_URLS.map((u) => http(u, { batch: { batchSize: 20 }, retryCount: 1 }))),
  batch: { multicall: { wait: 16, batchSize: 4096 } },
});

const CHUNK = 9_999n;

/** Every log of one contract since deployment, decoded against its ABI. Scanned in parallel chunks. */
export async function scanLogs<const A extends Abi>(address: Address, abi: A) {
  const head = await client.getBlockNumber();
  const ranges: [bigint, bigint][] = [];
  for (let from = FROM_BLOCK; from <= head; from += CHUNK + 1n) ranges.push([from, from + CHUNK > head ? head : from + CHUNK]);
  const parts = await Promise.all(
    ranges.map(async ([fromBlock, toBlock]) => {
      try {
        return await client.getLogs({ address, fromBlock, toBlock });
      } catch {
        // Some public endpoints refuse wide ranges: split once.
        const mid = (fromBlock + toBlock) / 2n;
        const [a, b] = await Promise.all([
          client.getLogs({ address, fromBlock, toBlock: mid }),
          client.getLogs({ address, fromBlock: mid + 1n, toBlock }),
        ]);
        return [...a, ...b];
      }
    }),
  );
  return { head, logs: parseEventLogs({ abi, logs: parts.flat(), strict: false }) };
}

export const blockTimes = new Map<bigint, number>();
export async function blockTime(n: bigint): Promise<number> {
  const hit = blockTimes.get(n);
  if (hit) return hit;
  const b = await client.getBlock({ blockNumber: n });
  blockTimes.set(n, Number(b.timestamp));
  return Number(b.timestamp);
}

/** api.imd.fun request uuid: the first 16 bytes of the PriceStored oracleId. */
export function oracleUuid(oracleId: Hex): string {
  const h = oracleId.slice(2, 34);
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20, 32)}`;
}
