"use client";

import * as React from "react";
import { useQuery } from "@tanstack/react-query";
import { formatUnits, isAddress, keccak256, parseUnits, toHex, zeroAddress } from "viem";
import { useAccount, useChainId, usePublicClient } from "wagmi";
import { useTx } from "@/hooks/useTx";
import { PageHeader } from "@/components/ui/PageHeader";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { Button } from "@/components/ui/Button";
import { Badge } from "@/components/ui/Badge";
import { EmptyState } from "@/components/ui/EmptyState";
import {
  distributionAbi,
  erc20AllowanceAbi,
  erc20DecimalsAbi,
  roleManagerAbi,
  yieldAccumulatorAbi
} from "@/lib/abi";
import { resolveDiscoveryFromBlock } from "@/lib/campaignDiscovery";
import { getLogsChunked } from "@/lib/discovery";
import { getPublicEnv } from "@/lib/env";
import { explorerAddressUrl, explorerTxUrl } from "@/lib/explorer";
import { shortAddr, shortHex32 } from "@/lib/format";
import { roles } from "@/lib/roles";

const B32_ZERO = ("0x" + "00".repeat(32)) as `0x${string}`;
const B32_RE = /^0x[0-9a-fA-F]{64}$/u;
const UINT64_MAX = 2n ** 64n - 1n;

const DEFAULT_ADMIN_ROLE = ("0x" + "00".repeat(32)) as `0x${string}`;
const REWARD_NOTIFIER_ROLE = keccak256(toHex("REWARD_NOTIFIER_ROLE")) as `0x${string}`;
const GOVERNANCE_ROLE =
  roles.find((r) => r.key === "GOVERNANCE_ROLE")?.role ??
  (keccak256(toHex("GOVERNANCE_ROLE")) as `0x${string}`);

type RewardHistoryRow = {
  id: string;
  txHash?: `0x${string}`;
  blockNumber: bigint;
  logIndex: number;
  amount: bigint;
  liquidationId: bigint;
  reportHash: `0x${string}`;
  timestamp?: number;
};

function canAddr(v: string): v is `0x${string}` {
  return isAddress(v);
}

function isBytes32(v: string): v is `0x${string}` {
  return B32_RE.test(v.trim());
}

function parseUint64(v: string): bigint | undefined {
  const raw = v.trim();
  if (!/^\d+$/u.test(raw)) return undefined;
  try {
    const n = BigInt(raw);
    if (n < 0n || n > UINT64_MAX) return undefined;
    return n;
  } catch {
    return undefined;
  }
}

function parseAmount(v: string, decimals: number): bigint | undefined {
  const raw = v.trim();
  if (!raw) return undefined;
  try {
    return parseUnits(raw, decimals);
  } catch {
    return undefined;
  }
}

function fmtAmount(v: bigint, decimals: number, precision = 4): string {
  const full = formatUnits(v, decimals);
  const [i, d] = full.split(".");
  if (!d) return i;
  return `${i}.${d.slice(0, precision)}`;
}

function fmtTs(ts?: number): string {
  if (!Number.isFinite(ts) || !ts || ts <= 0) return "-";
  return new Date(ts * 1000).toLocaleString();
}

export default function AdminLiquidationsPage() {
  const env = getPublicEnv();
  const chainId = useChainId();
  const client = usePublicClient();
  const { address, isConnected } = useAccount();
  const { sendTx } = useTx();

  const [distributionAddr, setDistributionAddr] = React.useState<string>("");
  const [amount, setAmount] = React.useState<string>("100");
  const [liquidationId, setLiquidationId] = React.useState<string>("");
  const [reportHash, setReportHash] = React.useState<string>(B32_ZERO);
  const [reportText, setReportText] = React.useState<string>("");

  const autoFillRef = React.useRef<string>("");

  React.useEffect(() => {
    if (typeof window === "undefined") return;
    const search = new URLSearchParams(window.location.search);
    const qAddr = search.get("addr") ?? "";
    const qAmount = search.get("amount") ?? "";
    const qLiquidationId = search.get("liquidationId") ?? "";
    const qReportHash = search.get("reportHash") ?? "";

    if (qAddr && canAddr(qAddr)) setDistributionAddr(qAddr);
    if (qAmount) setAmount(qAmount);
    if (qLiquidationId && parseUint64(qLiquidationId) !== undefined) setLiquidationId(qLiquidationId);
    if (qReportHash && isBytes32(qReportHash)) setReportHash(qReportHash);
  }, []);

  const distribution = canAddr(distributionAddr) ? distributionAddr : undefined;

  const distributionMeta = useQuery({
    queryKey: ["adminLiquidationsMeta", distribution],
    enabled: !!client && !!distribution,
    queryFn: async () => {
      if (!client || !distribution) {
        return {
          campaignId: undefined,
          roleManager: undefined,
          rewardToken: undefined,
          lastLiquidationId: 0n,
          nextLiquidationId: 1n
        };
      }
      const [campaignIdRaw, roleManagerRaw, rewardTokenRaw, lastRaw, nextRaw] = await Promise.all([
        client.readContract({ address: distribution, abi: yieldAccumulatorAbi, functionName: "campaignId" }).catch(() => undefined),
        client.readContract({ address: distribution, abi: yieldAccumulatorAbi, functionName: "roleManager" }).catch(() => undefined),
        client.readContract({ address: distribution, abi: yieldAccumulatorAbi, functionName: "rewardToken" }).catch(() => undefined),
        client.readContract({ address: distribution, abi: yieldAccumulatorAbi, functionName: "lastLiquidationId" }).catch(() => 0n),
        client.readContract({ address: distribution, abi: yieldAccumulatorAbi, functionName: "nextLiquidationId" }).catch(() => undefined)
      ]);
      const lastLiquidationId = BigInt(lastRaw as any);
      const nextLiquidationId = typeof nextRaw === "bigint" ? nextRaw : lastLiquidationId + 1n;
      return {
        campaignId: campaignIdRaw as `0x${string}` | undefined,
        roleManager: roleManagerRaw as `0x${string}` | undefined,
        rewardToken: rewardTokenRaw as `0x${string}` | undefined,
        lastLiquidationId,
        nextLiquidationId
      };
    }
  });

  React.useEffect(() => {
    if (!distribution) return;
    if (!distributionMeta.data?.nextLiquidationId) return;
    if (autoFillRef.current === distribution) return;
    setLiquidationId(distributionMeta.data.nextLiquidationId.toString());
    autoFillRef.current = distribution;
  }, [distribution, distributionMeta.data?.nextLiquidationId]);

  const rewardTokenMeta = useQuery({
    queryKey: ["adminLiquidationsRewardTokenMeta", distributionMeta.data?.rewardToken],
    enabled: !!client && !!distributionMeta.data?.rewardToken && distributionMeta.data.rewardToken !== zeroAddress,
    queryFn: async () => {
      if (!client || !distributionMeta.data?.rewardToken) return { symbol: "RWD", decimals: 18 };
      const rewardToken = distributionMeta.data.rewardToken;
      const [symbol, decimals] = await Promise.all([
        client.readContract({ address: rewardToken, abi: erc20AllowanceAbi, functionName: "symbol" }).catch(() => "RWD"),
        client.readContract({ address: rewardToken, abi: erc20DecimalsAbi, functionName: "decimals" }).catch(() => 18)
      ]);
      return {
        symbol: String(symbol || "RWD"),
        decimals: Number(decimals ?? 18)
      };
    }
  });

  const notifierRoleCheck = useQuery({
    queryKey: ["adminLiquidationsNotifierRole", distributionMeta.data?.roleManager, address],
    enabled: !!client && !!distributionMeta.data?.roleManager && !!address,
    queryFn: async () => {
      if (!client || !distributionMeta.data?.roleManager || !address) {
        return { canNotify: false, byRole: [] as { role: `0x${string}`; label: string; ok: boolean }[] };
      }
      const roleManager = distributionMeta.data.roleManager;
      const roleDefs = [
        { role: REWARD_NOTIFIER_ROLE, label: "Reward notifier" },
        { role: GOVERNANCE_ROLE, label: "Governance" },
        { role: DEFAULT_ADMIN_ROLE, label: "Default admin" }
      ];
      const byRole = await Promise.all(
        roleDefs.map(async (item) => {
          const ok = Boolean(
            await client.readContract({
              address: roleManager,
              abi: roleManagerAbi,
              functionName: "hasRole",
              args: [item.role, address]
            }).catch(() => false)
          );
          return { ...item, ok };
        })
      );
      return {
        canNotify: byRole.some((x) => x.ok),
        byRole
      };
    }
  });

  const history = useQuery({
    queryKey: ["adminLiquidationsHistory", distribution, env.NEXT_PUBLIC_DISCOVERY_FROM_BLOCK?.toString() ?? "auto"],
    enabled: !!client && !!distribution,
    refetchInterval: 30_000,
    queryFn: async (): Promise<RewardHistoryRow[]> => {
      if (!client || !distribution) return [];
      const head = await client.getBlockNumber();
      const from = resolveDiscoveryFromBlock(head, env.NEXT_PUBLIC_DISCOVERY_FROM_BLOCK);
      const logs = await getLogsChunked({
        client,
        fromBlock: from,
        toBlock: head,
        maxChunk: 5_000n,
        params: {
          address: distribution,
          abi: distributionAbi,
          eventName: "RewardNotified"
        }
      });

      const rows = [...(logs as any[])]
        .map((log) => ({
          id: `${String(log?.transactionHash ?? "nohash")}:${String(log?.logIndex ?? 0)}`,
          txHash: log?.transactionHash as `0x${string}` | undefined,
          blockNumber: BigInt(log?.blockNumber ?? 0),
          logIndex: Number(log?.logIndex ?? 0),
          amount: BigInt(log?.args?.amount ?? 0),
          liquidationId: BigInt(log?.args?.liquidationId ?? 0),
          reportHash: (log?.args?.reportHash ?? B32_ZERO) as `0x${string}`
        }))
        .sort((a, b) => {
          if (a.blockNumber === b.blockNumber) return b.logIndex - a.logIndex;
          return a.blockNumber > b.blockNumber ? -1 : 1;
        })
        .slice(0, 30);

      const byBlock = new Map<string, number>();
      const blockKeys = [...new Set(rows.map((x) => x.blockNumber.toString()))];
      await Promise.all(
        blockKeys.map(async (k) => {
          try {
            const block = await client.getBlock({ blockNumber: BigInt(k) });
            byBlock.set(k, Number(block.timestamp));
          } catch {
            // ignore timestamp errors
          }
        })
      );

      return rows.map((row) => ({
        ...row,
        timestamp: byBlock.get(row.blockNumber.toString())
      }));
    }
  });

  const builtHash = React.useMemo(() => {
    const t = reportText.trim();
    if (!t) return "";
    return keccak256(toHex(t));
  }, [reportText]);

  const rewardSymbol = rewardTokenMeta.data?.symbol ?? "RWD";
  const rewardDecimals = rewardTokenMeta.data?.decimals ?? 18;
  const parsedAmount = parseAmount(amount, rewardDecimals);
  const parsedLiquidationId = parseUint64(liquidationId);
  const parsedReportHash = isBytes32(reportHash) ? (reportHash.trim() as `0x${string}`) : undefined;
  const reportHashNonZero = Boolean(parsedReportHash && parsedReportHash.toLowerCase() !== B32_ZERO);
  const nextLiquidationId = distributionMeta.data?.nextLiquidationId;
  const sequentialOk =
    typeof nextLiquidationId === "bigint" && typeof parsedLiquidationId === "bigint"
      ? parsedLiquidationId === nextLiquidationId
      : false;

  const inputErrors: string[] = [];
  if (!distribution) inputErrors.push("Distribution address required");
  if (!parsedAmount || parsedAmount <= 0n) inputErrors.push("Amount must be > 0");
  if (!parsedLiquidationId) inputErrors.push("LiquidationId must be uint64");
  if (typeof nextLiquidationId !== "bigint") inputErrors.push("nextLiquidationId unavailable");
  if (typeof nextLiquidationId === "bigint" && parsedLiquidationId && parsedLiquidationId !== nextLiquidationId) {
    inputErrors.push(`LiquidationId must equal nextLiquidationId (${nextLiquidationId.toString()})`);
  }
  if (!parsedReportHash) inputErrors.push("Report hash must be bytes32");
  if (parsedReportHash && parsedReportHash.toLowerCase() === B32_ZERO) inputErrors.push("Report hash cannot be zero");
  if (!isConnected) inputErrors.push("Connect wallet");
  if (isConnected && distributionMeta.data && !distributionMeta.data.roleManager) inputErrors.push("RoleManager unavailable");
  if (isConnected && distributionMeta.data?.roleManager && notifierRoleCheck.isLoading) inputErrors.push("Checking notifier role");
  if (isConnected && notifierRoleCheck.data && !notifierRoleCheck.data.canNotify) inputErrors.push("Wallet lacks notifier role");

  const simulation = useQuery({
    queryKey: [
      "adminLiquidationsSimulation",
      distribution,
      address,
      parsedAmount?.toString() ?? "none",
      parsedLiquidationId?.toString() ?? "none",
      parsedReportHash ?? "none"
    ],
    enabled:
      !!client &&
      !!distribution &&
      !!address &&
      !!parsedAmount &&
      !!parsedLiquidationId &&
      reportHashNonZero &&
      sequentialOk,
    queryFn: async () => {
      if (!client || !distribution || !address || !parsedAmount || !parsedLiquidationId || !parsedReportHash) {
        return { ok: false, error: "missing params" };
      }
      try {
        await client.simulateContract({
          account: address,
          address: distribution,
          abi: yieldAccumulatorAbi,
          functionName: "notifyReward",
          args: [parsedAmount, parsedLiquidationId, parsedReportHash]
        });
        return { ok: true, error: "" };
      } catch (error: any) {
        return { ok: false, error: error?.shortMessage || error?.message || "simulation failed" };
      }
    }
  });

  const onUseNext = () => {
    if (typeof nextLiquidationId !== "bigint") return;
    setLiquidationId(nextLiquidationId.toString());
  };

  const onNotifyReward = async () => {
    if (!distribution || !parsedAmount || !parsedLiquidationId || !parsedReportHash) return;
    await sendTx({
      title: `Notify reward #${parsedLiquidationId.toString()}`,
      address: distribution,
      abi: distributionAbi,
      functionName: "notifyReward",
      args: [parsedAmount, parsedLiquidationId, parsedReportHash]
    } as any);

    const refreshed = await distributionMeta.refetch();
    if (typeof refreshed.data?.nextLiquidationId === "bigint") {
      setLiquidationId(refreshed.data.nextLiquidationId.toString());
    }
    await Promise.all([history.refetch(), simulation.refetch()]);
  };

  return (
    <div>
      <PageHeader
        title="Admin · Liquidations"
        subtitle="Sequential reward notifications: nextLiquidationId + non-zero reportHash."
      />

      <div className="grid gap-4">
        <Card>
          <CardHeader>
            <CardTitle>Notify Reward</CardTitle>
            <CardDescription>
              Uses on-chain `nextLiquidationId()` guard. If you skip IDs, the transaction is blocked.
            </CardDescription>
          </CardHeader>
          <CardContent className="space-y-3">
            <div className="grid gap-2 md:grid-cols-2">
              <Input
                value={distributionAddr}
                onChange={(e) => setDistributionAddr(e.target.value)}
                placeholder="Distribution (YieldAccumulator) 0x..."
                aria-label="Distribution address"
              />
              <Input
                value={amount}
                onChange={(e) => setAmount(e.target.value)}
                placeholder={`Reward amount (${rewardSymbol})`}
                aria-label="Reward amount"
              />
              <Input
                value={liquidationId}
                onChange={(e) => setLiquidationId(e.target.value)}
                placeholder="Liquidation id (uint64)"
                aria-label="Liquidation id"
              />
              <Input
                value={reportHash}
                onChange={(e) => setReportHash(e.target.value)}
                placeholder="Report hash (bytes32, non-zero)"
                aria-label="Report hash"
              />
            </div>

            <div className="flex flex-wrap items-center gap-2">
              <Button variant="secondary" onClick={onUseNext} disabled={typeof nextLiquidationId !== "bigint"}>
                Use nextLiquidationId
              </Button>
              <Button
                variant="secondary"
                onClick={() => {
                  void distributionMeta.refetch();
                  void history.refetch();
                }}
                disabled={!distribution}
              >
                Refresh
              </Button>
              <Button
                onClick={onNotifyReward}
                disabled={!isConnected || inputErrors.length > 0 || simulation.data?.ok === false}
              >
                notifyReward
              </Button>
            </div>

            <div className="flex flex-wrap items-center gap-2">
              <Badge tone={distribution ? "good" : "warn"}>{distribution ? "Distribution OK" : "Distribution missing"}</Badge>
              <Badge tone={sequentialOk ? "good" : "warn"}>
                {sequentialOk ? "Sequential id OK" : "Id must equal next"}
              </Badge>
              <Badge tone={reportHashNonZero ? "good" : "warn"}>
                {reportHashNonZero ? "Report hash non-zero" : "Report hash invalid/zero"}
              </Badge>
              <Badge tone={notifierRoleCheck.data?.canNotify ? "good" : "warn"}>
                {notifierRoleCheck.data?.canNotify ? "Notifier role OK" : "Notifier role missing"}
              </Badge>
              <Badge tone={simulation.data?.ok ? "good" : simulation.data ? "bad" : "default"}>
                {simulation.data?.ok ? "Simulation OK" : simulation.data ? "Simulation failed" : "Simulation pending"}
              </Badge>
            </div>

            <div className="grid gap-2 text-xs text-text2 md:grid-cols-2">
              <div>
                CampaignId:{" "}
                {distributionMeta.data?.campaignId
                  ? shortHex32(distributionMeta.data.campaignId)
                  : "-"}
              </div>
              <div>
                lastLiquidationId: {distributionMeta.data?.lastLiquidationId?.toString() ?? "-"}
              </div>
              <div>
                nextLiquidationId: {distributionMeta.data?.nextLiquidationId?.toString() ?? "-"}
              </div>
              <div>
                Reward token:{" "}
                {distributionMeta.data?.rewardToken && distributionMeta.data.rewardToken !== zeroAddress ? (
                  <a
                    className="text-primary underline"
                    href={explorerAddressUrl(chainId, distributionMeta.data.rewardToken)}
                    target="_blank"
                    rel="noreferrer"
                  >
                    {shortAddr(distributionMeta.data.rewardToken, 6)}
                  </a>
                ) : (
                  "-"
                )}
              </div>
            </div>

            {notifierRoleCheck.data?.byRole?.length ? (
              <div className="flex flex-wrap gap-2">
                {notifierRoleCheck.data.byRole.map((r) => (
                  <Badge key={r.role} tone={r.ok ? "good" : "default"}>
                    {r.label}
                  </Badge>
                ))}
              </div>
            ) : null}

            {inputErrors.length > 0 ? (
              <div className="flex flex-wrap gap-2">
                {inputErrors.map((e) => (
                  <Badge key={e} tone="warn">{e}</Badge>
                ))}
              </div>
            ) : null}

            {simulation.data && !simulation.data.ok ? (
              <div className="rounded-xl border border-bad/30 bg-bad/10 p-3 text-sm text-bad">
                {simulation.data.error}
              </div>
            ) : null}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Report Hash Builder</CardTitle>
            <CardDescription>Build and copy `keccak256(text)` for off-chain liquidation report references.</CardDescription>
          </CardHeader>
          <CardContent className="space-y-3">
            <div className="grid gap-2 md:grid-cols-[1.2fr_1fr]">
              <Input
                value={reportText}
                onChange={(e) => setReportText(e.target.value)}
                placeholder="Type report label/text"
                aria-label="Report text"
              />
              <Input
                value={builtHash}
                readOnly
                placeholder="keccak256(text)"
                aria-label="Built report hash"
              />
            </div>
            <div className="flex flex-wrap items-center gap-2">
              <Button variant="secondary" onClick={() => setReportHash(builtHash)} disabled={!builtHash}>
                Use built hash
              </Button>
              <Button
                variant="secondary"
                onClick={() => navigator.clipboard.writeText(reportHash)}
                disabled={!isBytes32(reportHash)}
              >
                Copy reportHash
              </Button>
            </div>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Liquidation History</CardTitle>
            <CardDescription>Recent `RewardNotified` events from this distribution module.</CardDescription>
          </CardHeader>
          <CardContent>
            {history.isLoading ? (
              <div className="text-sm text-text2">Loading history...</div>
            ) : (history.data?.length ?? 0) === 0 ? (
              <EmptyState title="No liquidations yet" description="No RewardNotified events found for this module." />
            ) : (
              <>
                <div className="hidden md:block">
                  <div className="overflow-x-auto rounded-xl border border-border/80">
                    <table className="w-full min-w-[860px] text-left text-sm">
                      <thead className="bg-muted text-text2">
                        <tr>
                          <th className="px-3 py-2 font-medium">Liquidation</th>
                          <th className="px-3 py-2 font-medium">Amount</th>
                          <th className="px-3 py-2 font-medium">Report hash</th>
                          <th className="px-3 py-2 font-medium">When</th>
                          <th className="px-3 py-2 font-medium">Tx</th>
                        </tr>
                      </thead>
                      <tbody>
                        {(history.data ?? []).map((row) => (
                          <tr key={row.id} className="border-t border-border/70">
                            <td className="px-3 py-2 font-mono">#{row.liquidationId.toString()}</td>
                            <td className="px-3 py-2 font-mono">{fmtAmount(row.amount, rewardDecimals)} {rewardSymbol}</td>
                            <td className="px-3 py-2 font-mono">{shortHex32(row.reportHash)}</td>
                            <td className="px-3 py-2 text-xs">{fmtTs(row.timestamp)}</td>
                            <td className="px-3 py-2">
                              {row.txHash ? (
                                <div className="flex items-center gap-2">
                                  <button
                                    type="button"
                                    className="rounded-md border border-border px-2 py-1 text-xs hover:bg-card"
                                    onClick={() => navigator.clipboard.writeText(row.txHash!)}
                                  >
                                    Copy
                                  </button>
                                  <a
                                    className="rounded-md border border-border px-2 py-1 text-xs hover:bg-card"
                                    href={explorerTxUrl(chainId, row.txHash)}
                                    target="_blank"
                                    rel="noreferrer"
                                  >
                                    Explorer
                                  </a>
                                </div>
                              ) : "-"}
                            </td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                </div>

                <div className="grid gap-3 md:hidden">
                  {(history.data ?? []).map((row) => (
                    <div key={row.id} className="rounded-xl border border-border/80 bg-card p-3">
                      <div className="flex items-start justify-between gap-2">
                        <div className="font-medium">Liquidation #{row.liquidationId.toString()}</div>
                        <Badge tone="default">{fmtTs(row.timestamp)}</Badge>
                      </div>
                      <div className="mt-2 text-xs text-text2">
                        Amount: {fmtAmount(row.amount, rewardDecimals)} {rewardSymbol}
                      </div>
                      <div className="mt-1 text-xs text-text2">Report: {shortHex32(row.reportHash)}</div>
                      <div className="mt-1 text-xs text-text2">Block: {row.blockNumber.toString()}</div>
                      {row.txHash ? (
                        <div className="mt-3 flex flex-wrap items-center gap-2">
                          <button
                            type="button"
                            className="rounded-md border border-border px-2 py-1 text-xs hover:bg-muted"
                            onClick={() => navigator.clipboard.writeText(row.txHash!)}
                          >
                            Copy tx
                          </button>
                          <a
                            className="rounded-md border border-border px-2 py-1 text-xs hover:bg-muted"
                            href={explorerTxUrl(chainId, row.txHash)}
                            target="_blank"
                            rel="noreferrer"
                          >
                            Explorer
                          </a>
                        </div>
                      ) : null}
                    </div>
                  ))}
                </div>
              </>
            )}
          </CardContent>
        </Card>
      </div>
    </div>
  );
}
