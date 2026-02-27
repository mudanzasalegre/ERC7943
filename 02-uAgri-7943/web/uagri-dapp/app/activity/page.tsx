"use client";

import { Copy, ExternalLink, RotateCcw } from "lucide-react";
import { PageHeader } from "@/components/ui/PageHeader";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/Card";
import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { EmptyState } from "@/components/ui/EmptyState";
import { explorerTxUrl } from "@/lib/explorer";
import { useToaster, type TxEntry } from "@/components/tx/ToasterProvider";

function statusLabel(tx: TxEntry): string {
  if (tx.stage === "pending") return tx.pendingPhase === "wallet" ? "PENDING (WALLET)" : "PENDING (CHAIN)";
  if (tx.stage === "success") return "SUCCESS";
  return "ERROR";
}

function statusTone(tx: TxEntry): "good" | "warn" | "bad" {
  if (tx.stage === "success") return "good";
  if (tx.stage === "error") return "bad";
  return "warn";
}

export default function ActivityPage() {
  const { txs, openTxModal, retryTx, canRetry } = useToaster();

  return (
    <div>
      <PageHeader
        title="Activity"
        subtitle="Local transaction feed: pending, success and error states with hash, retry and modal details."
      />

      <Card>
        <CardHeader>
          <CardTitle>Recent local transactions</CardTitle>
          <CardDescription>Desktop uses table view. Mobile uses transaction cards.</CardDescription>
        </CardHeader>
        <CardContent>
          {txs.length === 0 ? (
            <EmptyState
              title="No local transactions yet"
              description="Execute any write action (deposit, redeem, admin operations) to populate this feed."
            />
          ) : (
            <>
              <div className="hidden md:block">
                <div className="overflow-x-auto rounded-xl border border-border/80">
                  <table className="w-full min-w-[840px] text-left text-sm">
                    <thead className="bg-muted text-text2">
                      <tr>
                        <th className="px-3 py-2 font-medium">Status</th>
                        <th className="px-3 py-2 font-medium">Title</th>
                        <th className="px-3 py-2 font-medium">Function</th>
                        <th className="px-3 py-2 font-medium">Hash</th>
                        <th className="px-3 py-2 font-medium">Attempt</th>
                        <th className="px-3 py-2 font-medium">Updated</th>
                        <th className="px-3 py-2 font-medium">Actions</th>
                      </tr>
                    </thead>
                    <tbody>
                      {txs.map((tx) => (
                        <tr key={tx.id} className="border-t border-border/70">
                          <td className="px-3 py-2">
                            <Badge tone={statusTone(tx)}>{statusLabel(tx)}</Badge>
                          </td>
                          <td className="px-3 py-2 font-medium">{tx.title}</td>
                          <td className="px-3 py-2 font-mono text-xs text-text2">{tx.functionName || "-"}</td>
                          <td className="px-3 py-2 font-mono text-xs text-text2">
                            {tx.hash ? `${tx.hash.slice(0, 10)}...${tx.hash.slice(-6)}` : "-"}
                          </td>
                          <td className="px-3 py-2 text-text2">#{tx.attempts}</td>
                          <td className="px-3 py-2 text-xs text-text2">{new Date(tx.updatedAt).toLocaleString()}</td>
                          <td className="px-3 py-2">
                            <div className="flex flex-wrap items-center gap-2">
                              <Button size="sm" variant="secondary" onClick={() => openTxModal(tx.id)}>
                                Details
                              </Button>
                              {tx.hash ? (
                                <Button size="sm" variant="ghost" onClick={() => navigator.clipboard.writeText(tx.hash!)}>
                                  <Copy size={14} />
                                </Button>
                              ) : null}
                              {tx.hash && tx.chainId ? (
                                <a
                                  className="inline-flex h-9 items-center justify-center rounded-xl border border-border px-2 text-text2 hover:bg-muted"
                                  href={explorerTxUrl(tx.chainId, tx.hash)}
                                  target="_blank"
                                  rel="noreferrer"
                                  aria-label="Open in explorer"
                                >
                                  <ExternalLink size={14} />
                                </a>
                              ) : null}
                              {tx.stage === "error" && canRetry(tx.id) ? (
                                <Button size="sm" variant="accent" onClick={() => retryTx(tx.id)}>
                                  <RotateCcw size={14} /> Retry
                                </Button>
                              ) : null}
                            </div>
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              </div>

              <div className="grid gap-3 md:hidden">
                {txs.map((tx) => (
                  <div key={tx.id} className="rounded-xl border border-border/80 bg-card p-3">
                    <div className="flex items-start justify-between gap-2">
                      <div>
                        <div className="font-medium">{tx.title}</div>
                        <div className="mt-1 text-xs text-text2">{tx.functionName || "Unknown function"}</div>
                      </div>
                      <Badge tone={statusTone(tx)}>{statusLabel(tx)}</Badge>
                    </div>

                    <div className="mt-2 text-xs text-text2">Attempt #{tx.attempts}</div>
                    <div className="mt-1 text-xs text-text2">{new Date(tx.updatedAt).toLocaleString()}</div>

                    {tx.hash ? <div className="mt-2 break-all font-mono text-xs text-text2">{tx.hash}</div> : null}
                    {tx.error ? <div className="mt-2 text-sm text-bad">{tx.error}</div> : null}

                    <div className="mt-3 flex flex-wrap items-center gap-2">
                      <Button size="sm" variant="secondary" onClick={() => openTxModal(tx.id)}>
                        Details
                      </Button>
                      {tx.hash ? (
                        <Button size="sm" variant="ghost" onClick={() => navigator.clipboard.writeText(tx.hash!)}>
                          <Copy size={14} />
                        </Button>
                      ) : null}
                      {tx.hash && tx.chainId ? (
                        <a
                          className="inline-flex h-9 items-center justify-center rounded-xl border border-border px-2 text-text2 hover:bg-muted"
                          href={explorerTxUrl(tx.chainId, tx.hash)}
                          target="_blank"
                          rel="noreferrer"
                        >
                          <ExternalLink size={14} />
                        </a>
                      ) : null}
                      {tx.stage === "error" && canRetry(tx.id) ? (
                        <Button size="sm" variant="accent" onClick={() => retryTx(tx.id)}>
                          <RotateCcw size={14} /> Retry
                        </Button>
                      ) : null}
                    </div>
                  </div>
                ))}
              </div>
            </>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
