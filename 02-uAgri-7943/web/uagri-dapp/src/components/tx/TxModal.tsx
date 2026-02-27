"use client";

import * as React from "react";
import * as Dialog from "@radix-ui/react-dialog";
import { Copy, ExternalLink, Loader2, CheckCircle2, XCircle, RotateCcw } from "lucide-react";
import { Button } from "@/components/ui/Button";
import { Card } from "@/components/ui/Card";
import { cn } from "@/lib/cn";
import { explorerTxUrl } from "@/lib/explorer";
import { useToaster } from "./ToasterProvider";

export default function TxModal({
  open,
  onOpenChange
}: {
  open: boolean;
  onOpenChange: (v: boolean) => void;
}) {
  const { activeTx, canRetry, retryTx } = useToaster();

  const icon =
    activeTx?.stage === "pending" ? (
      <Loader2 className="animate-spin text-primary" />
    ) : activeTx?.stage === "success" ? (
      <CheckCircle2 className="text-good" />
    ) : activeTx?.stage === "error" ? (
      <XCircle className="text-bad" />
    ) : null;

  const description =
    activeTx?.stage === "pending"
      ? activeTx.pendingPhase === "wallet"
        ? "Waiting for wallet confirmation."
        : "Submitted on-chain. Waiting for confirmation."
      : activeTx?.stage === "success"
      ? "Transaction confirmed."
      : activeTx?.stage === "error"
      ? "Transaction failed."
      : "No transaction selected.";

  return (
    <Dialog.Root open={open} onOpenChange={onOpenChange}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-[70] bg-black/40" />
        <Dialog.Content className="fixed left-1/2 top-1/2 z-[71] w-[92vw] max-w-[560px] -translate-x-1/2 -translate-y-1/2 outline-none">
          <Card className="p-5">
            <div className="flex items-start justify-between gap-4">
              <div className="flex items-start gap-3">
                <div className="mt-0.5">{icon}</div>
                <div>
                  <Dialog.Title className="text-base font-semibold">{activeTx?.title ?? "Transaction"}</Dialog.Title>
                  <Dialog.Description className="mt-1 text-sm text-text2">{description}</Dialog.Description>
                </div>
              </div>

              <Dialog.Close asChild>
                <button
                  aria-label="Close transaction dialog"
                  className="rounded-lg px-2 py-1 text-text2 hover:bg-muted focus-visible:ring-2 focus-visible:ring-primary/30"
                >
                  X
                </button>
              </Dialog.Close>
            </div>

            {activeTx ? (
              <div className="mt-4 grid gap-3">
                <div className="grid gap-2 rounded-xl border border-border bg-muted p-3 text-xs text-text2 md:grid-cols-2">
                  <div>
                    Status: <span className="font-medium text-text">{activeTx.stage.toUpperCase()}</span>
                  </div>
                  <div>
                    Attempt: <span className="font-medium text-text">#{activeTx.attempts}</span>
                  </div>
                  <div>
                    Created: <span className="font-medium text-text">{new Date(activeTx.createdAt).toLocaleString()}</span>
                  </div>
                  <div>
                    Updated: <span className="font-medium text-text">{new Date(activeTx.updatedAt).toLocaleString()}</span>
                  </div>
                  {activeTx.functionName ? (
                    <div className="md:col-span-2">
                      Function: <span className="font-mono text-text">{activeTx.functionName}</span>
                    </div>
                  ) : null}
                </div>

                {activeTx.hash ? (
                  <div className="rounded-xl border border-border bg-muted p-3">
                    <div className="text-xs text-text2">Tx Hash</div>
                    <div className="mt-1 break-all font-mono text-sm">{activeTx.hash}</div>
                    <div className="mt-3 flex flex-wrap items-center gap-2">
                      <Button size="sm" variant="secondary" onClick={() => navigator.clipboard.writeText(activeTx.hash!)}>
                        <Copy size={14} /> Copy
                      </Button>
                      {activeTx.chainId ? (
                        <a
                          className={cn(
                            "inline-flex h-9 items-center justify-center gap-2 rounded-xl border border-border bg-card px-3 text-sm hover:bg-muted"
                          )}
                          href={explorerTxUrl(activeTx.chainId, activeTx.hash)}
                          target="_blank"
                          rel="noreferrer"
                        >
                          <ExternalLink size={14} /> View on explorer
                        </a>
                      ) : null}
                    </div>
                  </div>
                ) : null}

                {activeTx.error ? (
                  <div className="rounded-xl border border-bad/30 bg-bad/10 p-3 text-sm text-bad">{activeTx.error}</div>
                ) : null}
              </div>
            ) : null}

            <div className="mt-5 flex flex-wrap justify-end gap-2">
              {activeTx?.stage === "error" && canRetry(activeTx.id) ? (
                <Button variant="accent" onClick={() => retryTx(activeTx.id)}>
                  <RotateCcw size={14} /> Retry
                </Button>
              ) : null}
              <Dialog.Close asChild>
                <Button variant="secondary">Close</Button>
              </Dialog.Close>
            </div>
          </Card>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
