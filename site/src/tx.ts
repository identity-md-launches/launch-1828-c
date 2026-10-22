import { useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { useAccount, useWriteContract } from "wagmi";
import { BaseError, ContractFunctionRevertedError, type Abi, type Address } from "viem";
import { client } from "./chain";
import { CHAIN_ID } from "./config";

const PLAIN: Record<string, string> = {
  StalePrice: "No price from the oracle in the last 24 hours for this card. Request one at the price desk.",
  TooMuchDebt: "That is more than 45% of the attested price. Lower the amount.",
  InsufficientLiquidity: "The pool does not have that much cash right now. Try a smaller amount or wait for repayments.",
  EnforcedPause: "This contract is paused by its guardian. Repayment still works; other actions wait.",
  DependenciesMismatch: "The pool is not yet bound to the lending contract (the owner's one-time setLending). Borrowing is closed until then.",
  NotBorrower: "Only the card's owner can do that.",
  WrongState: "This ticket is no longer in a state that allows that.",
  PriceNotNewer: "The oracle has no price newer than the one this ticket was written on. Request a price first.",
  NotLiquidatable: "This loan is not matured and its debt is within 60% of the latest price.",
  Slippage: "The auction price is above your max price.",
  RateAboveLimit: "The APR changed before your transaction landed.",
  ClassBusy: "A price request for this card is already open.",
  UnknownClass: "This card is not on the oracle's list.",
  WrongPayment: "The oracle fee changed. Reload and try again.",
  InvalidAmount: "Enter an amount above zero.",
  ERC4626ExceededMaxWithdraw: "More than you can withdraw now. Lent cash comes back as loans repay.",
  ERC20InsufficientBalance: "Your balance is too low for this.",
  ERC20InsufficientAllowance: "The approval was too small. Run the approval step again.",
};

export function plainError(e: unknown): string {
  if (e instanceof BaseError) {
    const rev = e.walk((x) => x instanceof ContractFunctionRevertedError) as ContractFunctionRevertedError | null;
    const name = rev?.data?.errorName;
    if (name && PLAIN[name]) return PLAIN[name];
    if (name) return `The contract refused: ${name}.`;
    if (/rejected|denied/i.test(e.message)) return "You declined it in your wallet. Nothing was sent.";
    return e.shortMessage;
  }
  return e instanceof Error ? e.message : String(e);
}

export type Step = { label: string; address: Address; abi: Abi; functionName: string; args: readonly unknown[] };

/** Runs one or more contract writes in order, simulating each first so reverts read in plain words. */
export function useTx() {
  const { address, chainId } = useAccount();
  const { writeContractAsync } = useWriteContract();
  const qc = useQueryClient();
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState<string | null>(null);
  const ready = !!address && chainId === CHAIN_ID;

  async function run(steps: Step[], doneText: string) {
    if (!address) return false;
    setError(null); setDone(null);
    try {
      for (const s of steps) {
        setBusy(s.label);
        await client.simulateContract({ account: address, address: s.address, abi: s.abi, functionName: s.functionName, args: s.args } as any);
        const hash = await writeContractAsync({ address: s.address, abi: s.abi, functionName: s.functionName, args: s.args } as any);
        const r = await client.waitForTransactionReceipt({ hash });
        if (r.status !== "success") throw new Error(`${s.label} reverted.`);
      }
      setDone(doneText);
      await qc.invalidateQueries();
      return true;
    } catch (e) {
      setError(plainError(e));
      return false;
    } finally {
      setBusy(null);
    }
  }
  return { run, busy, error, done, ready, account: address, reset: () => { setError(null); setDone(null); } };
}
