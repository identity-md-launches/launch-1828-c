// Starts anvil (chain id 11155111), deploys the five contracts from this repo's Foundry build, wires them,
// seeds cards, cash and an oracle price, builds the site against them and serves the export.
import { spawn, execSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { extname, join, resolve } from "node:path";
import { createPublicClient, createWalletClient, encodeAbiParameters, http, keccak256, pad, toHex, defineChain } from "viem";
import { privateKeyToAccount } from "viem/accounts";

const ROOT = resolve(import.meta.dirname, "../..");
const SITE = resolve(import.meta.dirname, "..");
export const RPC = "http://127.0.0.1:8547";
export const KEYS = [
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
];
const art = (n) => JSON.parse(readFileSync(join(ROOT, `out/${["TestIMD", "MockIntake"].includes(n) ? "Mocks" : n}.sol/${n}.json`), "utf8"));
const chain = defineChain({ id: 11155111, name: "anvil-sepolia", nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [RPC] } } });
const pub = createPublicClient({ chain, transport: http(RPC), pollingInterval: 50, cacheTime: 0 });
const rpc = (method, params = []) => fetch(RPC, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) }).then((r) => r.json());

export default async function globalSetup() {
  const anvil = spawn("anvil", ["--port", "8547", "--chain-id", "11155111", "--silent"], { stdio: "ignore" });
  for (let i = 0; i < 50; i++) { try { await pub.getChainId(); break; } catch { await new Promise((r) => setTimeout(r, 200)); } }
  await rpc("anvil_setCode", ["0xcA11bde05977b3631167028862bE2a173976CA11", readFileSync(join(import.meta.dirname, "multicall3.hex"), "utf8").trim()]);
  const owner = privateKeyToAccount(KEYS[0]);
  // The other roles are anvil's own unlocked accounts; the test wallet sends through eth_sendTransaction.
  const [, b, l, u] = (await rpc("eth_accounts")).result;
  const borrower = { address: b }, lender = { address: l }, buyer = { address: u };
  const w = createWalletClient({ chain, transport: http(RPC), account: owner });
  const deploy = async (n, args) => {
    const a = art(n);
    const hash = await w.deployContract({ abi: a.abi, bytecode: a.bytecode.object, args });
    return (await pub.waitForTransactionReceipt({ hash })).contractAddress;
  };
  const send = async (address, n, functionName, args, account = owner) => {
    const hash = await createWalletClient({ chain, transport: http(RPC), account }).writeContract({ address, abi: art(n).abi, functionName, args });
    const r = await pub.waitForTransactionReceipt({ hash });
    if (r.status !== "success") throw new Error(`${n}.${functionName} failed`);
  };
  const usdc = await deploy("MockUSDC", [owner.address]);
  const nft = await deploy("MockCardNFT", [owner.address]);
  const pool = await deploy("CardPool", [owner.address, usdc]);
  const imd = await deploy("TestIMD", []);
  const intake = await deploy("MockIntake", []);
  const oracle = await deploy("CardOracle", [owner.address, intake, imd, owner.address]);
  const lending = await deploy("CardLending", [owner.address, nft, pool, oracle, usdc]);
  await send(pool, "CardPool", "setLending", [lending]);
  const card = (cert, cardName = "Charizard", cardNumber = "4") => ({ game: "Pokemon", set: "Base Set", cardName, cardNumber, grader: "PSA", grade: "9", certNumber: cert });
  const classId = await pub.readContract({ address: nft, abi: art("MockCardNFT").abi, functionName: "computeClassId", args: [card("1")] });
  await send(oracle, "CardOracle", "setClass", [classId, { cardName: "Charizard", cardNumber: "4", setName: "Pokemon Base Set", setSlug: "pokemon-base-set", cardSlug: "charizard-4", gradeColumn: "PSA 9" }, true]);
  for (const cert of ["80011001", "80011002"]) await send(nft, "MockCardNFT", "mint", [borrower.address, card(cert)]);
  await send(usdc, "MockUSDC", "mint", [borrower.address, 5_000n * 10n ** 6n]);
  await send(usdc, "MockUSDC", "mint", [lender.address, 50_000n * 10n ** 6n]);
  await send(usdc, "MockUSDC", "mint", [buyer.address, 50_000n * 10n ** 6n]);
  await send(usdc, "MockUSDC", "approve", [pool, 100_000n * 10n ** 6n]);
  await send(pool, "CardPool", "deposit", [100_000n * 10n ** 6n, owner.address]);
  // Real request records and EIP-712 verification, signed only by anvil's public synthetic account.
  await send(imd, "TestIMD", "mint", [owner.address, 2n * 10n ** 18n]);
  await send(imd, "TestIMD", "approve", [oracle, 2n * 10n ** 18n]);
  const classes = [];
  for (const [i, name, number, dollars] of [[1, "Charizard", "4", 2000], [2, "Blastoise", "2", 1500], [3, "Venusaur", "15", 1000]]) {
    const id = await pub.readContract({ address: nft, abi: art("MockCardNFT").abi, functionName: "computeClassId", args: [card("1", name, number)] });
    if (id !== classId) await send(oracle, "CardOracle", "setClass", [id, { cardName: name, cardNumber: number, setName: "Pokemon Base Set", setSlug: "pokemon-base-set", cardSlug: `${name.toLowerCase()}-${number}`, gradeColumn: "PSA 9" }, true]);
    await send(oracle, "CardOracle", "requestPrice", [id]);
    const intakeId = await pub.readContract({ address: oracle, abi: art("CardOracle").abi, functionName: "pendingForClass", args: [id] });
    const requestId = pad(toHex(i, { size: 16 }), { size: 32, dir: "right" });
    const questionHash = keccak256(toHex(`synthetic question ${i}`));
    await send(oracle, "CardOracle", "bindRelay", [intakeId, requestId, questionHash]);
    const block = await pub.getBlock();
    const a = { requestId, chainId: 1n, questionHash, answerType: 3, answer: encodeAbiParameters([{ type: "uint256" }], [BigInt(dollars)]), figure: BigInt(dollars), fromBlock: 1n, toBlock: block.number, blockHash: block.hash, panelJobId: requestId, panelSize: 30, quorum: 21, agreed: 21, issuedAt: block.timestamp, expiresAt: block.timestamp + 86_400n };
    const digest = await pub.readContract({ address: oracle, abi: art("CardOracle").abi, functionName: "attestationDigest", args: [a] });
    await send(oracle, "CardOracle", "submit", [a, await owner.sign({ hash: digest })]);
    classes.push(id);
  }
  // Rotation must never change attribution of the already stored attestations.
  await send(oracle, "CardOracle", "setSigner", [buyer.address]);

  const outDir = join(ROOT, "test/scratch/e2e-dist");
  execSync("npx vite build", {
    cwd: SITE, stdio: "ignore",
    env: { ...process.env, CV_OUT_DIR: outDir, VITE_RPC_URLS: RPC, VITE_FROM_BLOCK: "0", VITE_MOCK_USDC: usdc, VITE_MOCK_CARD_NFT: nft, VITE_CARD_POOL: pool, VITE_CARD_ORACLE: oracle, VITE_CARD_LENDING: lending },
  });
  const types = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".svg": "image/svg+xml", ".png": "image/png", ".woff2": "font/woff2", ".woff": "font/woff" };
  const server = createServer((req, res) => {
    const p = decodeURIComponent((req.url ?? "/").split("?")[0]).replace(/^\/app\/?/, "/");
    const file = join(outDir, p === "/" ? "index.html" : p);
    try { res.writeHead(200, { "content-type": types[extname(file)] ?? "application/octet-stream" }); res.end(readFileSync(file)); }
    catch { res.writeHead(404); res.end(); }
  }).listen(4318);
  const snapshot = (await rpc("evm_snapshot")).result;
  writeFileSync(join(ROOT, "test/scratch/e2e-state.json"), JSON.stringify({ snapshot, borrower: b, lender: l, buyer: u, owner: owner.address, usdc, nft, pool, oracle, lending, imd, intake, classId, classes }, null, 2));
  return async () => { server.close(); anvil.kill(); };
}
