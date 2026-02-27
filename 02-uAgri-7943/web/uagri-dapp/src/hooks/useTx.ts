"use client";

import * as React from "react";
import { useChainId, usePublicClient, useWriteContract } from "wagmi";
import { useToaster } from "@/components/tx/ToasterProvider";

export function useTx() {
  const chainId = useChainId();
  const client = usePublicClient();
  const { writeContractAsync } = useWriteContract();

  const {
    createTx,
    updateTx,
    completeTxSuccess,
    completeTxError,
    notify,
    registerRetry,
    openTxModal
  } = useToaster();

  const waitForReceipt = React.useCallback(
    async (txId: string, txHash: `0x${string}`, title: string) => {
      if (!client) {
        completeTxError(txId, "Public client is unavailable to track this transaction.");
        notify({ title: "Tracking error", description: "Could not watch transaction receipt.", tone: "bad", txId });
        return;
      }

      try {
        const receipt = await client.waitForTransactionReceipt({ hash: txHash, confirmations: 1 });
        if (receipt.status === "success") {
          completeTxSuccess(txId, { chainId });
          notify({
            title: "Success",
            description: "Transaction confirmed on-chain.",
            tone: "good",
            txId
          });
        } else {
          const msg = "Transaction reverted on-chain.";
          completeTxError(txId, msg, { chainId });
          notify({ title: "Error", description: msg, tone: "bad", txId });
        }
      } catch (e: any) {
        const msg = e?.shortMessage || e?.message || "Transaction confirmation failed.";
        completeTxError(txId, msg, { chainId });
        notify({ title: "Error", description: msg, tone: "bad", txId });
      }
    },
    [client, completeTxError, completeTxSuccess, notify, chainId]
  );

  const sendTxInternal = React.useCallback(
    async (
      args: Parameters<typeof writeContractAsync>[0] & { title?: string },
      attempt = 1,
      retryOfTxId?: string
    ) => {
      const title = args.title ?? "Transaction pending";

      const txId = createTx({
        title,
        chainId,
        stage: "pending",
        pendingPhase: "wallet",
        attempts: attempt,
        retryOfTxId,
        address: (args as any)?.address?.toString?.(),
        functionName: String((args as any)?.functionName ?? "")
      });

      registerRetry(txId, async () => {
        await sendTxInternal(args, attempt + 1, txId);
      });

      notify({ title: "Pending", description: "Confirm in your wallet...", tone: "warn", txId });

      try {
        const txHash = (await writeContractAsync(args as any)) as `0x${string}`;

        updateTx(txId, {
          stage: "pending",
          pendingPhase: "chain",
          hash: txHash,
          chainId
        });

        notify({
          title: "Submitted",
          description: "Waiting for on-chain confirmation...",
          tone: "warn",
          txId
        });

        openTxModal(txId);
        void waitForReceipt(txId, txHash, title);

        return txHash;
      } catch (e: any) {
        const msg = e?.shortMessage || e?.message || "Transaction rejected.";
        completeTxError(txId, msg, { chainId });
        notify({ title: "Error", description: msg, tone: "bad", txId });
        throw e;
      }
    },
    [chainId, createTx, registerRetry, notify, writeContractAsync, updateTx, waitForReceipt, completeTxError, openTxModal]
  );

  const sendTx = React.useCallback(
    async (args: Parameters<typeof writeContractAsync>[0] & { title?: string }) => {
      return sendTxInternal(args, 1, undefined);
    },
    [sendTxInternal]
  );

  return { sendTx };
}
