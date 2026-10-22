import { readFileSync } from "node:fs";
import { test, expect, type Page } from "@playwright/test";

const RPC = "http://127.0.0.1:8547";
const state = () => JSON.parse(readFileSync(new URL("../../test/scratch/e2e-state.json", import.meta.url), "utf8"));
const ACCOUNTS = {
  get borrower() { return state().borrower as string; },
  get lender() { return state().lender as string; },
  get buyer() { return state().buyer as string; },
};
const rpc = (method: string, params: unknown[] = []) =>
  fetch(RPC, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) }).then((r) => r.json());

/** A minimal injected wallet: anvil's unlocked accounts sign, everything else is forwarded to the node. */
async function withWallet(page: Page, account: string) {
  await page.addInitScript(([rpcUrl, acct]) => {
    const listeners: Record<string, Function[]> = {};
    (window as any).ethereum = {
      isMetaMask: false,
      on: (e: string, f: Function) => { (listeners[e] ??= []).push(f); },
      removeListener: () => {},
      request: async ({ method, params }: { method: string; params?: unknown[] }) => {
        if (method === "eth_requestAccounts" || method === "eth_accounts") return [acct];
        if (method === "eth_chainId") return "0xaa36a7";
        if (method === "wallet_switchEthereumChain" || method === "wallet_addEthereumChain") return null;
        if (method === "wallet_requestPermissions" || method === "wallet_getPermissions") return [{ parentCapability: "eth_accounts" }];
        // Like a browser wallet, leave gas headroom for accrual/storage changes in the next block.
        // Forwarding an unpadded node estimate can run out of gas at a zero-interest boundary.
        if (method === "eth_sendTransaction" && !(params?.[0] as any)?.gas) {
          const estimate = await fetch(rpcUrl, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 2, method: "eth_estimateGas", params }) }).then((x) => x.json());
          if (estimate.error) throw Object.assign(new Error(estimate.error.message), estimate.error);
          params = [{ ...(params![0] as object), gas: `0x${(BigInt(estimate.result) * 125n / 100n).toString(16)}` }];
        }
        const r = await fetch(rpcUrl, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) }).then((x) => x.json());
        if (r.error) throw Object.assign(new Error(r.error.message), { code: r.error.code, data: r.error.data });
        return r.result;
      },
    };
  }, [RPC, account] as const);
}
async function connect(page: Page) {
  await page.getByRole("button", { name: "Connect" }).first().click();
  await page.getByRole("button", { name: "Browser wallet" }).click();
  await expect(page.getByRole("button", { name: /0x/ })).toBeVisible();
}
function watchConsole(page: Page) {
  const errors: string[] = [];
  page.on("console", (m) => { if (m.type() === "error") errors.push(m.text()); });
  page.on("pageerror", (e) => errors.push(e.message));
  return errors;
}

test.describe.configure({ mode: "serial" });

test("quote without a wallet", async ({ page }) => {
  const errors = watchConsole(page);
  await page.goto("./");
  await expect(page.getByRole("heading", { name: "Borrow against a graded card" })).toBeVisible();
  await expect(page.getByText("Borrow up to")).toBeVisible({ timeout: 15_000 });
  // $2,000 attested price -> 45% = $900.00; receive = 900 - 9 fee.
  await expect(page.getByRole("button", { name: /Borrow limit/ })).toHaveText("$900.00");
  await expect(page.getByText("You receive")).toBeVisible();
  await expect(page.getByRole("button", { name: /You receive/ })).toHaveText("$891.00");
  await expect(page.getByText("2 of", { exact: false }).or(page.getByText("21 of 30 agreed"))).toBeVisible();
  await expect(page.getByRole("button", { name: "Open a ticket" })).toBeVisible();
  for (const path of ["#/borrow", "#/tickets", "#/vault", "#/auctions"]) { await page.goto(`./${path}`); await page.waitForTimeout(800); }
  expect(errors).toEqual([]);
});

test("borrow: open a ticket in two transactions", async ({ page }) => {
  await withWallet(page, ACCOUNTS.borrower);
  await page.goto("./#/borrow");
  await connect(page);
  const slabs = page.getByRole("list", { name: "Your cards" }).getByRole("button");
  await expect(slabs).toHaveCount(2, { timeout: 15_000 });
  await slabs.first().click();
  await page.getByRole("button", { name: "Review ticket" }).click();
  await page.getByRole("button", { name: "Open the ticket" }).click();
  await expect(page.getByText("Ticket opened.")).toBeVisible({ timeout: 30_000 });
  await expect(page.getByRole("img", { name: "Status: active" }).first()).toBeVisible();
  // Second card: a ticket we will send to auction later.
  await expect(slabs).toHaveCount(1, { timeout: 15_000 });
  await slabs.first().click();
  await page.getByRole("button", { name: "Review ticket" }).click();
  await page.getByRole("button", { name: "Open the ticket" }).click();
  await expect(page.getByText("Ticket opened.")).toBeVisible({ timeout: 30_000 });
});

test("repay a ticket", async ({ page }) => {
  // Exercise a nonzero interest payment rather than racing the opening block's zero-interest path.
  await rpc("evm_increaseTime", [60]);
  await rpc("evm_mine");
  await withWallet(page, ACCOUNTS.borrower);
  await page.goto("./#/tickets");
  await connect(page);
  const first = page.getByRole("article", { name: "Ticket 1" });
  await expect(first).toBeVisible({ timeout: 15_000 });
  await first.getByRole("button", { name: "Repay in full" }).click();
  await expect(page.getByText("Ticket 1 repaid.")).toBeVisible({ timeout: 30_000 });
  await expect(page.getByRole("article", { name: "Ticket 1" }).getByRole("img", { name: "Status: repaid" })).toBeVisible({ timeout: 15_000 });
});

test("deposit and withdraw", async ({ page }) => {
  await withWallet(page, ACCOUNTS.lender);
  await page.goto("./#/vault");
  await connect(page);
  await page.getByLabel(/^Amount Wallet/).fill("1000");
  await page.getByRole("button", { name: "Deposit", exact: true }).click();
  await expect(page.getByText("Deposited.")).toBeVisible({ timeout: 30_000 });
  await page.getByLabel(/^Amount Your shares/).fill("250");
  await page.getByRole("button", { name: "Withdraw", exact: true }).click();
  await expect(page.getByText("Withdrawn to your wallet.")).toBeVisible({ timeout: 30_000 });
  await expect(page.getByRole("heading", { name: "The book" })).toBeVisible();
  await expect(page.getByRole("article", { name: "Ticket 2" })).toBeVisible();
});

test("auction: start and buy", async ({ page }) => {
  await rpc("evm_increaseTime", [31 * 86_400]);
  await rpc("evm_mine");
  await withWallet(page, ACCOUNTS.buyer);
  await page.clock.install({ time: Date.now() + 31 * 86_400_000 });
  await page.goto("./#/auctions");
  await connect(page);
  await page.getByRole("button", { name: "Start auction" }).click();
  await expect(page.getByText("Auction started for ticket 2.")).toBeVisible({ timeout: 30_000 });
  const buy = page.getByRole("button", { name: /^Buy for/ });
  await expect(buy).toBeVisible({ timeout: 15_000 });
  await buy.click();
  // The lot leaves the floor and lands under past auctions with its outcome.
  await expect(page.getByText(/No\. 2 · sold \$/)).toBeVisible({ timeout: 30_000 });
});
