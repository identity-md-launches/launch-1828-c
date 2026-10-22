import { readFileSync } from "node:fs";
import { test, expect, type Page } from "@playwright/test";
import { createPublicClient, createWalletClient, http, defineChain } from "viem";

const RPC = "http://127.0.0.1:8547";
const state = () => JSON.parse(readFileSync(new URL("../../test/scratch/e2e-state.json", import.meta.url), "utf8"));
const abi = (n: string) => JSON.parse(readFileSync(new URL(`../../out/${n}.sol/${n}.json`, import.meta.url), "utf8")).abi;
const chain = defineChain({ id: 11155111, name: "Synthetic Sepolia", nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [RPC] } } });
const pub = createPublicClient({ chain, transport: http(RPC), cacheTime: 0 });
const rpc = async (method: string, params: unknown[] = []) => {
  const r = await fetch(RPC, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) }).then((r) => r.json());
  if (r.error) throw new Error(r.error.message);
  return r.result;
};
async function send(address: string, name: string, functionName: string, args: unknown[], account = state().borrower) {
  const w = createWalletClient({ chain, transport: http(RPC), account });
  const hash = await w.writeContract({ address: address as `0x${string}`, abi: abi(name), functionName, args });
  const receipt = await pub.waitForTransactionReceipt({ hash });
  expect(receipt.status).toBe("success");
}
async function loan() {
  const s = state();
  await send(s.nft, "MockCardNFT", "approve", [s.lending, 1n]);
  await send(s.lending, "CardLending", "borrow", [1n, 400_000_000n]);
}
async function auction() {
  await loan();
  await rpc("evm_increaseTime", [31 * 86400]); await rpc("evm_mine");
  await send(state().lending, "CardLending", "liquidate", [1n]);
  return await pub.getBlock();
}
async function withWallet(page: Page, account: string) {
  await page.addInitScript(([url, acct]) => {
    const listeners: Record<string, Function[]> = {};
    (window as any).ethereum = {
      on: (e: string, f: Function) => { (listeners[e] ??= []).push(f); }, removeListener: () => {},
      request: async ({ method, params }: { method: string; params: unknown[] }) => {
        if (method === "eth_accounts" || method === "eth_requestAccounts") return [acct];
        if (method === "eth_chainId") return "0xaa36a7";
        if (method === "wallet_switchEthereumChain" || method === "wallet_addEthereumChain") return null;
        if (method === "wallet_requestPermissions" || method === "wallet_getPermissions") return [{ parentCapability: "eth_accounts" }];
        if (method === "eth_sendTransaction" && !(params?.[0] as any)?.gas) {
          const estimate = await fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 2, method: "eth_estimateGas", params }) }).then((r) => r.json());
          if (estimate.error) throw Object.assign(new Error(estimate.error.message), estimate.error);
          params = [{ ...(params[0] as object), gas: `0x${(BigInt(estimate.result) * 125n / 100n).toString(16)}` }];
        }
        const r = await fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) }).then((r) => r.json());
        if (r.error) throw Object.assign(new Error(r.error.message), r.error);
        return r.result;
      },
    };
  }, [RPC, account]);
}
async function connect(page: Page) {
  await page.getByRole("button", { name: "Connect", exact: true }).first().click();
  await page.getByRole("button", { name: "Browser wallet", exact: true }).click();
  await expect(page.locator(".acct")).toBeVisible();
}
async function containedTabs(page: Page, count = 12) {
  for (const key of ["Tab", "Shift+Tab"]) {
    for (let i = 0; i < count; i++) {
      await page.keyboard.press(key);
      expect(await page.evaluate(() => !!document.activeElement?.closest("dialog[open]"))).toBe(true);
    }
  }
}

test.describe.configure({ mode: "serial" });
let snapshot: string;
const errors = new WeakMap<Page, string[]>();
test.beforeAll(async () => { expect(await rpc("evm_revert", [state().snapshot])).toBe(true); });
test.beforeEach(async ({ page }) => {
  snapshot = await rpc("evm_snapshot");
  const messages: string[] = []; errors.set(page, messages);
  page.on("pageerror", (e) => messages.push(e.message));
  page.on("console", (m) => { if (m.type() === "error") messages.push(m.text()); });
});
test.afterEach(async ({ page }) => { expect(await rpc("evm_revert", [snapshot])).toBe(true); expect(errors.get(page)).toEqual([]); });

test("three-class counter keeps its slab, slider and action on the first phone screen", async ({ page }) => {
  await page.goto("./");
  const action = page.getByRole("button", { name: "Open a ticket", exact: true });
  await expect(action).toBeVisible();
  await expect(page.locator("main .slab")).toHaveCount(3);
  await page.evaluate(() => document.fonts.ready);
  expect((await action.boundingBox())!.y + (await action.boundingBox())!.height).toBeLessThanOrEqual(844);
  await page.screenshot({ path: new URL("../../test/scratch/counter-390.png", import.meta.url).pathname });
  const loaded = await page.evaluate(() => performance.getEntriesByType("resource").map((e) => e.name));
  expect(loaded.some((url) => /wallet-connectors-|w3m-|index\.es-/.test(url))).toBe(false);
  await expect(page.getByRole("slider")).toBeVisible();
  await page.getByRole("button", { name: /Venusaur/ }).click();
  await expect(page.getByRole("button", { name: /Borrow limit/ })).toHaveText("$450.00");
  expect((await action.boundingBox())!.y + (await action.boundingBox())!.height).toBeLessThanOrEqual(844);
  for (const width of [320, 390, 1440]) {
    await page.setViewportSize({ width, height: 844 });
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  }
});

test("last price, desk and history retain full provenance after signer and panel rotation", async ({ page }) => {
  const s = state();
  await send(s.oracle, "CardOracle", "setPanel", [40, 28], s.owner);
  await page.goto("./");
  await expect(page.locator(".quote .tag")).toContainText("21 of 30 agreed");
  await expect(page.locator(".quote .tag-rows a")).toHaveAttribute("href", new RegExp(s.owner, "i"));
  await page.locator(".facts .tag-price").click();
  const source = page.getByRole("dialog", { name: "Attested price" });
  await expect(source).toContainText("Expires"); await expect(source).toContainText("21 of 30 agreed");
  await expect(source.getByRole("link", { name: "IdentityMD oracle explorer" })).toHaveAttribute("href", "https://explorer.imd.fun/oracle");
  await expect(source.getByRole("link", { name: /^Attestation / })).toHaveAttribute("href", /api\.imd\.fun\/oracle\/requests\/[0-9a-f-]{36}$/);
  await source.getByRole("button", { name: "Close", exact: true }).click();
  await page.getByRole("button", { name: "Price desk", exact: true }).last().click();
  const desk = page.getByRole("dialog", { name: "Price desk", exact: true });
  await expect(desk.locator(".desk-row > .tag")).toHaveCount(3);
  await expect(desk.locator(".desk-row > .tag").first()).toContainText("21 of 30 agreed");
  await desk.locator(".hist .tag-price").first().click();
  await expect(source).toContainText("Signer");
  await expect(source.locator(".src-rows a").first()).toHaveAttribute("href", new RegExp(s.owner, "i"));
  await containedTabs(page);
  await page.keyboard.press("Escape");
  await expect(desk).toBeVisible();
  expect(await page.evaluate(() => !!document.activeElement?.closest('.hist'))).toBe(true);
});

test("stale oracle amounts preserve provenance and forbid a fresh quote", async ({ page }) => {
  await rpc("evm_increaseTime", [86401]); await rpc("evm_mine");
  const b = await pub.getBlock(); await page.clock.setFixedTime(Number(b.timestamp) * 1000);
  await page.goto("./");
  await expect(page.locator(".quote .tag")).toContainText("stale");
  await expect(page.getByRole("button", { name: "Open a ticket", exact: true })).toHaveCount(0);
  await page.locator(".quote .tag-price").click();
  await expect(page.getByRole("dialog")).toContainText("Stale");
  await expect(page.getByRole("dialog").getByRole("link", { name: /^Attestation / })).toBeVisible();
});

test("skip keeps each route and focuses main; both dialogs trap and restore focus", async ({ page }) => {
  for (const path of ["borrow", "tickets", "vault", "auctions"]) {
    await page.goto(`./#/${path}`);
    await page.locator(".skip").focus(); await page.keyboard.press("Enter");
    expect(await page.evaluate(() => location.hash)).toBe(`#/${path}`);
    await expect(page.locator("main")).toBeFocused();
  }
  const connectButton = page.getByRole("button", { name: "Connect", exact: true }).first();
  await connectButton.click(); await containedTabs(page);
  await page.keyboard.press("Escape"); await expect(connectButton).toBeFocused();
  await page.goto("./");
  const limit = page.getByRole("button", { name: /Borrow limit/ });
  await limit.click(); await containedTabs(page);
  await page.keyboard.press("Escape"); await expect(limit).toBeFocused();
});

test("tickets show full slabs and two-place debt; elapsed unpaid interest is not realised", async ({ page }) => {
  await loan(); const s = state();
  await withWallet(page, s.borrower); await page.goto("./#/tickets"); await connect(page);
  await expect(page.locator(".tickets .slab")).toHaveCount(1);
  for (const text of ["Charizard", "PSA", "Base Set", "#4", "Cert 80011001"]) await expect(page.locator(".tickets .slab")).toContainText(text);
  await expect(page.getByRole("button", { name: /Live debt/ })).toHaveText(/^\$\d+\.\d{2}$/);
  await page.goto("./#/vault");
  const realised = page.getByRole("button", { name: /^Realised yield:/ });
  await expect(realised).toHaveText("0.0000%");
  const shareBefore = await page.getByRole("button", { name: /^Share price:/ }).innerText();
  await rpc("evm_increaseTime", [86400]); await rpc("evm_mine");
  await page.reload(); await expect(realised).toHaveText("0.0000%");
  await expect(page.getByRole("button", { name: /^Share price:/ })).not.toHaveText(shareBefore);
  await send(s.usdc, "MockUSDC", "approve", [s.lending, 500_000_000n]);
  await send(s.lending, "CardLending", "repay", [1n]);
  await page.reload(); await expect(realised).not.toHaveText("0.0000%");
  await realised.click();
  const source = page.getByRole("dialog");
  await expect(source).toContainText("$100,000.00"); await expect(source).toContainText(/Settlements\s*1/);
  // A persisted injected account must restore after the static counter shell hydrates.
  // The shared console/pageerror assertion catches React hydration mismatches on this reload.
  await page.goto("./"); await page.reload();
  await expect(page.locator(".acct")).toBeVisible();
  await expect(page.getByRole("heading", { name: "Borrow against a graded card" })).toBeVisible();
});

test("invalid auction maxima disable Buy and never send an approval or purchase", async ({ page }) => {
  const b = await auction(); await page.clock.setFixedTime(Number(b.timestamp) * 1000);
  await withWallet(page, state().buyer); await page.goto("./#/auctions"); await connect(page);
  const buy = page.getByRole("button", { name: /^Buy for/ });
  await expect(buy).toBeEnabled();
  const nonce = await pub.getTransactionCount({ address: state().buyer });
  for (const value of ["1.0000000", "0", "-1", "oops", "0.000000", "1e2"]) {
    await page.getByLabel("Max price").fill(value);
    await expect(buy).toBeDisabled();
    await expect(page.getByLabel("Max price")).toHaveAttribute("aria-invalid", "true");
    await expect(page.getByRole("alert")).toContainText("Enter a price above zero");
  }
  expect(await pub.getTransactionCount({ address: state().buyer })).toBe(nonce);
  await page.getByLabel("Max price").fill("1.00"); await expect(buy).toBeEnabled(); await buy.click();
  await expect(page.getByText("The auction price is above your max price.")).toBeVisible();
  const l = await pub.readContract({ address: state().lending, abi: abi("CardLending"), functionName: "loan", args: [1n] }) as { state: number };
  expect(l.state).toBe(2);
});

test("blank auction max buys with the chain quote even when the device clock leads 30 seconds", async ({ page }) => {
  const b = await auction(); await page.clock.setFixedTime(Number(b.timestamp + 30n) * 1000);
  await withWallet(page, state().buyer); await page.goto("./#/auctions"); await connect(page);
  await expect(page.getByRole("button", { name: /^Auction price:/ })).toHaveText(/^\$\d+\.\d{2}$/);
  await expect(page.getByLabel("Max price")).toHaveValue("");
  await page.getByRole("button", { name: /^Buy for/ }).click();
  await expect(page.getByText(/No\. 1 · sold \$/)).toBeVisible({ timeout: 30_000 });
});
