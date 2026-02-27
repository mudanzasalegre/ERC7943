"use client";

import * as React from "react";
import { useQuery } from "@tanstack/react-query";
import { decodeErrorResult, formatUnits, parseUnits, zeroAddress } from "viem";
import { useAccount, useChainId, usePublicClient, useSwitchChain } from "wagmi";
import { base, baseSepolia } from "wagmi/chains";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/Card";
import { Button } from "@/components/ui/Button";
import { Input } from "@/components/ui/Input";
import { Badge } from "@/components/ui/Badge";
import { EmptyState } from "@/components/ui/EmptyState";
import { MobileStickyBar } from "@/components/ui/MobileStickyBar";
import {
  complianceAbi,
  disasterViewAbi,
  distributionAbi,
  erc20Abi,
  erc20AllowanceAbi,
  erc20DecimalsAbi,
  fundingManagerAbi,
  settlementQueueAbi,
  shareTokenAbi,
  yieldAccumulatorAbi
} from "@/lib/abi";
import { getPublicEnv } from "@/lib/env";
import { getLogsChunked } from "@/lib/discovery";
import { resolveDiscoveryFromBlock } from "@/lib/campaignDiscovery";
import { resolveAddressesForChain } from "@/lib/addresses";
import { cn } from "@/lib/cn";
import { explorerTxUrl } from "@/lib/explorer";
import { useTokenModules } from "@/hooks/useTokenModules";
import { useTx } from "@/hooks/useTx";
import { useAppMode } from "@/hooks/useAppMode";

type QueueReq = {
  id: bigint;
  kind: number;
  amount: bigint;
  minOut: bigint;
  maxIn: bigint;
  deadline: number;
  status: number;
  outAmount?: bigint;
  failCount: number;
  failedActive: boolean;
  lastFailData?: `0x${string}`;
};

type RewardClaimHistoryRow = {
  id: string;
  txHash?: `0x${string}`;
  blockNumber: bigint;
  logIndex: number;
  amount: bigint;
  timestamp?: number;
};

const K: Record<number, string> = { 0: "DEPOSIT", 1: "REDEEM" };
const S: Record<number, string> = { 0: "NONE", 1: "REQUESTED", 2: "CANCELLED", 3: "PROCESSED" };
const PAUSE_CLAIMS_FLAG = 1n << 3n;

const isLive = (a?: string): a is `0x${string}` =>
  Boolean(a && a.startsWith("0x") && a.length === 42 && a.toLowerCase() !== zeroAddress);

const toN = (v: unknown) => (typeof v === "bigint" ? Number(v) : Number(v ?? 0));

const parseAmt = (v: string, d: number): bigint | undefined => {
  const s = v.trim();
  if (!s) return undefined;
  try {
    return parseUnits(s, d);
  } catch {
    return undefined;
  }
};

const fmt = (v: bigint, d: number, p = 4) => {
  const full = formatUnits(v, d);
  const [i, f] = full.split(".");
  return f ? `${i}.${f.slice(0, p)}` : i;
};

function switchTargetChain(): number {
  if (resolveAddressesForChain(base.id).isConfigured) return base.id;
  if (resolveAddressesForChain(baseSepolia.id).isConfigured) return baseSepolia.id;
  return baseSepolia.id;
}

function statusView(req: QueueReq, now: number): {
  label: string;
  tone: "warn" | "bad" | "good" | "default";
  expired: boolean;
  failed: boolean;
} {
  const expired = req.status === 1 && req.deadline > 0 && req.deadline < now;
  const failed = req.status === 1 && req.failedActive;
  if (expired) return { label: "EXPIRED", tone: "bad", expired: true, failed: false };
  if (failed) return { label: "FAILED", tone: "bad", expired: false, failed: true };
  if (req.status === 3) return { label: "PROCESSED", tone: "good", expired: false, failed: false };
  if (req.status === 2) return { label: "CANCELLED", tone: "default", expired: false, failed: false };
  return { label: S[req.status] ?? `STATUS ${req.status}`, tone: "warn", expired: false, failed: false };
}

function latestById(logs: any[]) {
  const m = new Map<string, any>();
  for (const log of logs) {
    const id = BigInt(log?.args?.id ?? 0).toString();
    const prev = m.get(id);
    const aB = BigInt(log?.blockNumber ?? 0);
    const pB = BigInt(prev?.blockNumber ?? 0);
    const later = !prev || aB > pB || (aB === pB && Number(log?.logIndex ?? 0) > Number(prev?.logIndex ?? 0));
    if (later) m.set(id, log);
  }
  return m;
}

function dedupeLogs<T extends any>(logs: T[]): T[] {
  const m = new Map<string, T>();
  for (const log of logs) {
    const key = `${String((log as any)?.transactionHash ?? "0x")}:${String((log as any)?.logIndex ?? 0)}`;
    if (!m.has(key)) m.set(key, log);
  }
  return [...m.values()];
}

function isLaterLog(a?: any, b?: any): boolean {
  if (!a) return false;
  if (!b) return true;
  const aBlock = BigInt(a?.blockNumber ?? 0);
  const bBlock = BigInt(b?.blockNumber ?? 0);
  if (aBlock !== bBlock) return aBlock > bBlock;
  return Number(a?.logIndex ?? 0) > Number(b?.logIndex ?? 0);
}

function decodeFailData(data?: `0x${string}`): string {
  if (!data || data === "0x") return "Unknown error";
  try {
    return decodeErrorResult({ abi: fundingManagerAbi, data }).errorName;
  } catch {
    // try fallback abi
  }
  try {
    return decodeErrorResult({ abi: settlementQueueAbi, data }).errorName;
  } catch {
    // unknown selector
  }
  return `${data.slice(0, 10)}...`;
}

function fmtTs(ts?: number): string {
  if (!Number.isFinite(ts) || !ts || ts <= 0) return "-";
  return new Date(ts * 1000).toLocaleString();
}

function queryHref(path: string, params: Record<string, string | undefined>): string {
  const q = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) {
    if (!v) continue;
    q.set(k, v);
  }
  const qs = q.toString();
  return qs ? `${path}?${qs}` : path;
}

export function CampaignActions({
  token,
  campaignId,
  settlementAsset,
  shareDecimals = 18,
  showInvest = true,
  showRewards = true
}: {
  token: `0x${string}`;
  campaignId?: `0x${string}`;
  settlementAsset?: `0x${string}`;
  shareDecimals?: number;
  showInvest?: boolean;
  showRewards?: boolean;
}) {
  const env = getPublicEnv();
  const chainId = useChainId();
  const appMode = useAppMode();
  const client = usePublicClient();
  const { address, isConnected } = useAccount();
  const { switchChain, isPending: switchingChain } = useSwitchChain();
  const modules = useTokenModules(token);
  const { sendTx } = useTx();

  const queue = isLive(modules.data?.settlementQueue) ? modules.data?.settlementQueue : undefined;
  const asset = isLive(settlementAsset) ? settlementAsset : undefined;
  const distribution = isLive(modules.data?.distribution) ? modules.data?.distribution : undefined;
  const disaster = isLive(modules.data?.disaster) ? modules.data?.disaster : undefined;
  const complianceModule = isLive(modules.data?.compliance) ? modules.data?.compliance : undefined;
  const supported = chainId === base.id || chainId === baseSepolia.id;
  const wrongNet = isConnected && (!supported || (appMode.mode === "demo" && appMode.hasAnyAddressBook));
  const canWrite = isConnected && !wrongNet;

  const [depA, setDepA] = React.useState("100");
  const [depB, setDepB] = React.useState("0");
  const [redShares, setRedShares] = React.useState("10");
  const [redMinOut, setRedMinOut] = React.useState("0");
  const [deadlineMin, setDeadlineMin] = React.useState("60");
  const [now, setNow] = React.useState(() => Math.floor(Date.now() / 1000));
  const [txPending, setTxPending] = React.useState(false);
  const txLockRef = React.useRef(false);
  React.useEffect(() => {
    const i = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 10_000);
    return () => clearInterval(i);
  }, []);

  const qInfo = useQuery({
    queryKey: ["queueInfo", queue],
    enabled: showInvest && !!client && !!queue,
    queryFn: async () => {
      if (!client || !queue) return { exactShares: false, count: 0n, fundingManager: undefined as `0x${string}` | undefined };
      const [exactShares, count, fundingManager] = await Promise.all([
        client.readContract({ address: queue, abi: settlementQueueAbi, functionName: "depositExactSharesMode" }).catch(() => false),
        client.readContract({ address: queue, abi: settlementQueueAbi, functionName: "requestCount" }).catch(() => 0n),
        client.readContract({ address: queue, abi: settlementQueueAbi, functionName: "fundingManager" }).catch(() => undefined)
      ]);
      const fm = fundingManager as `0x${string}` | undefined;
      return {
        exactShares: Boolean(exactShares),
        count: BigInt(count as any),
        fundingManager: isLive(fm) ? fm : undefined
      };
    }
  });

  const compliance = useQuery({
    queryKey: ["canTransact", token, address],
    enabled: showInvest && !!client && !!address,
    queryFn: async () => {
      if (!client || !address) return true;
      return Boolean(await client.readContract({
        address: token,
        abi: shareTokenAbi,
        functionName: "canTransact",
        args: [address]
      }).catch(() => true));
    }
  });

  const shareBal = useQuery({
    queryKey: ["shareBal", token, address],
    enabled: showInvest && !!client && !!address,
    refetchInterval: showInvest && !!address ? 15_000 : false,
    queryFn: async () => {
      if (!client || !address) return 0n;
      return client.readContract({
        address: token,
        abi: shareTokenAbi,
        functionName: "balanceOf",
        args: [address]
      }) as Promise<bigint>;
    }
  });

  const assetCtx = useQuery({
    queryKey: ["assetCtx", asset, qInfo.data?.fundingManager, address],
    enabled: showInvest && !!client && !!asset,
    refetchInterval: showInvest && !!asset && !!address ? 15_000 : false,
    queryFn: async () => {
      if (!client || !asset) return { symbol: "ASSET", decimals: 6, balance: 0n, allowance: 0n };
      const spender = qInfo.data?.fundingManager;
      const [symbol, decimals, balance, allowance] = await Promise.all([
        client.readContract({ address: asset, abi: erc20AllowanceAbi, functionName: "symbol" }).catch(() => "ASSET"),
        client.readContract({ address: asset, abi: erc20DecimalsAbi, functionName: "decimals" }).catch(() => 6),
        address ? client.readContract({ address: asset, abi: erc20Abi, functionName: "balanceOf", args: [address] }).catch(() => 0n) : Promise.resolve(0n),
        address && spender
          ? client.readContract({ address: asset, abi: erc20AllowanceAbi, functionName: "allowance", args: [address, spender] }).catch(() => 0n)
          : Promise.resolve(0n)
      ]);
      return {
        symbol: String(symbol || "ASSET"),
        decimals: Number(decimals ?? 6),
        balance: BigInt(balance as any),
        allowance: BigInt(allowance as any)
      };
    }
  });

  const myReqs = useQuery({
    queryKey: ["myReqs", queue, address, env.NEXT_PUBLIC_DISCOVERY_FROM_BLOCK?.toString() ?? "auto"],
    enabled: showInvest && !!client && !!queue && !!address,
    refetchInterval: 20_000,
    queryFn: async (): Promise<QueueReq[]> => {
      if (!client || !queue || !address) return [];
      const head = await client.getBlockNumber();
      const from = resolveDiscoveryFromBlock(head, env.NEXT_PUBLIC_DISCOVERY_FROM_BLOCK);
      const [created, processed, failed, cancelled] = await Promise.all([
        getLogsChunked({ client, fromBlock: from, toBlock: head, maxChunk: 5_000n, params: { address: queue, abi: settlementQueueAbi, eventName: "RequestCreated", args: { account: address } } }),
        getLogsChunked({ client, fromBlock: from, toBlock: head, maxChunk: 5_000n, params: { address: queue, abi: settlementQueueAbi, eventName: "RequestProcessed", args: { account: address } } }),
        getLogsChunked({ client, fromBlock: from, toBlock: head, maxChunk: 5_000n, params: { address: queue, abi: settlementQueueAbi, eventName: "RequestFailed", args: { account: address } } }),
        getLogsChunked({ client, fromBlock: from, toBlock: head, maxChunk: 5_000n, params: { address: queue, abi: settlementQueueAbi, eventName: "RequestCancelled", args: { account: address } } })
      ]);
      const createdLogs = dedupeLogs(created as any[]);
      const processedLogs = dedupeLogs(processed as any[]);
      const failedLogs = dedupeLogs(failed as any[]);
      const cancelledLogs = dedupeLogs(cancelled as any[]);

      const ids = [...new Set(createdLogs.map((l) => BigInt(l?.args?.id ?? 0).toString()))]
        .map((x) => BigInt(x))
        .sort((a, b) => (a > b ? -1 : 1))
        .slice(0, 80);
      const processedById = latestById(processedLogs as any[]);
      const failedById = latestById(failedLogs as any[]);
      const cancelledById = latestById(cancelledLogs as any[]);
      const failCountById = new Map<string, number>();
      for (const log of failedLogs as any[]) {
        const id = BigInt(log?.args?.id ?? 0).toString();
        failCountById.set(id, (failCountById.get(id) ?? 0) + 1);
      }
      const rows = await Promise.all(ids.map(async (id): Promise<QueueReq | undefined> => {
        try {
          const r = await client.readContract({ address: queue, abi: settlementQueueAbi, functionName: "getRequest", args: [id] }) as any;
          const idStr = id.toString();
          const p = processedById.get(idStr);
          const f = failedById.get(idStr);
          const c = cancelledById.get(idStr);
          const status = toN(r.status);
          const failedActive = status === 1 && isLaterLog(f, p) && isLaterLog(f, c);
          return {
            id,
            kind: toN(r.kind),
            amount: BigInt(r.amount ?? 0),
            minOut: BigInt(r.minOut ?? 0),
            maxIn: BigInt(r.maxIn ?? 0),
            deadline: toN(r.deadline),
            status,
            outAmount: p ? BigInt(p?.args?.outAmount ?? 0) : undefined,
            failCount: failCountById.get(idStr) ?? 0,
            failedActive,
            lastFailData: failedActive ? (f?.args?.revertData as `0x${string}` | undefined) : undefined
          };
        } catch {
          return undefined;
        }
      }));
      return rows.filter((x): x is QueueReq => Boolean(x));
    }
  });

  const processedReqDigest = React.useMemo(
    () =>
      (myReqs.data ?? [])
        .filter((r) => r.status === 3)
        .map((r) => `${r.id.toString()}:${r.outAmount?.toString() ?? "na"}`)
        .join("|"),
    [myReqs.data]
  );

  const pending = useQuery({
    queryKey: ["pendingReward", distribution, address],
    enabled: showRewards && !!client && !!distribution && !!address,
    refetchInterval: showRewards && !!distribution && !!address ? 20_000 : false,
    queryFn: async () => {
      if (!client || !distribution || !address) return 0n;
      return client.readContract({
        address: distribution,
        abi: distributionAbi,
        functionName: "pending",
        args: [address]
      }) as Promise<bigint>;
    }
  });

  React.useEffect(() => {
    if (!isConnected) return;
    if (!processedReqDigest) return;
    void shareBal.refetch();
    void assetCtx.refetch();
    if (showRewards) void pending.refetch();
  }, [isConnected, processedReqDigest, showRewards]);

  const rewardMeta = useQuery({
    queryKey: ["rewardMeta", distribution],
    enabled: showRewards && !!client && !!distribution,
    queryFn: async () => {
      if (!client || !distribution) {
        return {
          rewardToken: asset,
          rewardSymbol: assetCtx.data?.symbol ?? "RWD",
          rewardDecimals: assetCtx.data?.decimals ?? 18,
          enforceComplianceOnClaim: false
        };
      }
      const [rewardTokenRaw, enforceComplianceOnClaim] = await Promise.all([
        client.readContract({ address: distribution, abi: yieldAccumulatorAbi, functionName: "rewardToken" }).catch(() => zeroAddress),
        client.readContract({ address: distribution, abi: yieldAccumulatorAbi, functionName: "enforceComplianceOnClaim" }).catch(() => false)
      ]);
      const rewardToken = rewardTokenRaw as `0x${string}`;
      if (!isLive(rewardToken)) {
        return {
          rewardToken: undefined,
          rewardSymbol: assetCtx.data?.symbol ?? "RWD",
          rewardDecimals: assetCtx.data?.decimals ?? 18,
          enforceComplianceOnClaim: Boolean(enforceComplianceOnClaim)
        };
      }
      const [rewardSymbol, rewardDecimals] = await Promise.all([
        client.readContract({ address: rewardToken, abi: erc20AllowanceAbi, functionName: "symbol" }).catch(() => "RWD"),
        client.readContract({ address: rewardToken, abi: erc20DecimalsAbi, functionName: "decimals" }).catch(() => 18)
      ]);
      return {
        rewardToken,
        rewardSymbol: String(rewardSymbol || "RWD"),
        rewardDecimals: Number(rewardDecimals ?? 18),
        enforceComplianceOnClaim: Boolean(enforceComplianceOnClaim)
      };
    }
  });

  const claimGuard = useQuery({
    queryKey: [
      "claimGuard",
      distribution,
      disaster,
      complianceModule,
      campaignId,
      address,
      rewardMeta.data?.enforceComplianceOnClaim ? "compliance-on-claim" : "compliance-off"
    ],
    enabled: showRewards && !!client && !!distribution && !!campaignId,
    queryFn: async () => {
      if (!client || !distribution || !campaignId) {
        return {
          paused: false,
          restricted: false,
          hardFrozen: false,
          complianceDenied: false
        };
      }

      let flags = 0n;
      let restricted = false;
      let hardFrozen = false;
      if (disaster) {
        const [flagsRaw, restrictedRaw, hardFrozenRaw] = await Promise.all([
          client.readContract({
            address: disaster,
            abi: disasterViewAbi,
            functionName: "campaignFlags",
            args: [campaignId]
          }).catch(() => 0n),
          client.readContract({
            address: disaster,
            abi: disasterViewAbi,
            functionName: "isRestricted",
            args: [campaignId]
          }).catch(() => false),
          client.readContract({
            address: disaster,
            abi: disasterViewAbi,
            functionName: "isHardFrozen",
            args: [campaignId]
          }).catch(() => false)
        ]);
        flags = BigInt(flagsRaw as any);
        restricted = Boolean(restrictedRaw);
        hardFrozen = Boolean(hardFrozenRaw);
      }

      let complianceDenied = false;
      if (rewardMeta.data?.enforceComplianceOnClaim && address) {
        if (!complianceModule) {
          complianceDenied = true;
        } else {
          const canTransact = Boolean(
            await client.readContract({
              address: complianceModule,
              abi: complianceAbi,
              functionName: "canTransact",
              args: [address]
            }).catch(() => false)
          );
          complianceDenied = !canTransact;
        }
      }

      return {
        paused: (flags & PAUSE_CLAIMS_FLAG) !== 0n,
        restricted,
        hardFrozen,
        complianceDenied
      };
    }
  });

  const claimHistory = useQuery({
    queryKey: ["claimHistory", distribution, address, env.NEXT_PUBLIC_DISCOVERY_FROM_BLOCK?.toString() ?? "auto"],
    enabled: showRewards && !!client && !!distribution && !!address,
    refetchInterval: 30_000,
    queryFn: async (): Promise<RewardClaimHistoryRow[]> => {
      if (!client || !distribution || !address) return [];
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
          eventName: "Claimed",
          args: { account: address }
        }
      });
      const rows = [...(logs as any[])]
        .map((log) => ({
          id: `${String(log?.transactionHash ?? "nohash")}:${String(log?.logIndex ?? 0)}`,
          txHash: log?.transactionHash as `0x${string}` | undefined,
          blockNumber: BigInt(log?.blockNumber ?? 0),
          logIndex: Number(log?.logIndex ?? 0),
          amount: BigInt(log?.args?.amount ?? 0)
        }))
        .sort((a, b) => {
          if (a.blockNumber === b.blockNumber) return b.logIndex - a.logIndex;
          return a.blockNumber > b.blockNumber ? -1 : 1;
        })
        .slice(0, 20);

      const blockKeys = [...new Set(rows.map((r) => r.blockNumber.toString()))];
      const timestampByBlock = new Map<string, number>();
      await Promise.all(
        blockKeys.map(async (k) => {
          try {
            const block = await client.getBlock({ blockNumber: BigInt(k) });
            timestampByBlock.set(k, Number(block.timestamp));
          } catch {
            // ignore block timestamp errors for history
          }
        })
      );

      return rows.map((row) => ({
        ...row,
        timestamp: timestampByBlock.get(row.blockNumber.toString())
      }));
    }
  });

  const exactShares = Boolean(qInfo.data?.exactShares);
  const queueSpender = qInfo.data?.fundingManager;
  const sym = assetCtx.data?.symbol ?? "ASSET";
  const aDec = assetCtx.data?.decimals ?? 6;
  const aBal = assetCtx.data?.balance ?? 0n;
  const allowance = assetCtx.data?.allowance ?? 0n;
  const sBal = shareBal.data ?? 0n;
  const rewardPending = pending.data ?? 0n;
  const rewardSym = rewardMeta.data?.rewardSymbol ?? sym;
  const rewardDec = rewardMeta.data?.rewardDecimals ?? aDec;
  const complianceHref = queryHref("/compliance", {
    token,
    compliance: complianceModule,
    from: address,
    to: address,
    amount: "1"
  });
  const onboardingHref = queryHref("/onboarding", {
    token,
    compliance: complianceModule,
    account: address
  });
  const adminSettlementHref = queryHref("/admin/settlement", { addr: queue });

  const withTxLock = React.useCallback(async (work: () => Promise<void>) => {
    if (txLockRef.current) return;
    txLockRef.current = true;
    setTxPending(true);
    try {
      await work();
    } finally {
      txLockRef.current = false;
      setTxPending(false);
    }
  }, []);

  const waitForTxFinality = React.useCallback(
    async (hash?: `0x${string}`) => {
      if (!client || !hash) return;
      await client.waitForTransactionReceipt({ hash, confirmations: 1 });
    },
    [client]
  );

  const mins = Number(deadlineMin);
  const deadline = Number.isFinite(mins) && mins >= 1 ? BigInt(now + Math.floor(mins * 60)) : undefined;

  const dep1 = parseAmt(depA, exactShares ? shareDecimals : aDec);
  const dep2raw = parseAmt(depB, exactShares ? aDec : shareDecimals);
  const dep2 = dep2raw ?? 0n;
  const reqAllowance = exactShares ? dep2raw : dep1;
  const red1 = parseAmt(redShares, shareDecimals);
  const red2 = parseAmt(redMinOut, aDec) ?? 0n;

  const depErr: string[] = [];
  if (!isConnected) depErr.push("Connect wallet");
  if (wrongNet) depErr.push("Wrong network");
  if (!queue) depErr.push("Queue unavailable");
  if (queue && !qInfo.isLoading && !queueSpender) depErr.push("FundingManager unavailable");
  if (!asset) depErr.push("Settlement asset unavailable");
  if (compliance.data === false) depErr.push("Compliance denied");
  if (!deadline) depErr.push("Invalid deadline");
  if (!dep1 || dep1 <= 0n) depErr.push(exactShares ? "Enter shares desired" : `Enter ${sym} amount`);
  if (exactShares && (!dep2raw || dep2raw <= 0n)) depErr.push("Enter max assets in");
  if (reqAllowance && reqAllowance > aBal) depErr.push(`Insufficient ${sym} balance`);
  if (reqAllowance && reqAllowance > allowance) depErr.push("Approval required");

  const redErr: string[] = [];
  if (!isConnected) redErr.push("Connect wallet");
  if (wrongNet) redErr.push("Wrong network");
  if (!queue) redErr.push("Queue unavailable");
  if (compliance.data === false) redErr.push("Compliance denied");
  if (!deadline) redErr.push("Invalid deadline");
  if (!red1 || red1 <= 0n) redErr.push("Enter shares");
  if (red1 && red1 > sBal) redErr.push("Insufficient shares");

  const rewardErr: string[] = [];
  if (!isConnected) rewardErr.push("Connect wallet");
  if (wrongNet) rewardErr.push("Wrong network");
  if (!distribution) rewardErr.push("Distribution unavailable");
  if (rewardPending <= 0n) rewardErr.push("No pending rewards");
  if (claimGuard.data?.paused) rewardErr.push("Claims paused");
  if (claimGuard.data?.restricted) rewardErr.push("Campaign restricted");
  if (claimGuard.data?.hardFrozen) rewardErr.push("Campaign hard frozen");
  if (claimGuard.data?.complianceDenied) rewardErr.push("Compliance denied");

  const isDepositExactSharesReq = React.useCallback((r: QueueReq) => r.kind === 0 && r.maxIn > 0n, []);

  const onApprove = async () => {
    if (!asset || !queueSpender || !reqAllowance || reqAllowance <= 0n) return;
    await withTxLock(async () => {
      const hash = await sendTx({
        title: `Approve ${sym}`,
        address: asset,
        abi: erc20AllowanceAbi,
        functionName: "approve",
        args: [queueSpender, reqAllowance]
      } as any);
      await waitForTxFinality(hash);
    });
    await Promise.all([assetCtx.refetch(), qInfo.refetch()]);
  };

  const onDeposit = async () => {
    if (!queue || !deadline || !dep1 || dep1 <= 0n) return;
    await withTxLock(async () => {
      if (exactShares) {
        if (!dep2raw || dep2raw <= 0n) return;
        const hash = await sendTx({
          title: "Request deposit (exact shares)",
          address: queue,
          abi: settlementQueueAbi,
          functionName: "requestDepositExactShares",
          args: [dep1, dep2raw, deadline]
        } as any);
        await waitForTxFinality(hash);
      } else {
        const hash = await sendTx({
          title: "Request deposit (exact assets)",
          address: queue,
          abi: settlementQueueAbi,
          functionName: "requestDepositExactAssets",
          args: [dep1, dep2, deadline]
        } as any);
        await waitForTxFinality(hash);
      }
    });
    await Promise.all([myReqs.refetch(), assetCtx.refetch(), shareBal.refetch()]);
  };

  const onRedeem = async () => {
    if (!queue || !deadline || !red1 || red1 <= 0n) return;
    await withTxLock(async () => {
      const hash = await sendTx({
        title: "Request redeem",
        address: queue,
        abi: settlementQueueAbi,
        functionName: "requestRedeem",
        args: [red1, red2, deadline]
      } as any);
      await waitForTxFinality(hash);
    });
    await Promise.all([myReqs.refetch(), shareBal.refetch()]);
  };

  const onCancel = async (id: bigint) => {
    if (!queue) return;
    await withTxLock(async () => {
      const hash = await sendTx({
        title: `Cancel request #${id.toString()}`,
        address: queue,
        abi: settlementQueueAbi,
        functionName: "cancel",
        args: [id]
      } as any);
      await waitForTxFinality(hash);
    });
    await myReqs.refetch();
  };

  const onRetryPrefill = (r: QueueReq) => {
    if (r.kind === 1) {
      setRedShares(formatUnits(r.amount, shareDecimals));
      setRedMinOut(formatUnits(r.minOut, aDec));
      return;
    }
    if (isDepositExactSharesReq(r)) {
      setDepA(formatUnits(r.amount, shareDecimals));
      setDepB(formatUnits(r.maxIn > 0n ? r.maxIn : r.amount, aDec));
    } else {
      setDepA(formatUnits(r.amount, aDec));
      setDepB(formatUnits(r.minOut, shareDecimals));
    }
  };

  const onRetry = async (r: QueueReq) => {
    if (!queue || !deadline) return;

    onRetryPrefill(r);

    if (r.kind === 1) {
      await withTxLock(async () => {
        const hash = await sendTx({
          title: `Retry redeem #${r.id.toString()}`,
          address: queue,
          abi: settlementQueueAbi,
          functionName: "requestRedeem",
          args: [r.amount, r.minOut, deadline]
        } as any);
        await waitForTxFinality(hash);
      });
      await myReqs.refetch();
      return;
    }

    if (isDepositExactSharesReq(r)) {
      const maxIn = r.maxIn > 0n ? r.maxIn : r.amount;
      await withTxLock(async () => {
        const hash = await sendTx({
          title: `Retry deposit #${r.id.toString()}`,
          address: queue,
          abi: settlementQueueAbi,
          functionName: "requestDepositExactShares",
          args: [r.amount, maxIn, deadline]
        } as any);
        await waitForTxFinality(hash);
      });
    } else {
      await withTxLock(async () => {
        const hash = await sendTx({
          title: `Retry deposit #${r.id.toString()}`,
          address: queue,
          abi: settlementQueueAbi,
          functionName: "requestDepositExactAssets",
          args: [r.amount, r.minOut, deadline]
        } as any);
        await waitForTxFinality(hash);
      });
    }

    await Promise.all([myReqs.refetch(), shareBal.refetch(), assetCtx.refetch()]);
  };

  const onClaim = async () => {
    if (!distribution) return;
    await withTxLock(async () => {
      const hash = await sendTx({
        title: "Claim rewards",
        address: distribution,
        abi: distributionAbi,
        functionName: "claim",
        args: []
      } as any);
      await waitForTxFinality(hash);
    });
    await Promise.all([pending.refetch(), claimHistory.refetch()]);
  };

  const target = switchTargetChain();
  const targetName = target === base.id ? "Base" : "Base Sepolia";
  const needsApprove = Boolean(reqAllowance && reqAllowance > allowance);
  const canApprove = Boolean(needsApprove && canWrite && !switchingChain && !txPending && asset && queueSpender);
  const canDeposit = depErr.length === 0 && !txPending;
  const canRedeem = redErr.length === 0 && !txPending;
  const showInvestStickyBar = showInvest;

  if (!showInvest && !showRewards) return null;

  return (
    <div className={cn("grid gap-4", showInvest ? "pb-40 md:grid-cols-2 md:pb-0" : "grid-cols-1")}>
      {showInvest ? (
        <>
          <Card>
            <CardHeader>
              <CardTitle>Funding</CardTitle>
              <CardDescription>Approve + deposit request with queue mode detection.</CardDescription>
            </CardHeader>
            <CardContent className="space-y-3">
              <div className="flex flex-wrap items-center gap-2">
                <Badge tone="accent">Mode: {exactShares ? "Exact shares" : "Exact assets"}</Badge>
                <Badge tone="default">Queue: {qInfo.data?.count?.toString() ?? "0"} requests</Badge>
                <Badge tone={queueSpender ? "good" : qInfo.isLoading ? "default" : "warn"}>
                  {queueSpender ? "FundingManager linked" : qInfo.isLoading ? "FundingManager loading" : "FundingManager unresolved"}
                </Badge>
                {compliance.data === false ? <Badge tone="bad">Compliance denied</Badge> : <Badge tone="good">Compliance OK</Badge>}
              </div>
              <div className="rounded-xl border border-border bg-muted p-3 text-xs text-text2">
                <div>Step 1: approve {sym} for FundingManager (only if allowance is low).</div>
                <div>Step 2: submit one queue request with "Request deposit".</div>
                <div className="mt-1 font-mono text-text">
                  {exactShares
                    ? "requestDepositExactShares(sharesDesired, maxAssetsIn, deadline)"
                    : "requestDepositExactAssets(assetsIn, minSharesOut, deadline)"}
                </div>
              </div>
              {compliance.data === false ? (
                <div className="flex flex-wrap items-center gap-2">
                  <a href={complianceHref} className="rounded-xl border border-border bg-card px-3 py-2 text-sm hover:shadow-soft">
                    Why blocked
                  </a>
                  <a href={onboardingHref} className="rounded-xl border border-border bg-card px-3 py-2 text-sm hover:shadow-soft">
                    Start onboarding
                  </a>
                </div>
              ) : null}
              <div className="grid gap-2 md:grid-cols-2">
                <div className="space-y-1">
                  <div className="text-xs text-text2">{exactShares ? "Shares desired" : `${sym} to deposit`}</div>
                  <Input value={depA} onChange={(e) => setDepA(e.target.value)} placeholder={exactShares ? "Shares desired" : `${sym} in`} />
                </div>
                <div className="space-y-1">
                  <div className="text-xs text-text2">{exactShares ? `Max ${sym} in` : "Min shares out"}</div>
                  <Input value={depB} onChange={(e) => setDepB(e.target.value)} placeholder={exactShares ? `Max ${sym} in` : "Min shares out"} />
                </div>
              </div>
              <div className="space-y-1">
                <div className="text-xs text-text2">Deadline (minutes from now)</div>
                <Input value={deadlineMin} onChange={(e) => setDeadlineMin(e.target.value)} placeholder="60" />
              </div>
              <div className="rounded-xl border border-border bg-muted p-3 text-xs text-text2">
                <div>{sym} balance: <span className="font-mono text-text">{fmt(aBal, aDec)} {sym}</span></div>
                <div>Allowance to FundingManager: <span className="font-mono text-text">{fmt(allowance, aDec)} {sym}</span></div>
              </div>
              {depErr.length > 0 ? (
                <div className="flex flex-wrap gap-2">{depErr.map((e) => <Badge key={e} tone="warn">{e}</Badge>)}</div>
              ) : null}
              <div className="flex flex-wrap items-center gap-2">
                {reqAllowance && reqAllowance > allowance ? (
                  <Button onClick={onApprove} disabled={!canApprove}>Approve {sym}</Button>
                ) : (
                  <Badge tone="good">Allowance OK</Badge>
                )}
                <Button variant="accent" onClick={onDeposit} disabled={!canDeposit}>Request deposit</Button>
                <a href={adminSettlementHref} className="rounded-xl border border-border bg-card px-3 py-2 text-sm hover:shadow-soft">
                  Open Admin Settlement
                </a>
                {wrongNet && switchChain ? (
                  <Button variant="secondary" onClick={() => switchChain({ chainId: target })} disabled={switchingChain}>
                    Switch to {targetName}
                  </Button>
                ) : null}
              </div>
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle>Redeem</CardTitle>
              <CardDescription>Request redeem with share/deadline checks.</CardDescription>
            </CardHeader>
            <CardContent className="space-y-3">
              <div className="grid gap-2 md:grid-cols-2">
                <Input value={redShares} onChange={(e) => setRedShares(e.target.value)} placeholder="Shares" />
                <Input value={redMinOut} onChange={(e) => setRedMinOut(e.target.value)} placeholder={`Min ${sym} out`} />
              </div>
              <div className="rounded-xl border border-border bg-muted p-3 text-xs text-text2">
                Share balance: <span className="font-mono text-text">{fmt(sBal, shareDecimals)} shares</span>
              </div>
              {redErr.length > 0 ? (
                <div className="flex flex-wrap gap-2">{redErr.map((e) => <Badge key={e} tone="warn">{e}</Badge>)}</div>
              ) : null}
              {compliance.data === false ? (
                <div className="flex flex-wrap items-center gap-2">
                  <a href={complianceHref} className="rounded-xl border border-border bg-card px-3 py-2 text-sm hover:shadow-soft">
                    Why blocked
                  </a>
                  <a href={onboardingHref} className="rounded-xl border border-border bg-card px-3 py-2 text-sm hover:shadow-soft">
                    Start onboarding
                  </a>
                </div>
              ) : null}
              <Button onClick={onRedeem} disabled={!canRedeem}>Request redeem</Button>
            </CardContent>
          </Card>

          <Card className="md:col-span-2">
            <CardHeader>
              <CardTitle>My Requests</CardTitle>
              <CardDescription>Status, expiries and actions (cancel/retry).</CardDescription>
            </CardHeader>
            <CardContent>
              {!isConnected ? (
                <EmptyState title="Connect wallet" description="Your requests appear here once connected." />
              ) : myReqs.isLoading ? (
                <div className="text-sm text-text2">Loading requests...</div>
              ) : (myReqs.data?.length ?? 0) === 0 ? (
                <EmptyState title="No requests yet" description="Create a deposit/redeem request to populate this list." />
              ) : (
                <div className="grid gap-3">
                  {(myReqs.data ?? []).map((r) => {
                    const st = statusView(r, now);
                    const depExactSharesReq = isDepositExactSharesReq(r);
                    const canCancel = canWrite && !txPending && r.status === 1;
                    const canRetry = canWrite && !txPending && (r.status === 2 || st.expired || st.failed);
                    const amountLabel = r.kind === 0
                      ? `${fmt(r.amount, depExactSharesReq ? shareDecimals : aDec)} ${depExactSharesReq ? "shares" : sym}`
                      : `${fmt(r.amount, shareDecimals)} shares`;
                    const limitsLabel = r.kind === 0
                      ? (depExactSharesReq
                        ? `Max in ${fmt(r.maxIn > 0n ? r.maxIn : r.amount, aDec)} ${sym}`
                        : `Min out ${fmt(r.minOut, shareDecimals)} shares`)
                      : `Min out ${fmt(r.minOut, aDec)} ${sym}`;
                    const processedOutLabel = r.kind === 0
                      ? `${fmt(r.outAmount ?? 0n, shareDecimals)} shares`
                      : `${fmt(r.outAmount ?? 0n, aDec)} ${sym}`;
                    return (
                      <div key={r.id.toString()} className="rounded-xl border border-border/80 bg-card p-3">
                        <div className="flex items-start justify-between gap-2">
                          <div>
                            <div className="font-medium">Request #{r.id.toString()} - {K[r.kind] ?? `KIND ${r.kind}`}</div>
                            <div className="mt-1 text-xs text-text2">Deadline: {new Date(r.deadline * 1000).toLocaleString()}</div>
                          </div>
                          <div className="flex flex-wrap items-center justify-end gap-1">
                            <Badge tone={st.tone}>{st.label}</Badge>
                            {st.label === "PROCESSED" && typeof r.outAmount === "bigint" && r.outAmount === 0n ? (
                              <Badge tone="bad">ZERO_OUT</Badge>
                            ) : null}
                            {st.failed ? <Badge tone="bad">RETRYABLE_FAIL</Badge> : null}
                            {st.expired ? <Badge tone="bad">DEADLINE_PASSED</Badge> : null}
                          </div>
                        </div>
                        {st.failed ? (
                          <div className="mt-2 text-xs text-bad">
                            Failed while processing: {decodeFailData(r.lastFailData)}
                          </div>
                        ) : null}
                        {st.expired ? (
                          <div className="mt-2 text-xs text-bad">Caducado: este request no se puede procesar; usa Retry para crear uno nuevo con otro deadline.</div>
                        ) : null}
                        <div className="mt-2 text-xs text-text2">
                          Amount: {amountLabel}
                        </div>
                        <div className="mt-1 text-xs text-text2">
                          {limitsLabel}
                        </div>
                        {typeof r.outAmount === "bigint" ? (
                          <div className="mt-1 text-xs text-good">Processed out: {processedOutLabel}</div>
                        ) : null}
                        {st.label === "PROCESSED" && r.failCount > 0 ? (
                          <div className="mt-2 text-xs text-text2">Previous failed attempts: {r.failCount}</div>
                        ) : null}
                        <div className="mt-3 flex flex-wrap items-center gap-2">
                          {canCancel ? <Button size="sm" variant="secondary" onClick={() => onCancel(r.id)}>Cancel</Button> : null}
                          {canRetry ? <Button size="sm" variant="accent" onClick={() => onRetry(r)}>Retry</Button> : null}
                        </div>
                      </div>
                    );
                  })}
                </div>
              )}
            </CardContent>
          </Card>
        </>
      ) : null}

      {showRewards ? (
        <Card className={showInvest ? "md:col-span-2" : undefined}>
          <CardHeader>
            <CardTitle>Rewards</CardTitle>
            <CardDescription>Pending rewards, gated claim and on-chain claim history.</CardDescription>
          </CardHeader>
          <CardContent className="space-y-3">
            <div className="grid gap-2 md:grid-cols-3">
              <div className="rounded-xl border border-border bg-muted p-3 text-sm">
                <div className="text-text2">Pending</div>
                <div className="mt-1 font-mono">
                  {pending.isLoading ? "..." : `${fmt(rewardPending, rewardDec)} ${rewardSym}`}
                </div>
              </div>
              <div className="rounded-xl border border-border bg-muted p-3 text-sm">
                <div className="text-text2">Reward token</div>
                <div className="mt-1 font-mono">
                  {rewardMeta.isLoading
                    ? "..."
                    : rewardMeta.data?.rewardToken
                      ? rewardMeta.data.rewardToken
                      : "Unresolved"}
                </div>
              </div>
              <div className="rounded-xl border border-border bg-muted p-3 text-sm">
                <div className="text-text2">My claims</div>
                <div className="mt-1 font-mono">
                  {claimHistory.isLoading ? "..." : (claimHistory.data?.length ?? 0).toString()}
                </div>
              </div>
            </div>

            <div className="flex flex-wrap items-center gap-2">
              <Badge tone={rewardPending > 0n ? "good" : "default"}>{rewardPending > 0n ? "Pending > 0" : "Pending 0"}</Badge>
              <Badge tone={claimGuard.data?.paused ? "bad" : "good"}>
                {claimGuard.data?.paused ? "Claims paused" : "Claims unpaused"}
              </Badge>
              <Badge tone={claimGuard.data?.restricted ? "bad" : "good"}>
                {claimGuard.data?.restricted ? "Restricted" : "Not restricted"}
              </Badge>
              <Badge tone={claimGuard.data?.hardFrozen ? "bad" : "good"}>
                {claimGuard.data?.hardFrozen ? "Hard frozen" : "Not hard-frozen"}
              </Badge>
              {rewardMeta.data?.enforceComplianceOnClaim ? (
                <Badge tone={claimGuard.data?.complianceDenied ? "bad" : "good"}>
                  {claimGuard.data?.complianceDenied ? "Compliance denied" : "Compliance OK"}
                </Badge>
              ) : (
                <Badge tone="default">Compliance check off</Badge>
              )}
            </div>

            {rewardErr.length > 0 ? (
              <div className="flex flex-wrap gap-2">
                {rewardErr.map((e) => (
                  <Badge key={e} tone={e.includes("paused") || e.includes("restricted") || e.includes("frozen") || e.includes("denied") ? "bad" : "warn"}>
                    {e}
                  </Badge>
                ))}
              </div>
            ) : null}
            {claimGuard.data?.complianceDenied ? (
              <div className="flex flex-wrap items-center gap-2">
                <a href={complianceHref} className="rounded-xl border border-border bg-card px-3 py-2 text-sm hover:shadow-soft">
                  Why blocked
                </a>
                <a href={onboardingHref} className="rounded-xl border border-border bg-card px-3 py-2 text-sm hover:shadow-soft">
                  Start onboarding
                </a>
              </div>
            ) : null}

            <div className="flex flex-wrap items-center gap-2">
              <Button onClick={onClaim} disabled={modules.isLoading || rewardMeta.isLoading || claimGuard.isLoading || rewardErr.length > 0}>
                Claim
              </Button>
              <Button
                variant="secondary"
                onClick={() => {
                  void pending.refetch();
                  void claimHistory.refetch();
                  void claimGuard.refetch();
                }}
              >
                Refresh
              </Button>
            </div>

            <div className="rounded-xl border border-border/80 bg-card p-3">
              <div className="mb-2 text-sm font-medium">Claim history</div>
              {!isConnected ? (
                <div className="text-sm text-text2">Connect wallet to load your claim history.</div>
              ) : claimHistory.isLoading ? (
                <div className="text-sm text-text2">Loading claim history...</div>
              ) : (claimHistory.data?.length ?? 0) === 0 ? (
                <div className="text-sm text-text2">No claims yet for this wallet.</div>
              ) : (
                <div className="grid gap-2">
                  {(claimHistory.data ?? []).map((row) => (
                    <div key={row.id} className="rounded-lg border border-border/70 bg-muted p-3 text-xs">
                      <div className="flex flex-wrap items-center justify-between gap-2">
                        <div className="font-mono text-text">{fmt(row.amount, rewardDec)} {rewardSym}</div>
                        <div className="text-text2">{fmtTs(row.timestamp)}</div>
                      </div>
                      <div className="mt-2 flex flex-wrap items-center gap-2">
                        <Badge tone="default">Block {row.blockNumber.toString()}</Badge>
                        {row.txHash ? (
                          <>
                            <button
                              type="button"
                              className="rounded-md border border-border px-2 py-1 hover:bg-card"
                              onClick={() => navigator.clipboard.writeText(row.txHash!)}
                            >
                              Copy tx
                            </button>
                            <a
                              className="rounded-md border border-border px-2 py-1 hover:bg-card"
                              href={explorerTxUrl(chainId, row.txHash)}
                              target="_blank"
                              rel="noreferrer"
                            >
                              Explorer
                            </a>
                          </>
                        ) : null}
                      </div>
                    </div>
                  ))}
                </div>
              )}
            </div>
          </CardContent>
        </Card>
      ) : null}

      {showInvestStickyBar ? (
        <MobileStickyBar testId="invest-sticky-actions" ariaLabel="Invest sticky actions">
          <div className="grid grid-cols-2 gap-2">
            {needsApprove ? (
              <Button
                size="sm"
                onClick={onApprove}
                disabled={!canApprove}
                data-testid="invest-sticky-approve"
              >
                Approve {sym}
              </Button>
            ) : (
              <Button size="sm" variant="secondary" disabled>
                Allowance OK
              </Button>
            )}
            <Button
              size="sm"
              variant="accent"
              onClick={onDeposit}
              disabled={!canDeposit}
              data-testid="invest-sticky-deposit"
            >
              Request deposit
            </Button>
            <Button
              size="sm"
              variant="secondary"
              onClick={onRedeem}
              disabled={!canRedeem}
              data-testid="invest-sticky-redeem"
            >
              Request redeem
            </Button>
            {wrongNet && switchChain ? (
              <Button
                size="sm"
                variant="secondary"
                onClick={() => switchChain({ chainId: target })}
                disabled={switchingChain}
              >
                Switch {targetName}
              </Button>
            ) : (
              <Button
                size="sm"
                variant="secondary"
                onClick={() => {
                  void myReqs.refetch();
                  void assetCtx.refetch();
                  void pending.refetch();
                }}
              >
                Refresh
              </Button>
            )}
          </div>
        </MobileStickyBar>
      ) : null}
    </div>
  );
}

