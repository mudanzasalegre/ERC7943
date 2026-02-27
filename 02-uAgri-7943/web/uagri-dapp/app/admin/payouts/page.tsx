"use client";

import * as React from "react";
import { useQuery } from "@tanstack/react-query";
import { formatUnits, isAddress, keccak256, parseUnits, toHex, zeroAddress } from "viem";
import { useAccount, useChainId, usePublicClient } from "wagmi";
import { useTx } from "@/hooks/useTx";
import { PageHeader } from "@/components/ui/PageHeader";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { Textarea } from "@/components/ui/Textarea";
import { Button } from "@/components/ui/Button";
import { Badge } from "@/components/ui/Badge";
import { EmptyState } from "@/components/ui/EmptyState";
import { complianceAbi, distributionAbi, erc20AllowanceAbi, erc20DecimalsAbi, roleManagerAbi, shareTokenAbi, yieldAccumulatorAbi } from "@/lib/abi";
import { explorerTxUrl } from "@/lib/explorer";
import { shortAddr, shortHex32 } from "@/lib/format";
import { roles } from "@/lib/roles";

const B32_ZERO = ("0x" + "00".repeat(32)) as `0x${string}`;
const B32_RE = /^0x[0-9a-fA-F]{64}$/u;
const BYTES_RE = /^0x(?:[0-9a-fA-F]{2})+$/u;
const UINT64_MAX = 2n ** 64n - 1n;

const DEFAULT_ADMIN_ROLE = ("0x" + "00".repeat(32)) as `0x${string}`;
const PAYOUT_OPERATOR_ROLE = keccak256(toHex("PAYOUT_OPERATOR_ROLE")) as `0x${string}`;
const GOVERNANCE_ROLE =
  roles.find((r) => r.key === "GOVERNANCE_ROLE")?.role ??
  (keccak256(toHex("GOVERNANCE_ROLE")) as `0x${string}`);

type RowStatus = "not-found" | "requested" | "confirmed" | "used-no-record";
type AuditAction = "claim" | "confirm";
type RecRow = {
  ref: `0x${string}`;
  account: `0x${string}`;
  to: `0x${string}`;
  amount: bigint;
  railHash: `0x${string}`;
  receiptHash: `0x${string}`;
  status: RowStatus;
  txHash?: `0x${string}`;
  action?: AuditAction;
  updatedAt: number;
};

function canAddr(v: string): v is `0x${string}` {
  return isAddress(v);
}
function isBytes32(v: string): v is `0x${string}` {
  return B32_RE.test(v.trim());
}
function isHexBytes(v: string): v is `0x${string}` {
  return BYTES_RE.test(v.trim());
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
function fmt(v: bigint, decimals: number, p = 4): string {
  const s = formatUnits(v, decimals);
  const [i, d] = s.split(".");
  return d ? `${i}.${d.slice(0, p)}` : i;
}
function statusTone(s: RowStatus): "default" | "good" | "warn" | "bad" | "accent" {
  if (s === "confirmed") return "good";
  if (s === "requested") return "warn";
  if (s === "used-no-record") return "bad";
  return "default";
}
function statusFrom(account: `0x${string}`, receiptHash: `0x${string}`, usedRef: boolean): RowStatus {
  if (account !== zeroAddress) return receiptHash === B32_ZERO ? "requested" : "confirmed";
  return usedRef ? "used-no-record" : "not-found";
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

export default function AdminPayoutsPage() {
  const chainId = useChainId();
  const client = usePublicClient();
  const { address, isConnected } = useAccount();
  const { sendTx } = useTx();

  const [distributionAddr, setDistributionAddr] = React.useState("");
  const [claimAccount, setClaimAccount] = React.useState("");
  const [claimTo, setClaimTo] = React.useState("");
  const [claimAmount, setClaimAmount] = React.useState("0");
  const [claimDeadline, setClaimDeadline] = React.useState(() => String(Math.floor(Date.now() / 1000) + 3600));
  const [claimRef, setClaimRef] = React.useState<string>(B32_ZERO);
  const [claimRailHash, setClaimRailHash] = React.useState<string>(B32_ZERO);
  const [claimSig, setClaimSig] = React.useState("");

  const [confirmRef, setConfirmRef] = React.useState<string>(B32_ZERO);
  const [receiptHash, setReceiptHash] = React.useState<string>(B32_ZERO);
  const [receiptText, setReceiptText] = React.useState("");

  const [lookupRef, setLookupRef] = React.useState("");
  const [payloadJson, setPayloadJson] = React.useState("");
  const [payloadErr, setPayloadErr] = React.useState("");
  const [rows, setRows] = React.useState<RecRow[]>([]);

  const distribution = canAddr(distributionAddr) ? distributionAddr : undefined;
  const claimAccountAddr = canAddr(claimAccount) ? claimAccount : undefined;
  const claimToAddr = canAddr(claimTo) ? claimTo : undefined;
  const claimRefB32 = isBytes32(claimRef) ? (claimRef.trim() as `0x${string}`) : undefined;
  const claimRailB32 = isBytes32(claimRailHash) ? (claimRailHash.trim() as `0x${string}`) : undefined;
  const claimSigHex = isHexBytes(claimSig) ? (claimSig.trim() as `0x${string}`) : undefined;
  const claimDeadlineU64 = parseUint64(claimDeadline);

  const confirmRefB32 = isBytes32(confirmRef) ? (confirmRef.trim() as `0x${string}`) : undefined;
  const receiptHashB32 = isBytes32(receiptHash) ? (receiptHash.trim() as `0x${string}`) : undefined;
  const lookupRefB32 = isBytes32(lookupRef) ? (lookupRef.trim() as `0x${string}`) : undefined;
  const builtReceiptHash = receiptText.trim() ? keccak256(toHex(receiptText.trim())) : "";

  React.useEffect(() => {
    if (typeof window === "undefined") return;
    const search = new URLSearchParams(window.location.search);
    const mode = search.get("mode") ?? "";
    const qAddr = search.get("addr") ?? "";
    const qAccount = search.get("account") ?? "";
    const qTo = search.get("to") ?? "";
    const qAmount = search.get("maxAmount") ?? "";
    const qDeadline = search.get("deadline") ?? "";
    const qRef = search.get("ref") ?? "";
    const qRailHash = search.get("payoutRailHash") ?? "";
    const qSignature = search.get("signature") ?? "";
    const qReceiptHash = search.get("receiptHash") ?? "";

    if (qAddr && canAddr(qAddr)) setDistributionAddr(qAddr);
    if (qAccount && canAddr(qAccount)) setClaimAccount(qAccount);
    if (qTo && canAddr(qTo)) setClaimTo(qTo);
    if (qAmount) setClaimAmount(qAmount);
    if (qDeadline && parseUint64(qDeadline) !== undefined) setClaimDeadline(qDeadline);
    if (qRef && isBytes32(qRef)) {
      setClaimRef(qRef);
      setConfirmRef(qRef);
      setLookupRef(qRef);
    }
    if (qRailHash && isBytes32(qRailHash)) setClaimRailHash(qRailHash);
    if (qSignature && isHexBytes(qSignature)) setClaimSig(qSignature);
    if (qReceiptHash && isBytes32(qReceiptHash)) setReceiptHash(qReceiptHash);

    if (mode === "confirm" && qRef && isBytes32(qRef)) {
      setConfirmRef(qRef);
      setLookupRef(qRef);
    }
  }, []);

  React.useEffect(() => {
    if (!address) return;
    if (!claimAccount) setClaimAccount(address);
    if (!claimTo) setClaimTo(address);
  }, [address, claimAccount, claimTo]);

  const storageKey = React.useMemo(() => `uagri:payouts:reconcile:v1:${chainId}:${distribution ?? "none"}`, [chainId, distribution]);
  React.useEffect(() => {
    if (typeof window === "undefined") return;
    try {
      const raw = window.localStorage.getItem(storageKey);
      if (!raw) return setRows([]);
      const parsed = JSON.parse(raw) as any[];
      const hydrated = (Array.isArray(parsed) ? parsed : [])
        .filter((x) => typeof x === "object" && x)
        .map((x) => ({
          ref: isBytes32(String(x.ref ?? "")) ? (String(x.ref) as `0x${string}`) : (B32_ZERO as `0x${string}`),
          account: canAddr(String(x.account ?? "")) ? (String(x.account) as `0x${string}`) : zeroAddress,
          to: canAddr(String(x.to ?? "")) ? (String(x.to) as `0x${string}`) : zeroAddress,
          amount: BigInt(String(x.amount ?? "0")),
          railHash: isBytes32(String(x.railHash ?? "")) ? (String(x.railHash) as `0x${string}`) : B32_ZERO,
          receiptHash: isBytes32(String(x.receiptHash ?? "")) ? (String(x.receiptHash) as `0x${string}`) : B32_ZERO,
          status: (x.status as RowStatus) ?? "not-found",
          txHash: isHexBytes(String(x.txHash ?? "")) ? (String(x.txHash) as `0x${string}`) : undefined,
          action: x.action === "claim" || x.action === "confirm" ? (x.action as AuditAction) : undefined,
          updatedAt: Number(x.updatedAt || Date.now())
        }))
        .filter((x) => x.ref !== B32_ZERO);
      setRows(hydrated);
    } catch {
      setRows([]);
    }
  }, [storageKey]);
  React.useEffect(() => {
    if (typeof window === "undefined") return;
    const serializable = rows.slice(0, 150).map((x) => ({ ...x, amount: x.amount.toString() }));
    window.localStorage.setItem(storageKey, JSON.stringify(serializable));
  }, [rows, storageKey]);

  const meta = useQuery({
    queryKey: ["adminPayoutsMeta", distribution],
    enabled: !!client && !!distribution,
    queryFn: async () => {
      if (!client || !distribution) {
        return { campaignId: undefined, roleManager: undefined, rewardToken: undefined, shareToken: undefined, enforceComplianceOnClaim: false };
      }
      const [campaignId, roleManager, rewardToken, shareToken, enforceComplianceOnClaim] = await Promise.all([
        client.readContract({ address: distribution, abi: yieldAccumulatorAbi, functionName: "campaignId" }).catch(() => undefined),
        client.readContract({ address: distribution, abi: yieldAccumulatorAbi, functionName: "roleManager" }).catch(() => undefined),
        client.readContract({ address: distribution, abi: yieldAccumulatorAbi, functionName: "rewardToken" }).catch(() => undefined),
        client.readContract({ address: distribution, abi: yieldAccumulatorAbi, functionName: "shareToken" }).catch(() => undefined),
        client.readContract({ address: distribution, abi: yieldAccumulatorAbi, functionName: "enforceComplianceOnClaim" }).catch(() => false)
      ]);
      return {
        campaignId: campaignId as `0x${string}` | undefined,
        roleManager: roleManager as `0x${string}` | undefined,
        rewardToken: rewardToken as `0x${string}` | undefined,
        shareToken: shareToken as `0x${string}` | undefined,
        enforceComplianceOnClaim: Boolean(enforceComplianceOnClaim)
      };
    }
  });

  const complianceModule = useQuery({
    queryKey: ["adminPayoutsComplianceModule", meta.data?.shareToken],
    enabled: !!client && !!meta.data?.shareToken,
    queryFn: async () => {
      if (!client || !meta.data?.shareToken) return undefined;
      return client.readContract({
        address: meta.data.shareToken,
        abi: shareTokenAbi,
        functionName: "complianceModule"
      }).catch(() => undefined) as Promise<`0x${string}` | undefined>;
    }
  });

  const compliancePrecheck = useQuery({
    queryKey: ["adminPayoutsCompliancePrecheck", complianceModule.data ?? "none", claimAccountAddr ?? "none"],
    enabled: !!client && !!complianceModule.data && !!claimAccountAddr && !!meta.data?.enforceComplianceOnClaim,
    queryFn: async () => {
      if (!client || !complianceModule.data || !claimAccountAddr) return true;
      return Boolean(
        await client.readContract({
          address: complianceModule.data,
          abi: complianceAbi,
          functionName: "canTransact",
          args: [claimAccountAddr]
        }).catch(() => false)
      );
    }
  });

  const rewardMeta = useQuery({
    queryKey: ["adminPayoutsRewardMeta", meta.data?.rewardToken],
    enabled: !!client && !!meta.data?.rewardToken,
    queryFn: async () => {
      if (!client || !meta.data?.rewardToken) return { symbol: "RWD", decimals: 18 };
      const token = meta.data.rewardToken;
      const [symbol, decimals] = await Promise.all([
        client.readContract({ address: token, abi: erc20AllowanceAbi, functionName: "symbol" }).catch(() => "RWD"),
        client.readContract({ address: token, abi: erc20DecimalsAbi, functionName: "decimals" }).catch(() => 18)
      ]);
      return { symbol: String(symbol || "RWD"), decimals: Number(decimals ?? 18) };
    }
  });

  const rewardSymbol = rewardMeta.data?.symbol ?? "RWD";
  const rewardDecimals = rewardMeta.data?.decimals ?? 18;
  const claimAmountParsed = parseAmount(claimAmount, rewardDecimals);

  const pending = useQuery({
    queryKey: ["adminPayoutsPending", distribution, claimAccountAddr ?? "none"],
    enabled: !!client && !!distribution && !!claimAccountAddr,
    queryFn: async () => {
      if (!client || !distribution || !claimAccountAddr) return 0n;
      return client.readContract({
        address: distribution,
        abi: distributionAbi,
        functionName: "pending",
        args: [claimAccountAddr]
      }) as Promise<bigint>;
    }
  });

  const roleCheck = useQuery({
    queryKey: ["adminPayoutsRoles", meta.data?.roleManager, address],
    enabled: !!client && !!meta.data?.roleManager && !!address,
    queryFn: async () => {
      if (!client || !meta.data?.roleManager || !address) return { canClaim: false, canConfirm: false, byRole: [] as { label: string; ok: boolean }[] };
      const roleManager = meta.data.roleManager;
      const defs = [
        { label: "Payout operator", role: PAYOUT_OPERATOR_ROLE },
        { label: "Governance", role: GOVERNANCE_ROLE },
        { label: "Default admin", role: DEFAULT_ADMIN_ROLE }
      ];
      const byRole = await Promise.all(
        defs.map(async (d) => {
          const ok = Boolean(
            await client.readContract({ address: roleManager, abi: roleManagerAbi, functionName: "hasRole", args: [d.role, address] }).catch(() => false)
          );
          return { label: d.label, ok, role: d.role };
        })
      );
      return { canClaim: byRole.some((x) => x.role === PAYOUT_OPERATOR_ROLE && x.ok), canConfirm: byRole.some((x) => x.ok), byRole };
    }
  });

  const readRow = React.useCallback(
    async (ref: `0x${string}`): Promise<RecRow> => {
      if (!client || !distribution) {
        return { ref, account: zeroAddress, to: zeroAddress, amount: 0n, railHash: B32_ZERO, receiptHash: B32_ZERO, status: "not-found", updatedAt: Date.now() };
      }
      const [info, usedRef] = await Promise.all([
        client.readContract({ address: distribution, abi: yieldAccumulatorAbi, functionName: "payoutByRef", args: [ref] }).catch(() => undefined),
        client.readContract({ address: distribution, abi: yieldAccumulatorAbi, functionName: "usedPayoutRef", args: [ref] }).catch(() => false)
      ]);
      const account = ((info as any)?.account ?? (info as any)?.[0] ?? zeroAddress) as `0x${string}`;
      const to = ((info as any)?.to ?? (info as any)?.[1] ?? zeroAddress) as `0x${string}`;
      const amount = BigInt((info as any)?.amount ?? (info as any)?.[2] ?? 0);
      const railHash = ((info as any)?.payoutRailHash ?? (info as any)?.[3] ?? B32_ZERO) as `0x${string}`;
      const gotReceipt = ((info as any)?.receiptHash ?? (info as any)?.[4] ?? B32_ZERO) as `0x${string}`;
      return {
        ref,
        account,
        to,
        amount,
        railHash,
        receiptHash: gotReceipt,
        status: statusFrom(account, gotReceipt, Boolean(usedRef)),
        updatedAt: Date.now()
      };
    },
    [client, distribution]
  );

  const claimRefInfo = useQuery({
    queryKey: ["adminPayoutClaimRef", distribution, claimRefB32 ?? "none"],
    enabled: !!claimRefB32 && !!distribution && !!client,
    queryFn: async () => readRow(claimRefB32!)
  });
  const confirmRefInfo = useQuery({
    queryKey: ["adminPayoutConfirmRef", distribution, confirmRefB32 ?? "none"],
    enabled: !!confirmRefB32 && !!distribution && !!client,
    queryFn: async () => readRow(confirmRefB32!)
  });
  const lookupInfo = useQuery({
    queryKey: ["adminPayoutLookupRef", distribution, lookupRefB32 ?? "none"],
    enabled: !!lookupRefB32 && !!distribution && !!client,
    queryFn: async () => readRow(lookupRefB32!)
  });

  const now = BigInt(Math.floor(Date.now() / 1000));
  const claimErrors: string[] = [];
  if (!distribution) claimErrors.push("Distribution required");
  if (!claimAccountAddr) claimErrors.push("account invalid");
  if (!claimToAddr) claimErrors.push("to invalid");
  if (!claimAmountParsed || claimAmountParsed <= 0n) claimErrors.push("maxAmount must be > 0");
  if (!claimDeadlineU64) claimErrors.push("deadline must be uint64");
  if (claimDeadlineU64 && claimDeadlineU64 !== 0n && claimDeadlineU64 < now) claimErrors.push("deadline expired");
  if (!claimRefB32 || claimRefB32.toLowerCase() === B32_ZERO) claimErrors.push("ref invalid/zero");
  if (!claimRailB32 || claimRailB32.toLowerCase() === B32_ZERO) claimErrors.push("payoutRailHash invalid/zero");
  if (!claimSigHex) claimErrors.push("signature must be hex bytes");
  if (claimRefInfo.data?.status !== "not-found") claimErrors.push("ref already used");
  if (!isConnected) claimErrors.push("connect wallet");
  if (isConnected && roleCheck.data && !roleCheck.data.canClaim) claimErrors.push("wallet lacks PAYOUT_OPERATOR_ROLE");
  if (meta.data?.enforceComplianceOnClaim && compliancePrecheck.data === false) claimErrors.push("account blocked by compliance");

  const confirmErrors: string[] = [];
  if (!distribution) confirmErrors.push("Distribution required");
  if (!confirmRefB32 || confirmRefB32.toLowerCase() === B32_ZERO) confirmErrors.push("ref invalid/zero");
  if (!receiptHashB32 || receiptHashB32.toLowerCase() === B32_ZERO) confirmErrors.push("receiptHash invalid/zero");
  if (confirmRefInfo.data?.status === "not-found") confirmErrors.push("ref not found");
  if (confirmRefInfo.data?.status === "confirmed") confirmErrors.push("ref already confirmed");
  if (!isConnected) confirmErrors.push("connect wallet");
  if (isConnected && roleCheck.data && !roleCheck.data.canConfirm) confirmErrors.push("wallet lacks confirmer role");
  const complianceBlocked = Boolean(meta.data?.enforceComplianceOnClaim && compliancePrecheck.data === false);
  const complianceHref = queryHref("/compliance", {
    token: meta.data?.shareToken,
    compliance: complianceModule.data,
    from: claimAccountAddr,
    to: claimToAddr ?? claimAccountAddr,
    amount: claimAmount || "1"
  });
  const onboardingHref = queryHref("/onboarding", {
    token: meta.data?.shareToken,
    compliance: complianceModule.data,
    account: claimAccountAddr
  });

  const upsertRow = React.useCallback((row: RecRow) => {
    setRows((prev) => [row, ...prev.filter((x) => x.ref.toLowerCase() !== row.ref.toLowerCase())].slice(0, 150));
  }, []);

  const onLoadPayload = () => {
    setPayloadErr("");
    try {
      const p = JSON.parse(payloadJson) as any;
      if (typeof p !== "object" || !p) {
        setPayloadErr("Payload must be JSON object");
        return;
      }
      if (typeof p.distribution === "string" && canAddr(p.distribution)) setDistributionAddr(p.distribution);
      if (typeof p.account === "string" && canAddr(p.account)) setClaimAccount(p.account);
      if (typeof p.to === "string" && canAddr(p.to)) setClaimTo(p.to);
      if (typeof p.maxAmountInput === "string" && p.maxAmountInput.trim()) {
        setClaimAmount(p.maxAmountInput.trim());
      } else if (typeof p.maxAmountWei === "string" && /^\d+$/u.test(p.maxAmountWei.trim())) {
        setClaimAmount(formatUnits(BigInt(p.maxAmountWei.trim()), rewardDecimals));
      }
      if (typeof p.deadline === "string" && /^\d+$/u.test(p.deadline.trim())) setClaimDeadline(p.deadline.trim());
      if (typeof p.ref === "string" && isBytes32(p.ref)) {
        setClaimRef(p.ref);
        setConfirmRef(p.ref);
        setLookupRef(p.ref);
      }
      if (typeof p.payoutRailHash === "string" && isBytes32(p.payoutRailHash)) setClaimRailHash(p.payoutRailHash);
      if (typeof p.signature === "string" && isHexBytes(p.signature)) setClaimSig(p.signature);
    } catch (error: any) {
      setPayloadErr(error?.message || "Invalid payload JSON");
    }
  };

  const onClaim = async () => {
    if (!distribution || !claimAccountAddr || !claimToAddr || !claimAmountParsed || !claimDeadlineU64 || !claimRefB32 || !claimRailB32 || !claimSigHex) {
      return;
    }
    const txHash = await sendTx({
      title: "Payout claimToWithSig",
      address: distribution,
      abi: yieldAccumulatorAbi,
      functionName: "claimToWithSig",
      args: [claimAccountAddr, claimToAddr, claimAmountParsed, claimDeadlineU64, claimRefB32, claimRailB32, claimSigHex]
    } as any);
    const row = await readRow(claimRefB32);
    upsertRow({ ...row, txHash, action: "claim", updatedAt: Date.now() });
    setLookupRef(claimRefB32);
    void Promise.all([claimRefInfo.refetch(), confirmRefInfo.refetch(), lookupInfo.refetch()]);
  };

  const onConfirm = async () => {
    if (!distribution || !confirmRefB32 || !receiptHashB32) return;
    const txHash = await sendTx({
      title: "Payout confirmPayout",
      address: distribution,
      abi: yieldAccumulatorAbi,
      functionName: "confirmPayout",
      args: [confirmRefB32, receiptHashB32]
    } as any);
    const row = await readRow(confirmRefB32);
    upsertRow({ ...row, txHash, action: "confirm", updatedAt: Date.now() });
    setLookupRef(confirmRefB32);
    void Promise.all([confirmRefInfo.refetch(), lookupInfo.refetch()]);
  };

  const onTrackLookup = async () => {
    if (!lookupRefB32) return;
    const row = await readRow(lookupRefB32);
    upsertRow(row);
  };

  React.useEffect(() => {
    if (!client || !distribution || rows.length === 0) return;
    const t = setInterval(() => {
      const refs = rows.map((x) => x.ref);
      void Promise.all(refs.map((ref) => readRow(ref))).then((fresh) => {
        setRows((prev) => {
          const map = new Map(prev.map((x) => [x.ref.toLowerCase(), x]));
          for (const r of fresh) {
            const old = map.get(r.ref.toLowerCase());
            map.set(r.ref.toLowerCase(), { ...r, txHash: old?.txHash, action: old?.action, updatedAt: old?.updatedAt ?? r.updatedAt });
          }
          return [...map.values()].sort((a, b) => b.updatedAt - a.updatedAt).slice(0, 150);
        });
      });
    }, 20000);
    return () => clearInterval(t);
  }, [client, distribution, rows, readRow]);

  return (
    <div>
      <PageHeader title="Admin · Payouts" subtitle="Claim with signature + payout confirmation + reconciliation by ref." />

      <div className="grid gap-4">
        <Card>
          <CardHeader>
            <CardTitle>ClaimToWithSig</CardTitle>
            <CardDescription>Paste payload from `/payout` or complete fields manually.</CardDescription>
          </CardHeader>
          <CardContent className="space-y-3">
            <div className="grid gap-2 md:grid-cols-2">
              <Input value={distributionAddr} onChange={(e) => setDistributionAddr(e.target.value)} placeholder="Distribution 0x..." />
              <Input value={claimAccount} onChange={(e) => setClaimAccount(e.target.value)} placeholder="account 0x..." />
              <Input value={claimTo} onChange={(e) => setClaimTo(e.target.value)} placeholder="to 0x..." />
              <Input value={claimAmount} onChange={(e) => setClaimAmount(e.target.value)} placeholder={`maxAmount (${rewardSymbol})`} />
              <Input value={claimDeadline} onChange={(e) => setClaimDeadline(e.target.value)} placeholder="deadline (unix, uint64)" />
              <Input value={claimRef} onChange={(e) => setClaimRef(e.target.value)} placeholder="ref bytes32" />
              <Input value={claimRailHash} onChange={(e) => setClaimRailHash(e.target.value)} placeholder="payoutRailHash bytes32" />
            </div>

            <Textarea value={claimSig} onChange={(e) => setClaimSig(e.target.value)} placeholder="signature bytes hex 0x..." className="min-h-[90px]" />
            <Textarea value={payloadJson} onChange={(e) => setPayloadJson(e.target.value)} placeholder="payload JSON from /payout" className="min-h-[120px]" />

            <div className="flex flex-wrap items-center gap-2">
              <Button variant="secondary" onClick={onLoadPayload}>Load payload</Button>
              <Button onClick={onClaim} disabled={claimErrors.length > 0}>claimToWithSig</Button>
              <Button variant="secondary" onClick={() => navigator.clipboard.writeText(claimSig)} disabled={!claimSigHex}>Copy signature</Button>
            </div>

            <div className="flex flex-wrap items-center gap-2">
              <Badge tone={distribution ? "good" : "warn"}>{distribution ? "distribution ok" : "distribution missing"}</Badge>
              <Badge tone={roleCheck.data?.canClaim ? "good" : "warn"}>{roleCheck.data?.canClaim ? "operator role ok" : "operator role missing"}</Badge>
              <Badge tone={claimRefInfo.data?.status === "not-found" ? "good" : "bad"}>
                {claimRefInfo.data?.status === "not-found" ? "ref unused" : "ref already used"}
              </Badge>
              <Badge tone="default">pending: {pending.isLoading ? "..." : `${fmt(pending.data ?? 0n, rewardDecimals)} ${rewardSymbol}`}</Badge>
              {meta.data?.enforceComplianceOnClaim ? (
                <Badge tone={compliancePrecheck.data === false ? "bad" : "good"}>
                  {compliancePrecheck.data === false ? "Compliance denied" : "Compliance OK"}
                </Badge>
              ) : (
                <Badge tone="default">Claim compliance off</Badge>
              )}
            </div>
            {complianceBlocked ? (
              <div className="flex flex-wrap items-center gap-2">
                <a href={complianceHref} className="rounded-xl border border-border bg-card px-3 py-2 text-sm hover:shadow-soft">
                  Why blocked
                </a>
                <a href={onboardingHref} className="rounded-xl border border-border bg-card px-3 py-2 text-sm hover:shadow-soft">
                  Start onboarding
                </a>
              </div>
            ) : null}

            <div className="grid gap-2 text-xs text-text2 md:grid-cols-2">
              <div>CampaignId: {meta.data?.campaignId ? shortHex32(meta.data.campaignId) : "-"}</div>
              <div>RoleManager: {meta.data?.roleManager ? shortAddr(meta.data.roleManager, 6) : "-"}</div>
              <div>Reward token: {meta.data?.rewardToken ? shortAddr(meta.data.rewardToken, 6) : "-"}</div>
              <div>Share token: {meta.data?.shareToken ? shortAddr(meta.data.shareToken, 6) : "-"}</div>
              <div>Amount parsed: {claimAmountParsed ? `${fmt(claimAmountParsed, rewardDecimals)} ${rewardSymbol}` : "-"}</div>
              <div>Compliance: {complianceModule.data ? shortAddr(complianceModule.data, 6) : "-"}</div>
            </div>

            {payloadErr ? <div className="rounded-xl border border-bad/30 bg-bad/10 p-3 text-sm text-bad">{payloadErr}</div> : null}
            {claimErrors.length > 0 ? (
              <div className="flex flex-wrap gap-2">
                {claimErrors.map((e) => (
                  <Badge key={e} tone="warn">{e}</Badge>
                ))}
              </div>
            ) : null}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>ConfirmPayout</CardTitle>
            <CardDescription>Set `receiptHash` and call `confirmPayout(ref, receiptHash)`.</CardDescription>
          </CardHeader>
          <CardContent className="space-y-3">
            <div className="grid gap-2 md:grid-cols-2">
              <Input value={confirmRef} onChange={(e) => setConfirmRef(e.target.value)} placeholder="ref bytes32" />
              <Input value={receiptHash} onChange={(e) => setReceiptHash(e.target.value)} placeholder="receiptHash bytes32" />
            </div>
            <div className="grid gap-2 md:grid-cols-[1fr_auto]">
              <Input value={receiptText} onChange={(e) => setReceiptText(e.target.value)} placeholder="receipt text/id" />
              <Button variant="secondary" onClick={() => builtReceiptHash && setReceiptHash(builtReceiptHash)} disabled={!builtReceiptHash}>
                Use keccak(text)
              </Button>
            </div>

            <div className="flex flex-wrap items-center gap-2">
              <Button onClick={onConfirm} disabled={confirmErrors.length > 0}>confirmPayout</Button>
              <Badge tone={roleCheck.data?.canConfirm ? "good" : "warn"}>{roleCheck.data?.canConfirm ? "confirmer role ok" : "confirmer role missing"}</Badge>
              <Badge tone={confirmRefInfo.data ? statusTone(confirmRefInfo.data.status) : "default"}>
                {confirmRefInfo.data?.status ?? "unknown"}
              </Badge>
            </div>

            {confirmErrors.length > 0 ? (
              <div className="flex flex-wrap gap-2">
                {confirmErrors.map((e) => (
                  <Badge key={e} tone="warn">{e}</Badge>
                ))}
              </div>
            ) : null}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Lookup PayoutByRef</CardTitle>
            <CardDescription>Track ref and add it to reconciliation table.</CardDescription>
          </CardHeader>
          <CardContent className="space-y-3">
            <div className="grid gap-2 md:grid-cols-[1fr_auto_auto]">
              <Input value={lookupRef} onChange={(e) => setLookupRef(e.target.value)} placeholder="ref bytes32" />
              <Button variant="secondary" onClick={onTrackLookup} disabled={!lookupRefB32}>Track</Button>
              <Button variant="secondary" onClick={() => lookupRefB32 && setConfirmRef(lookupRefB32)} disabled={!lookupRefB32}>
                Use in confirm
              </Button>
            </div>

            {lookupInfo.data ? (
              <div className="grid gap-2 rounded-xl border border-border/80 bg-muted p-3 text-sm md:grid-cols-2">
                <div>ref: <span className="font-mono">{shortHex32(lookupInfo.data.ref)}</span></div>
                <div><Badge tone={statusTone(lookupInfo.data.status)}>{lookupInfo.data.status}</Badge></div>
                <div>railHash: {shortHex32(lookupInfo.data.railHash)}</div>
                <div>receiptHash: {shortHex32(lookupInfo.data.receiptHash)}</div>
                <div>amount: {fmt(lookupInfo.data.amount, rewardDecimals)} {rewardSymbol}</div>
                <div>to: {lookupInfo.data.to !== zeroAddress ? shortAddr(lookupInfo.data.to, 6) : "-"}</div>
              </div>
            ) : (
              <EmptyState title="No lookup result" description="Enter a valid ref and click Track." />
            )}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Reconciliation</CardTitle>
            <CardDescription>ref · railHash · receiptHash · amount · status</CardDescription>
          </CardHeader>
          <CardContent>
            {rows.length === 0 ? (
              <EmptyState title="No payout refs tracked" description="Execute claim/confirm or lookup to populate the table." />
            ) : (
              <>
                <div className="hidden md:block">
                  <div className="overflow-x-auto rounded-xl border border-border/80">
                    <table className="w-full min-w-[980px] text-left text-sm">
                      <thead className="bg-muted text-text2">
                        <tr>
                          <th className="px-3 py-2 font-medium">Ref</th>
                          <th className="px-3 py-2 font-medium">Rail</th>
                          <th className="px-3 py-2 font-medium">Receipt</th>
                          <th className="px-3 py-2 font-medium">Amount</th>
                          <th className="px-3 py-2 font-medium">Status</th>
                          <th className="px-3 py-2 font-medium">Tx</th>
                        </tr>
                      </thead>
                      <tbody>
                        {rows.map((row) => (
                          <tr key={row.ref} className="border-t border-border/70">
                            <td className="px-3 py-2 font-mono">{shortHex32(row.ref)}</td>
                            <td className="px-3 py-2 font-mono">{shortHex32(row.railHash)}</td>
                            <td className="px-3 py-2 font-mono">{shortHex32(row.receiptHash)}</td>
                            <td className="px-3 py-2 font-mono">{fmt(row.amount, rewardDecimals)} {rewardSymbol}</td>
                            <td className="px-3 py-2"><Badge tone={statusTone(row.status)}>{row.status}</Badge></td>
                            <td className="px-3 py-2">
                              {row.txHash ? (
                                <div className="flex items-center gap-2">
                                  <button type="button" className="rounded-md border border-border px-2 py-1 text-xs hover:bg-card" onClick={() => navigator.clipboard.writeText(row.txHash!)}>
                                    Copy
                                  </button>
                                  <a className="rounded-md border border-border px-2 py-1 text-xs hover:bg-card" href={explorerTxUrl(chainId, row.txHash)} target="_blank" rel="noreferrer">
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
                  {rows.map((row) => (
                    <div key={row.ref} className="rounded-xl border border-border/80 bg-card p-3">
                      <div className="flex items-start justify-between gap-2">
                        <div className="font-medium">Ref {shortHex32(row.ref)}</div>
                        <Badge tone={statusTone(row.status)}>{row.status}</Badge>
                      </div>
                      <div className="mt-2 text-xs text-text2">Rail: {shortHex32(row.railHash)}</div>
                      <div className="mt-1 text-xs text-text2">Receipt: {shortHex32(row.receiptHash)}</div>
                      <div className="mt-1 text-xs text-text2">Amount: {fmt(row.amount, rewardDecimals)} {rewardSymbol}</div>
                      <div className="mt-1 text-xs text-text2">Updated: {new Date(row.updatedAt).toLocaleString()}</div>
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
