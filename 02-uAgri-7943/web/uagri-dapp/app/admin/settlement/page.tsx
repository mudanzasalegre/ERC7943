"use client";

import * as React from "react";
import { useQuery } from "@tanstack/react-query";
import { decodeErrorResult, formatUnits, isAddress, zeroAddress } from "viem";
import { useAccount, usePublicClient } from "wagmi";
import { PageHeader } from "@/components/ui/PageHeader";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { Button } from "@/components/ui/Button";
import { Badge } from "@/components/ui/Badge";
import { EmptyState } from "@/components/ui/EmptyState";
import { useTx } from "@/hooks/useTx";
import {
  campaignRegistryAbi,
  erc20Abi,
  erc20AllowanceAbi,
  erc20DecimalsAbi,
  fundingManagerAbi,
  roleManagerAbi,
  settlementQueueAbi
} from "@/lib/abi";
import { getPublicEnv } from "@/lib/env";
import { getLogsChunked } from "@/lib/discovery";
import { resolveDiscoveryFromBlock } from "@/lib/campaignDiscovery";
import { roles } from "@/lib/roles";
import { shortAddr } from "@/lib/format";

type PendingRequest = {
  id: bigint;
  account: `0x${string}`;
  kind: number;
  amount: bigint;
  minOut: bigint;
  maxIn: bigint;
  deadline: number;
  createdBlock: bigint;
  failCount: number;
  lastFailData?: `0x${string}`;
  lastFailBlock?: bigint;
};

type QueueMeta = {
  fundingManager?: `0x${string}`;
  roleManager?: `0x${string}`;
  campaignId?: `0x${string}`;
  requestCount: bigint;
};

const B32_RE = /^0x[0-9a-fA-F]{64}$/;
const MAX_BATCH_RECOMMENDED = 80;
const EMPTY_ROWS: PendingRequest[] = [];
const PROCESS_GAS_BASE = 220_000n;
const PROCESS_GAS_PER_DEPOSIT = 560_000n;
const PROCESS_GAS_PER_REDEEM = 420_000n;
const PROCESS_GAS_OOG_RETRY_BONUS = 180_000n;
const PROCESS_GAS_MARGIN_BPS = 11_500n; // +15% safety margin
const PROCESS_GAS_MIN_SINGLE = 700_000n;
const PROCESS_GAS_MAX = 12_000_000n;

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
    if (n < 0n || n > (2n ** 64n - 1n)) return undefined;
    return n;
  } catch {
    return undefined;
  }
}

function uniq<T>(arr: T[]): T[] {
  return [...new Set(arr)];
}

function dedupeLogs<T extends any>(logs: T[]): T[] {
  const m = new Map<string, T>();
  for (const log of logs) {
    const key = `${String((log as any)?.transactionHash ?? "0x")}:${String((log as any)?.logIndex ?? 0)}`;
    if (!m.has(key)) m.set(key, log);
  }
  return [...m.values()];
}

function fmtTs(ts: number): string {
  if (!Number.isFinite(ts) || ts <= 0) return "-";
  return new Date(ts * 1000).toLocaleString();
}

function fmtAmt(v: bigint, decimals: number, precision = 4): string {
  const s = formatUnits(v, decimals);
  const [i, d] = s.split(".");
  if (!d) return i;
  return `${i}.${d.slice(0, precision)}`;
}

function fmtIdList(ids: string[], max = 4): string {
  if (ids.length === 0) return "-";
  const slice = ids.slice(0, max).map((id) => `#${id}`);
  return ids.length > max ? `${slice.join(", ")} +${ids.length - max}` : slice.join(", ");
}

function fmtGas(v: bigint): string {
  if (v <= 0n) return "-";
  return `${(Number(v) / 1_000_000).toFixed(2)}M`;
}

function estimateProcessGas(rows: PendingRequest[]): bigint {
  if (rows.length === 0) return 0n;

  let total = PROCESS_GAS_BASE;
  for (const r of rows) {
    total += r.kind === 0 ? PROCESS_GAS_PER_DEPOSIT : PROCESS_GAS_PER_REDEEM;
    if (r.failCount > 0 && (!r.lastFailData || r.lastFailData === "0x")) {
      total += PROCESS_GAS_OOG_RETRY_BONUS;
    }
  }

  let withMargin = (total * PROCESS_GAS_MARGIN_BPS + 9_999n) / 10_000n;
  if (rows.length === 1 && withMargin < PROCESS_GAS_MIN_SINGLE) {
    withMargin = PROCESS_GAS_MIN_SINGLE;
  }
  if (withMargin > PROCESS_GAS_MAX) {
    return PROCESS_GAS_MAX;
  }
  return withMargin;
}

function decodeFailData(data?: `0x${string}`): string {
  if (!data || data === "0x") return "No revert data (possible inner out-of-gas)";
  try {
    const dec = decodeErrorResult({ abi: fundingManagerAbi, data });
    return dec.errorName;
  } catch {}
  try {
    const dec = decodeErrorResult({ abi: settlementQueueAbi, data });
    return dec.errorName;
  } catch {}
  return `${data.slice(0, 10)}...`;
}

export default function AdminSettlementPage() {
  const env = getPublicEnv();
  const client = usePublicClient();
  const { address, isConnected } = useAccount();
  const { sendTx } = useTx();

  const [queueAddr, setQueueAddr] = React.useState<string>("");
  const [epoch, setEpoch] = React.useState<string>(() => String(Math.floor(Date.now() / 1000)));
  const [reportHash, setReportHash] = React.useState<string>("0x" + "00".repeat(32));
  const [selectedIds, setSelectedIds] = React.useState<Set<string>>(new Set());
  const [nowTs, setNowTs] = React.useState<number>(() => Math.floor(Date.now() / 1000));
  const [txPending, setTxPending] = React.useState(false);

  React.useEffect(() => {
    if (typeof window === "undefined") return;
    const search = new URLSearchParams(window.location.search);
    const qAddr = search.get("addr") ?? "";
    const qEpoch = search.get("epoch") ?? "";
    const qReportHash = search.get("reportHash") ?? "";

    if (qAddr && canAddr(qAddr)) setQueueAddr(qAddr);
    if (qEpoch && parseUint64(qEpoch) !== undefined) setEpoch(qEpoch);
    if (qReportHash && isBytes32(qReportHash)) setReportHash(qReportHash);
  }, []);

  React.useEffect(() => {
    const id = setInterval(() => setNowTs(Math.floor(Date.now() / 1000)), 10_000);
    return () => clearInterval(id);
  }, []);

  const queue = canAddr(queueAddr) ? queueAddr : undefined;
  const parsedEpoch = parseUint64(epoch);
  const reportHashOk = isBytes32(reportHash);

  const roleByKey = React.useMemo(() => {
    return new Map(roles.map((r) => [r.key, r.role]));
  }, []);

  const processorRoles = React.useMemo(() => {
    return [
      roleByKey.get("FARM_OPERATOR_ROLE"),
      roleByKey.get("TREASURY_ADMIN_ROLE"),
      roleByKey.get("GOVERNANCE_ROLE"),
      roleByKey.get("DEFAULT_ADMIN_ROLE")
    ].filter(Boolean) as `0x${string}`[];
  }, [roleByKey]);

  const queueMeta = useQuery({
    queryKey: ["opsSettlementQueueMeta", queue],
    enabled: !!client && !!queue,
    queryFn: async (): Promise<QueueMeta> => {
      if (!client || !queue) return { requestCount: 0n };
      const [fundingManager, roleManager, campaignId, requestCount] = await Promise.all([
        client.readContract({ address: queue, abi: settlementQueueAbi, functionName: "fundingManager" }).catch(() => undefined),
        client.readContract({ address: queue, abi: settlementQueueAbi, functionName: "roleManager" }).catch(() => undefined),
        client.readContract({ address: queue, abi: settlementQueueAbi, functionName: "campaignId" }).catch(() => undefined),
        client.readContract({ address: queue, abi: settlementQueueAbi, functionName: "requestCount" }).catch(() => 0n)
      ]);
      return {
        fundingManager: fundingManager as `0x${string}` | undefined,
        roleManager: roleManager as `0x${string}` | undefined,
        campaignId: campaignId as `0x${string}` | undefined,
        requestCount: BigInt(requestCount as any)
      };
    }
  });

  const fundingMeta = useQuery({
    queryKey: ["opsSettlementFundingMeta", queueMeta.data?.fundingManager],
    enabled: !!client && !!queueMeta.data?.fundingManager,
    queryFn: async () => {
      if (!client || !queueMeta.data?.fundingManager) return undefined;
      const fundingManager = queueMeta.data.fundingManager;
      const [settlementAsset, registry, totalRaisedNet, settlementQueue] = await Promise.all([
        client.readContract({ address: fundingManager, abi: fundingManagerAbi, functionName: "settlementAsset" }).catch(() => undefined),
        client.readContract({ address: fundingManager, abi: fundingManagerAbi, functionName: "registry" }).catch(() => undefined),
        client.readContract({ address: fundingManager, abi: fundingManagerAbi, functionName: "totalRaisedNet" }).catch(() => 0n),
        client.readContract({ address: fundingManager, abi: fundingManagerAbi, functionName: "settlementQueue" }).catch(() => undefined)
      ]);
      return {
        settlementAsset: settlementAsset as `0x${string}` | undefined,
        registry: registry as `0x${string}` | undefined,
        totalRaisedNet: BigInt(totalRaisedNet as any),
        settlementQueue: settlementQueue as `0x${string}` | undefined
      };
    }
  });

  const campaignMeta = useQuery({
    queryKey: ["opsSettlementCampaignMeta", fundingMeta.data?.registry, queueMeta.data?.campaignId],
    enabled: !!client && !!fundingMeta.data?.registry && !!queueMeta.data?.campaignId,
    queryFn: async () => {
      if (!client || !fundingMeta.data?.registry || !queueMeta.data?.campaignId) return undefined;
      const c = (await client.readContract({
        address: fundingMeta.data.registry,
        abi: campaignRegistryAbi,
        functionName: "getCampaign",
        args: [queueMeta.data.campaignId]
      })) as any;
      return {
        fundingCap: BigInt(c?.fundingCap ?? 0),
        state: Number(c?.state ?? 0),
        settlementAsset: c?.settlementAsset as `0x${string}` | undefined
      };
    }
  });

  const assetMeta = useQuery({
    queryKey: ["opsSettlementAssetMeta", fundingMeta.data?.settlementAsset],
    enabled: !!client && !!fundingMeta.data?.settlementAsset && fundingMeta.data?.settlementAsset !== zeroAddress,
    queryFn: async () => {
      if (!client || !fundingMeta.data?.settlementAsset) return { symbol: "ASSET", decimals: 6 };
      const asset = fundingMeta.data.settlementAsset;
      const [symbol, decimals] = await Promise.all([
        client.readContract({ address: asset, abi: erc20AllowanceAbi, functionName: "symbol" }).catch(() => "ASSET"),
        client.readContract({ address: asset, abi: erc20DecimalsAbi, functionName: "decimals" }).catch(() => 6)
      ]);
      return { symbol: String(symbol || "ASSET"), decimals: Number(decimals ?? 6) };
    }
  });

  const roleCheck = useQuery({
    queryKey: ["opsSettlementRoleCheck", queueMeta.data?.roleManager, address],
    enabled: !!client && !!queueMeta.data?.roleManager && !!address,
    queryFn: async () => {
      if (!client || !queueMeta.data?.roleManager || !address) return { isProcessor: false, byRole: [] as { role: string; ok: boolean }[] };
      const roleManager = queueMeta.data.roleManager;
      const checks = await Promise.all(
        processorRoles.map(async (role) => {
          const ok = Boolean(
            await client.readContract({
              address: roleManager,
              abi: roleManagerAbi,
              functionName: "hasRole",
              args: [role, address]
            }).catch(() => false)
          );
          return { role, ok };
        })
      );
      return {
        isProcessor: checks.some((x) => x.ok),
        byRole: checks
      };
    }
  });

  const pendingRequests = useQuery({
    queryKey: ["opsSettlementPendingRequests", queue, env.NEXT_PUBLIC_DISCOVERY_FROM_BLOCK?.toString() ?? "auto"],
    enabled: !!client && !!queue,
    refetchInterval: 20_000,
    queryFn: async (): Promise<PendingRequest[]> => {
      if (!client || !queue) return [];

      const head = await client.getBlockNumber();
      const fromBlock = resolveDiscoveryFromBlock(head, env.NEXT_PUBLIC_DISCOVERY_FROM_BLOCK);
      const [created, failed] = await Promise.all([
        getLogsChunked({
          client,
          fromBlock,
          toBlock: head,
          maxChunk: 5_000n,
          params: {
            address: queue,
            abi: settlementQueueAbi,
            eventName: "RequestCreated"
          }
        }),
        getLogsChunked({
          client,
          fromBlock,
          toBlock: head,
          maxChunk: 5_000n,
          params: {
            address: queue,
            abi: settlementQueueAbi,
            eventName: "RequestFailed"
          }
        })
      ]);

      const createdLogs = dedupeLogs(created as any[]);
      const failedLogs = dedupeLogs(failed as any[]);

      const sortedLogs = [...createdLogs].sort((a, b) => {
        const aB = BigInt(a?.blockNumber ?? 0);
        const bB = BigInt(b?.blockNumber ?? 0);
        if (aB === bB) return Number(b?.logIndex ?? 0) - Number(a?.logIndex ?? 0);
        return aB > bB ? -1 : 1;
      });

      const byId = new Map<string, any>();
      for (const log of sortedLogs) {
        const id = BigInt(log?.args?.id ?? 0).toString();
        if (!byId.has(id)) byId.set(id, log);
      }

      const sortedFailed = [...failedLogs].sort((a, b) => {
        const aB = BigInt(a?.blockNumber ?? 0);
        const bB = BigInt(b?.blockNumber ?? 0);
        if (aB === bB) return Number(b?.logIndex ?? 0) - Number(a?.logIndex ?? 0);
        return aB > bB ? -1 : 1;
      });

      const lastFailById = new Map<string, any>();
      const failCountById = new Map<string, number>();
      for (const log of sortedFailed) {
        const id = BigInt(log?.args?.id ?? 0).toString();
        if (!lastFailById.has(id)) lastFailById.set(id, log);
        failCountById.set(id, (failCountById.get(id) ?? 0) + 1);
      }

      const ids = [...byId.keys()].slice(0, 250);
      const out: PendingRequest[] = [];

      for (let i = 0; i < ids.length; i += 25) {
        const chunk = ids.slice(i, i + 25);
        const rows = await Promise.all(
          chunk.map(async (idStr): Promise<PendingRequest | undefined> => {
            const log = byId.get(idStr);
            const id = BigInt(idStr);
            try {
              const req = (await client.readContract({
                address: queue,
                abi: settlementQueueAbi,
                functionName: "getRequest",
                args: [id]
              })) as any;
              if (Number(req?.status ?? 0) !== 1) return undefined;
              return {
                id,
                account: req?.account as `0x${string}`,
                kind: Number(req?.kind ?? 0),
                amount: BigInt(req?.amount ?? 0),
                minOut: BigInt(req?.minOut ?? 0),
                maxIn: BigInt(req?.maxIn ?? 0),
                deadline: Number(req?.deadline ?? 0),
                createdBlock: BigInt(log?.blockNumber ?? 0),
                failCount: failCountById.get(idStr) ?? 0,
                lastFailData: (lastFailById.get(idStr)?.args?.revertData ?? undefined) as `0x${string}` | undefined,
                lastFailBlock: lastFailById.has(idStr) ? BigInt(lastFailById.get(idStr)?.blockNumber ?? 0) : undefined
              };
            } catch {
              return undefined;
            }
          })
        );
        out.push(...rows.filter((x): x is PendingRequest => Boolean(x)));
      }

      const unique = new Map<string, PendingRequest>();
      for (const row of out) {
        unique.set(row.id.toString(), row);
      }
      return [...unique.values()].sort((a, b) => (a.id > b.id ? -1 : 1));
    }
  });

  const rows = React.useMemo(() => pendingRequests.data ?? EMPTY_ROWS, [pendingRequests.data]);

  React.useEffect(() => {
    const known = new Set(rows.map((r) => r.id.toString()));
    setSelectedIds((prev) => {
      let changed = false;
      const next = new Set<string>();
      for (const id of prev) {
        if (known.has(id)) {
          next.add(id);
        } else {
          changed = true;
        }
      }
      if (!changed && next.size === prev.size) return prev;
      return next;
    });
  }, [rows]);

  const selectedRows = React.useMemo(() => rows.filter((r) => selectedIds.has(r.id.toString())), [rows, selectedIds]);
  const selectedIdList = React.useMemo(() => selectedRows.map((r) => r.id).sort((a, b) => (a < b ? -1 : 1)), [selectedRows]);
  const allSelected = rows.length > 0 && rows.every((r) => selectedIds.has(r.id.toString()));
  const rowById = React.useMemo(() => {
    const out = new Map<string, PendingRequest>();
    for (const row of rows) {
      out.set(row.id.toString(), row);
    }
    return out;
  }, [rows]);
  const processGas = React.useMemo(() => estimateProcessGas(selectedRows), [selectedRows]);

  const selectedDepositRows = React.useMemo(() => selectedRows.filter((r) => r.kind === 0), [selectedRows]);
  const selectedExpired = React.useMemo(
    () => selectedRows.filter((r) => r.deadline !== 0 && r.deadline < nowTs),
    [selectedRows, nowTs]
  );

  const requiredDepositAssets = React.useMemo(
    () => selectedDepositRows.reduce((acc, r) => acc + (r.maxIn > 0n ? r.maxIn : r.amount), 0n),
    [selectedDepositRows]
  );

  const allowancePrechecks = useQuery({
    queryKey: [
      "opsSettlementAllowancePrechecks",
      fundingMeta.data?.settlementAsset,
      queueMeta.data?.fundingManager,
      selectedDepositRows.map((r) => r.id.toString()).join(",")
    ],
    enabled:
      !!client &&
      !!fundingMeta.data?.settlementAsset &&
      !!queueMeta.data?.fundingManager &&
      selectedDepositRows.length > 0,
    queryFn: async () => {
      if (!client || !fundingMeta.data?.settlementAsset || !queueMeta.data?.fundingManager) {
        return { allowanceIssues: [] as string[], balanceIssues: [] as string[] };
      }
      const asset = fundingMeta.data.settlementAsset;
      const spender = queueMeta.data.fundingManager;
      const accounts = uniq(selectedDepositRows.map((r) => r.account.toLowerCase()));
      const accountState = new Map<string, { allowance: bigint; balance: bigint }>();

      await Promise.all(
        accounts.map(async (acc) => {
          const owner = acc as `0x${string}`;
          const [allowance, balance] = await Promise.all([
            client.readContract({
              address: asset,
              abi: erc20AllowanceAbi,
              functionName: "allowance",
              args: [owner, spender]
            }).catch(() => 0n),
            client.readContract({
              address: asset,
              abi: erc20Abi,
              functionName: "balanceOf",
              args: [owner]
            }).catch(() => 0n)
          ]);
          accountState.set(acc, { allowance: BigInt(allowance as any), balance: BigInt(balance as any) });
        })
      );

      const allowanceIssues: string[] = [];
      const balanceIssues: string[] = [];
      const remaining = new Map<string, { allowance: bigint; balance: bigint }>();
      for (const [acc, state] of accountState.entries()) {
        remaining.set(acc, { allowance: state.allowance, balance: state.balance });
      }

      const ordered = [...selectedDepositRows].sort((a, b) => (a.id < b.id ? -1 : 1));
      for (const req of ordered) {
        const need = req.maxIn > 0n ? req.maxIn : req.amount;
        const state = remaining.get(req.account.toLowerCase());
        if (!state) continue;
        if (state.allowance < need) allowanceIssues.push(req.id.toString());
        else state.allowance -= need;
        if (state.balance < need) balanceIssues.push(req.id.toString());
        else state.balance -= need;
      }
      return { allowanceIssues, balanceIssues };
    }
  });

  const rowAccountChecks = useQuery({
    queryKey: [
      "opsSettlementRowAccountChecks",
      fundingMeta.data?.settlementAsset,
      queueMeta.data?.fundingManager,
      rows.map((r) => r.id.toString()).join(",")
    ],
    enabled: !!client && !!fundingMeta.data?.settlementAsset && !!queueMeta.data?.fundingManager && rows.length > 0,
    queryFn: async () => {
      if (!client || !fundingMeta.data?.settlementAsset || !queueMeta.data?.fundingManager) {
        return new Map<string, { need: bigint; allowance: bigint; balance: bigint }>();
      }
      const asset = fundingMeta.data.settlementAsset;
      const spender = queueMeta.data.fundingManager;
      const accounts = uniq(rows.filter((r) => r.kind === 0).map((r) => r.account.toLowerCase()));
      const accountState = new Map<string, { allowance: bigint; balance: bigint }>();

      await Promise.all(
        accounts.map(async (acc) => {
          const owner = acc as `0x${string}`;
          const [allowance, balance] = await Promise.all([
            client.readContract({
              address: asset,
              abi: erc20AllowanceAbi,
              functionName: "allowance",
              args: [owner, spender]
            }).catch(() => 0n),
            client.readContract({
              address: asset,
              abi: erc20Abi,
              functionName: "balanceOf",
              args: [owner]
            }).catch(() => 0n)
          ]);
          accountState.set(acc, { allowance: BigInt(allowance as any), balance: BigInt(balance as any) });
        })
      );

      const byId = new Map<string, { need: bigint; allowance: bigint; balance: bigint }>();
      for (const req of rows) {
        if (req.kind !== 0) continue;
        const need = req.maxIn > 0n ? req.maxIn : req.amount;
        const st = accountState.get(req.account.toLowerCase());
        byId.set(req.id.toString(), {
          need,
          allowance: st?.allowance ?? 0n,
          balance: st?.balance ?? 0n
        });
      }
      return byId;
    }
  });

  const simulation = useQuery({
    queryKey: [
      "opsSettlementSimulation",
      queue,
      address,
      selectedIdList.map((x) => x.toString()).join(","),
      parsedEpoch?.toString() ?? "none",
      reportHash
    ],
    enabled: !!client && !!queue && !!address && selectedIdList.length > 0 && !!parsedEpoch && reportHashOk,
    queryFn: async () => {
      if (!client || !queue || !address || !parsedEpoch || !reportHashOk) return { ok: false, error: "missing params" };
      try {
        await client.simulateContract({
          account: address,
          address: queue,
          abi: settlementQueueAbi,
          functionName: "batchProcess",
          args: [selectedIdList, parsedEpoch, reportHash as `0x${string}`]
        });
        return { ok: true, error: "" };
      } catch (error: any) {
        return { ok: false, error: error?.shortMessage || error?.message || "simulation failed" };
      }
    }
  });

  const fundingCap = campaignMeta.data?.fundingCap ?? 0n;
  const totalRaisedNet = fundingMeta.data?.totalRaisedNet ?? 0n;
  const capRemaining = fundingCap > totalRaisedNet ? fundingCap - totalRaisedNet : 0n;
  const capWarning = fundingCap > 0n && requiredDepositAssets > capRemaining;
  const fmQueueLink = fundingMeta.data?.settlementQueue;
  const fmQueueMismatch = Boolean(
    queue &&
    fmQueueLink &&
    fmQueueLink.toLowerCase() !== queue.toLowerCase()
  );

  const hasProcessorRole = roleCheck.data?.isProcessor ?? false;
  const inputErrors: string[] = [];
  if (!queue) inputErrors.push("Queue address required");
  if (!parsedEpoch) inputErrors.push("Epoch must be uint64");
  if (!reportHashOk) inputErrors.push("Report hash must be bytes32");
  if (selectedIdList.length === 0) inputErrors.push("Select at least one request");
  if (selectedIdList.length > MAX_BATCH_RECOMMENDED) inputErrors.push(`Batch size > ${MAX_BATCH_RECOMMENDED} (risk)`);
  if (isConnected && roleCheck.data && !hasProcessorRole) inputErrors.push("Connected wallet has no processor role");
  if (fmQueueMismatch) inputErrors.push("FundingManager settlementQueue mismatch");
  if (selectedDepositRows.length > 0) {
    if (allowancePrechecks.isLoading) {
      inputErrors.push("Allowance/balance prechecks pending");
    } else if (allowancePrechecks.isError) {
      inputErrors.push("Allowance/balance prechecks unavailable");
    } else {
      const allowanceIds = allowancePrechecks.data?.allowanceIssues ?? [];
      const balanceIds = allowancePrechecks.data?.balanceIssues ?? [];
      if (allowanceIds.length > 0) {
        inputErrors.push(`Insufficient cumulative allowance: ${fmtIdList(allowanceIds)}`);
      }
      if (balanceIds.length > 0) {
        inputErrors.push(`Insufficient cumulative balance: ${fmtIdList(balanceIds)}`);
      }
    }
  }

  const onToggle = (id: string, checked: boolean) => {
    setSelectedIds((prev) => {
      const next = new Set(prev);
      if (checked) next.add(id);
      else next.delete(id);
      return next;
    });
  };

  const onSelectAll = () => {
    if (allSelected) {
      setSelectedIds(new Set());
      return;
    }
    setSelectedIds(new Set(rows.map((r) => r.id.toString())));
  };

  const onProcess = async () => {
    if (!queue || !parsedEpoch || !reportHashOk || selectedIdList.length === 0) return;
    setTxPending(true);
    try {
        const hash = await sendTx({
          title: `Batch process ${selectedIdList.length} requests`,
          address: queue,
          abi: settlementQueueAbi,
          functionName: "batchProcess",
          args: [selectedIdList, parsedEpoch, reportHash as `0x${string}`],
          gas: processGas > 0n ? processGas : undefined
        } as any);
        if (client && hash) {
          await client.waitForTransactionReceipt({ hash, confirmations: 1 });
        }
      setSelectedIds(new Set());
      await Promise.all([
        pendingRequests.refetch(),
        queueMeta.refetch(),
        simulation.refetch(),
        allowancePrechecks.refetch(),
        rowAccountChecks.refetch()
      ]);
    } finally {
      setTxPending(false);
    }
  };

  const onProcessOneByOne = async () => {
    if (!queue || !parsedEpoch || !reportHashOk || selectedIdList.length === 0) return;
    setTxPending(true);
    try {
      for (const id of selectedIdList) {
        const row = rowById.get(id.toString());
        const singleGas = row ? estimateProcessGas([row]) : PROCESS_GAS_MIN_SINGLE;
        const hash = await sendTx({
          title: `Process request #${id.toString()}`,
          address: queue,
          abi: settlementQueueAbi,
          functionName: "batchProcess",
          args: [[id], parsedEpoch, reportHash as `0x${string}`],
          gas: singleGas
        } as any);
        if (client && hash) {
          await client.waitForTransactionReceipt({ hash, confirmations: 1 });
        }
      }
      setSelectedIds(new Set());
      await Promise.all([
        pendingRequests.refetch(),
        queueMeta.refetch(),
        simulation.refetch(),
        allowancePrechecks.refetch(),
        rowAccountChecks.refetch()
      ]);
    } finally {
      setTxPending(false);
    }
  };

  const onCancelSelected = async () => {
    if (!queue || selectedIdList.length === 0) return;
    setTxPending(true);
    try {
      for (const id of selectedIdList) {
        const hash = await sendTx({
          title: `Cancel request #${id.toString()}`,
          address: queue,
          abi: settlementQueueAbi,
          functionName: "cancel",
          args: [id]
        } as any);
        if (client && hash) {
          await client.waitForTransactionReceipt({ hash, confirmations: 1 });
        }
      }
      setSelectedIds(new Set());
      await Promise.all([
        pendingRequests.refetch(),
        queueMeta.refetch(),
        simulation.refetch(),
        allowancePrechecks.refetch(),
        rowAccountChecks.refetch()
      ]);
    } finally {
      setTxPending(false);
    }
  };

  const assetSymbol = assetMeta.data?.symbol ?? "ASSET";
  const assetDecimals = assetMeta.data?.decimals ?? 6;

  return (
    <div>
      <PageHeader title="Admin · Settlement" subtitle="Ops console for SettlementQueue batchProcess with prechecks and simulation." />

      <div className="grid gap-4">
        <Card>
          <CardHeader>
            <CardTitle>Batch Target</CardTitle>
            <CardDescription>Queue config + batch params. All writes are recorded in local Activity.</CardDescription>
          </CardHeader>
          <CardContent className="space-y-3">
            <div className="grid gap-2 md:grid-cols-3">
              <Input value={queueAddr} onChange={(e) => setQueueAddr(e.target.value)} placeholder="SettlementQueue 0x..." />
              <Input value={epoch} onChange={(e) => setEpoch(e.target.value)} placeholder="Epoch (uint64)" />
              <Input value={reportHash} onChange={(e) => setReportHash(e.target.value)} placeholder="Report hash (bytes32)" />
            </div>

            <div className="flex flex-wrap items-center gap-2">
              <Badge tone={queue ? "good" : "warn"}>{queue ? "Queue OK" : "Queue missing"}</Badge>
              <Badge tone={reportHashOk ? "good" : "warn"}>{reportHashOk ? "Report hash OK" : "Bad report hash"}</Badge>
              <Badge tone={parsedEpoch ? "good" : "warn"}>{parsedEpoch ? "Epoch OK" : "Bad epoch"}</Badge>
              <Badge tone={hasProcessorRole ? "good" : "warn"}>{hasProcessorRole ? "Processor role OK" : "No processor role"}</Badge>
              <Badge tone={fmQueueMismatch ? "bad" : fmQueueLink ? "good" : "warn"}>
                {fmQueueMismatch ? "FM->Queue mismatch" : fmQueueLink ? "FM->Queue linked" : "FM->Queue unknown"}
              </Badge>
              <Badge tone="default">Selected {selectedIdList.length}</Badge>
              <Badge tone="default">Pending {rows.length}</Badge>
              <Badge tone="default">Process gas ~{fmtGas(processGas)}</Badge>
            </div>

            <div className="grid gap-2 text-xs text-text2 md:grid-cols-3">
              <div>FundingManager: {queueMeta.data?.fundingManager ? shortAddr(queueMeta.data.fundingManager, 6) : "-"}</div>
              <div>RoleManager: {queueMeta.data?.roleManager ? shortAddr(queueMeta.data.roleManager, 6) : "-"}</div>
              <div>FM settlementQueue: {fmQueueLink ? shortAddr(fmQueueLink, 6) : "-"}</div>
              <div>CampaignId: {queueMeta.data?.campaignId ? queueMeta.data.campaignId.slice(0, 14) + "..." : "-"}</div>
              <div>Total requests: {queueMeta.data?.requestCount?.toString() ?? "0"}</div>
            </div>

            <div className="flex flex-wrap items-center gap-2">
              <Button variant="secondary" onClick={() => pendingRequests.refetch()} disabled={!queue}>
                Refresh pending
              </Button>
              <Button variant="secondary" onClick={onSelectAll} disabled={rows.length === 0}>
                {allSelected ? "Clear selection" : "Select all visible"}
              </Button>
              <Button onClick={onProcess} disabled={!isConnected || inputErrors.length > 0 || txPending}>
                {txPending ? "Processing..." : "Process selected"}
              </Button>
              <Button variant="secondary" onClick={onProcessOneByOne} disabled={!isConnected || inputErrors.length > 0 || txPending}>
                Process 1-by-1
              </Button>
              <Button variant="secondary" onClick={onCancelSelected} disabled={!isConnected || selectedIdList.length === 0 || txPending}>
                Cancel selected
              </Button>
            </div>

            {inputErrors.length > 0 ? (
              <div className="flex flex-wrap gap-2">
                {inputErrors.map((e) => (
                  <Badge key={e} tone="warn">{e}</Badge>
                ))}
              </div>
            ) : null}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Prechecks</CardTitle>
            <CardDescription>Expiries, cap risk, requester allowances/balances (cumulative per selected batch) and call simulation.</CardDescription>
          </CardHeader>
          <CardContent className="space-y-3">
            <div className="grid gap-2 md:grid-cols-3">
              <div className="rounded-xl border border-border bg-muted p-3 text-sm">
                <div className="text-text2">Expired in selection</div>
                <div className="mt-1 font-mono">{selectedExpired.length}</div>
              </div>
              <div className="rounded-xl border border-border bg-muted p-3 text-sm">
                <div className="text-text2">Allowance issues</div>
                <div className="mt-1 font-mono">{allowancePrechecks.data?.allowanceIssues.length ?? 0}</div>
                {(allowancePrechecks.data?.allowanceIssues.length ?? 0) > 0 ? (
                  <div className="mt-1 text-xs text-bad">{fmtIdList(allowancePrechecks.data?.allowanceIssues ?? [], 6)}</div>
                ) : null}
              </div>
              <div className="rounded-xl border border-border bg-muted p-3 text-sm">
                <div className="text-text2">Balance issues</div>
                <div className="mt-1 font-mono">{allowancePrechecks.data?.balanceIssues.length ?? 0}</div>
                {(allowancePrechecks.data?.balanceIssues.length ?? 0) > 0 ? (
                  <div className="mt-1 text-xs text-bad">{fmtIdList(allowancePrechecks.data?.balanceIssues ?? [], 6)}</div>
                ) : null}
              </div>
            </div>

            <div className="rounded-xl border border-border bg-muted p-3 text-sm">
              <div className="text-text2">
                Selected deposit assets (conservative):{" "}
                <span className="font-mono">{fmtAmt(requiredDepositAssets, assetDecimals)} {assetSymbol}</span>
              </div>
              <div className="mt-1 text-text2">
                Cap remaining:{" "}
                <span className="font-mono">
                  {fundingCap > 0n ? `${fmtAmt(capRemaining, assetDecimals)} ${assetSymbol}` : "Unlimited / unavailable"}
                </span>
              </div>
              {capWarning ? <div className="mt-2 text-bad">Selected deposits may exceed remaining campaign cap.</div> : null}
            </div>

            <div className="flex flex-wrap items-center gap-2">
              <Badge tone={simulation.data?.ok ? "good" : simulation.data ? "bad" : "default"}>
                {simulation.data?.ok ? "Simulation OK" : simulation.data ? "Simulation failed" : "Simulation pending"}
              </Badge>
              {selectedIdList.length > MAX_BATCH_RECOMMENDED ? (
                <Badge tone="warn">Large batch selected ({selectedIdList.length})</Badge>
              ) : null}
              {reportHash === "0x" + "00".repeat(32) ? <Badge tone="warn">reportHash is zero</Badge> : null}
            </div>

            {simulation.data && !simulation.data.ok ? (
              <div className="rounded-xl border border-bad/30 bg-bad/10 p-3 text-sm text-bad">
                {simulation.data.error}
              </div>
            ) : null}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Pending Requests</CardTitle>
            <CardDescription>Select multiple requests and run batchProcess without Foundry scripts. A successful tx can still leave requests pending if they emit RequestFailed.</CardDescription>
          </CardHeader>
          <CardContent>
            {pendingRequests.isLoading ? (
              <div className="text-sm text-text2">Loading pending requests...</div>
            ) : rows.length === 0 ? (
              <EmptyState title="No pending requests" description="No RequestCreated entries in Requested status were found for this queue." />
            ) : (
              <>
                <div className="hidden md:block">
                  <div className="overflow-x-auto rounded-xl border border-border/80">
                    <table className="w-full min-w-[980px] text-left text-sm">
                      <thead className="bg-muted text-text2">
                        <tr>
                          <th className="px-3 py-2"><input type="checkbox" checked={allSelected} onChange={() => onSelectAll()} /></th>
                          <th className="px-3 py-2 font-medium">ID</th>
                          <th className="px-3 py-2 font-medium">Account</th>
                          <th className="px-3 py-2 font-medium">Kind</th>
                          <th className="px-3 py-2 font-medium">Amount</th>
                          <th className="px-3 py-2 font-medium">Limits</th>
                          <th className="px-3 py-2 font-medium">Deadline</th>
                          <th className="px-3 py-2 font-medium">Last Failure</th>
                        </tr>
                      </thead>
                      <tbody>
                        {rows.map((r) => {
                          const id = r.id.toString();
                          const checked = selectedIds.has(id);
                          const expired = r.deadline !== 0 && r.deadline < nowTs;
                          const failed = r.failCount > 0;
                          const check = rowAccountChecks.data?.get(id);
                          const lowAllowance = !!check && check.allowance < check.need;
                          const lowBalance = !!check && check.balance < check.need;
                          return (
                            <tr key={id} className="border-t border-border/70">
                              <td className="px-3 py-2">
                                <input type="checkbox" checked={checked} onChange={(e) => onToggle(id, e.target.checked)} />
                              </td>
                              <td className="px-3 py-2 font-mono">#{id}</td>
                              <td className="px-3 py-2">{shortAddr(r.account, 6)}</td>
                              <td className="px-3 py-2">{r.kind === 0 ? "DEPOSIT" : "REDEEM"}</td>
                              <td className="px-3 py-2 font-mono">
                                {r.kind === 0
                                  ? (r.maxIn > 0n ? `${fmtAmt(r.amount, 18)} shares` : `${fmtAmt(r.amount, assetDecimals)} ${assetSymbol}`)
                                  : `${fmtAmt(r.amount, 18)} shares`}
                              </td>
                              <td className="px-3 py-2 text-xs text-text2">
                                {r.kind === 0
                                  ? (r.maxIn > 0n
                                    ? `maxIn ${fmtAmt(r.maxIn, assetDecimals)} ${assetSymbol}`
                                    : `minOut ${fmtAmt(r.minOut, 18)} shares`)
                                  : `minOut ${fmtAmt(r.minOut, assetDecimals)} ${assetSymbol}`}
                              </td>
                              <td className="px-3 py-2 text-xs">
                                <div>{fmtTs(r.deadline)}</div>
                                {expired ? <Badge tone="bad">Expired</Badge> : <Badge tone="warn">Requested</Badge>}
                              </td>
                              <td className="px-3 py-2 text-xs">
                                {failed ? (
                                  <div className="space-y-1">
                                    <Badge tone="bad">Failed x{r.failCount}</Badge>
                                    <div className="text-bad">{decodeFailData(r.lastFailData)}</div>
                                    {check ? (
                                      <div className="text-text2">
                                        Need {fmtAmt(check.need, assetDecimals)} / Allow {fmtAmt(check.allowance, assetDecimals)} / Bal {fmtAmt(check.balance, assetDecimals)} {assetSymbol}
                                      </div>
                                    ) : null}
                                    {lowAllowance || lowBalance ? (
                                      <div className="text-bad">
                                        Likely cause: {lowAllowance ? "allowance too low" : ""}{lowAllowance && lowBalance ? " + " : ""}{lowBalance ? "balance too low" : ""}.
                                      </div>
                                    ) : r.lastFailData === "0x" ? (
                                      <div className="text-bad">
                                        Likely cause: tx gas limit too low for this settlement path.
                                      </div>
                                    ) : null}
                                  </div>
                                ) : (
                                  <span className="text-text2">-</span>
                                )}
                              </td>
                            </tr>
                          );
                        })}
                      </tbody>
                    </table>
                  </div>
                </div>

                <div className="grid gap-3 md:hidden">
                  {rows.map((r) => {
                    const id = r.id.toString();
                    const checked = selectedIds.has(id);
                    const expired = r.deadline !== 0 && r.deadline < nowTs;
                    const failed = r.failCount > 0;
                    const check = rowAccountChecks.data?.get(id);
                    const lowAllowance = !!check && check.allowance < check.need;
                    const lowBalance = !!check && check.balance < check.need;
                    return (
                      <div key={id} className="rounded-xl border border-border/80 bg-card p-3">
                        <div className="flex items-start justify-between gap-2">
                          <div>
                            <div className="font-medium">Request #{id}</div>
                            <div className="mt-1 text-xs text-text2">{shortAddr(r.account, 6)}</div>
                          </div>
                          <input type="checkbox" checked={checked} onChange={(e) => onToggle(id, e.target.checked)} />
                        </div>
                        <div className="mt-2 text-xs text-text2">Kind: {r.kind === 0 ? "DEPOSIT" : "REDEEM"}</div>
                        <div className="mt-1 text-xs text-text2">
                          Amount: {r.kind === 0
                            ? (r.maxIn > 0n ? `${fmtAmt(r.amount, 18)} shares` : `${fmtAmt(r.amount, assetDecimals)} ${assetSymbol}`)
                            : `${fmtAmt(r.amount, 18)} shares`}
                        </div>
                        <div className="mt-1 text-xs text-text2">Deadline: {fmtTs(r.deadline)}</div>
                        <div className="mt-2">{expired ? <Badge tone="bad">Expired</Badge> : <Badge tone="warn">Requested</Badge>}</div>
                        {failed ? (
                          <div className="mt-2 space-y-1 text-xs">
                            <div className="text-bad">Failed x{r.failCount}: {decodeFailData(r.lastFailData)}</div>
                            {check ? (
                              <div className="text-text2">
                                Need {fmtAmt(check.need, assetDecimals)} / Allow {fmtAmt(check.allowance, assetDecimals)} / Bal {fmtAmt(check.balance, assetDecimals)} {assetSymbol}
                              </div>
                            ) : null}
                            {lowAllowance || lowBalance ? (
                              <div className="text-bad">
                                Likely cause: {lowAllowance ? "allowance too low" : ""}{lowAllowance && lowBalance ? " + " : ""}{lowBalance ? "balance too low" : ""}.
                              </div>
                            ) : r.lastFailData === "0x" ? (
                              <div className="text-bad">Likely cause: tx gas limit too low for this settlement path.</div>
                            ) : null}
                          </div>
                        ) : null}
                      </div>
                    );
                  })}
                </div>
              </>
            )}
          </CardContent>
        </Card>
      </div>
    </div>
  );
}
