export const BPS = 10_000n;
export const YEAR = 365n * 86_400n;
export const TERM = 30n * 86_400n;
export const ceilDiv = (a: bigint, b: bigint) => (a === 0n ? 0n : (a - 1n) / b + 1n);

/** AUREON has six decimals; shown with two. */
export function usd(v: bigint | undefined, opts: { sign?: boolean } = {}): string {
  if (v === undefined) return "…";
  const neg = v < 0n;
  const a = neg ? -v : v;
  const cents = a / 10_000n; // floor to cents
  const whole = (cents / 100n).toLocaleString("en-US");
  const frac = (cents % 100n).toString().padStart(2, "0");
  return `${neg ? "-" : opts.sign ? "+" : ""}$${whole}.${frac}`;
}
export const pct = (bps: number | bigint, digits = 2) => `${(Number(bps) / 100).toFixed(digits)}%`;
export function parseUsd(s: string): bigint | undefined {
  const m = s.trim().replace(/[$,]/g, "").match(/^(\d*)(?:\.(\d{0,6}))?$/);
  if (!m || (m[1] === "" && !m[2])) return undefined;
  return BigInt(m[1] || "0") * 1_000_000n + BigInt((m[2] ?? "").padEnd(6, "0") || "0");
}
export function age(sec: number): string {
  const s = Math.max(0, Math.floor(sec));
  if (s < 90) return `${s}s`;
  if (s < 5400) return `${Math.round(s / 60)}m`;
  if (s < 172800) return `${Math.round(s / 3600)}h`;
  return `${Math.round(s / 86400)}d`;
}
export function dur(sec: number): string {
  const s = Math.max(0, Math.floor(sec));
  const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
  return d ? `${d}d ${h}h` : h ? `${h}h ${m}m` : `${m}m ${s % 60}s`;
}
export const date = (t: number | bigint) =>
  new Date(Number(t) * 1000).toLocaleDateString("en-GB", { day: "2-digit", month: "short", year: "numeric" });
export const dateTime = (t: number | bigint) =>
  new Date(Number(t) * 1000).toLocaleString("en-GB", { day: "2-digit", month: "short", hour: "2-digit", minute: "2-digit" });
export const short = (a: string) => `${a.slice(0, 6)}…${a.slice(-4)}`;

/** Quote for a fresh borrow of `amount` at `aprBps`, exactly as CardLending computes it. */
export function quote(amount: bigint, aprBps: bigint) {
  const fee = ceilDiv(amount * 100n, BPS);
  const interest = ceilDiv(amount * aprBps * TERM, BPS * YEAR);
  return { fee, receive: amount - fee, interest, repay: amount + interest, cost: fee + interest };
}
export const maxBorrow = (price: bigint) => (price * 4500n) / BPS;
export const interestFor = (principal: bigint, aprBps: bigint, secs: bigint) => ceilDiv(principal * aprBps * secs, BPS * YEAR);

/** CardLending.auctionPrice, client side, for a ticking display. */
export function auctionPriceAt(debt: bigint, startedAt: bigint, now: bigint): bigint {
  const DUR = 86_400n;
  let el = now - startedAt;
  if (el < 0n) el = 0n;
  if (el > DUR) el = DUR;
  return ceilDiv(debt * (12_000n * DUR - 7_000n * el), BPS * DUR);
}
