"use client";

import * as React from "react";
import { useQuery } from "@tanstack/react-query";
import { encodePacked, formatUnits, isAddress, keccak256, parseUnits, toHex } from "viem";
import { useAccount, useChainId, usePublicClient } from "wagmi";
import { PageHeader } from "@/components/ui/PageHeader";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { Button } from "@/components/ui/Button";
import { Badge } from "@/components/ui/Badge";
import { EmptyState } from "@/components/ui/EmptyState";
import { MobileStickyBar } from "@/components/ui/MobileStickyBar";
import { useTx } from "@/hooks/useTx";
import {
  complianceAbi,
  erc20Abi,
  erc20AllowanceAbi,
  erc20DecimalsAbi,
  fundingManagerAbi,
  roleManagerAbi,
  shareTokenAbi
} from "@/lib/abi";
import { explorerTxUrl } from "@/lib/explorer";
import { shortAddr, shortHex32 } from "@/lib/format";

const B32_ZERO = ("0x" + "00".repeat(32)) as `0x${string}`;
const B32_RE = /^0x[0-9a-fA-F]{64}$/u;
const UINT64_MAX = 2n ** 64n - 1n;

const DEFAULT_ADMIN_ROLE = ("0x" + "00".repeat(32)) as `0x${string}`;
const TREASURY_ADMIN_ROLE = keccak256(toHex("TREASURY_ADMIN_ROLE")) as `0x${string}`;
const GOVERNANCE_ROLE = keccak256(toHex("GOVERNANCE_ROLE")) as `0x${string}`;
const ONRAMP_OPERATOR_ROLE = keccak256(toHex("ONRAMP_OPERATOR_ROLE")) as `0x${string}`;

type AuditEntry = {
  ref: `0x${string}`;
  payer: `0x${string}`;
  beneficiary: `0x${string}`;
  amountIn: string;
  minSharesOut: string;
  deadline: string;
  txHash: `0x${string}`;
  createdAt: number;
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

function fmtTs(ts: number): string {
  return new Date(ts).toLocaleString();
}

function statusTone(status: string): "default" | "good" | "warn" | "bad" | "accent" {
  if (status === "success") return "good";
  if (status === "reverted") return "bad";
  if (status === "pending") return "warn";
  return "default";
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

export default function AdminOnRampPage() {
  const chainId = useChainId();
  const client = usePublicClient();
  const { address, isConnected } = useAccount();
  const { sendTx } = useTx();

  const [fundingManagerAddr, setFundingManagerAddr] = React.useState<string>("");
  const [payer, setPayer] = React.useState<string>("");
  const [beneficiary, setBeneficiary] = React.useState<string>("");
  const [amountIn, setAmountIn] = React.useState<string>("100");
  const [minSharesOut, setMinSharesOut] = React.useState<string>("0");
  const [deadline, setDeadline] = React.useState<string>(() => String(Math.floor(Date.now() / 1000) + 3600));
  const [ref, setRef] = React.useState<string>(B32_ZERO);

  const [userRef, setUserRef] = React.useState<string>("");
  const [refTimestamp, setRefTimestamp] = React.useState<string>(() => String(Math.floor(Date.now() / 1000)));

  const [auditEntries, setAuditEntries] = React.useState<AuditEntry[]>([]);

  React.useEffect(() => {
    if (typeof window === "undefined") return;
    const search = new URLSearchParams(window.location.search);
    const qAddr = search.get("addr") ?? "";
    const qPayer = search.get("payer") ?? "";
    const qBeneficiary = search.get("beneficiary") ?? "";
    const qAmountIn = search.get("amountIn") ?? "";
    const qMinSharesOut = search.get("minSharesOut") ?? "";
    const qDeadline = search.get("deadline") ?? "";
    const qRef = search.get("ref") ?? "";

    if (qAddr && canAddr(qAddr)) setFundingManagerAddr(qAddr);
    if (qPayer && canAddr(qPayer)) setPayer(qPayer);
    if (qBeneficiary && canAddr(qBeneficiary)) setBeneficiary(qBeneficiary);
    if (qAmountIn) setAmountIn(qAmountIn);
    if (qMinSharesOut) setMinSharesOut(qMinSharesOut);
    if (qDeadline && parseUint64(qDeadline) !== undefined) setDeadline(qDeadline);
    if (qRef && isBytes32(qRef)) setRef(qRef);
  }, []);

  const fundingManager = canAddr(fundingManagerAddr) ? fundingManagerAddr : undefined;
  const payerAddr = canAddr(payer) ? payer : undefined;
  const beneficiaryAddr = canAddr(beneficiary) ? beneficiary : undefined;
  const parsedDeadline = parseUint64(deadline);
  const parsedRef = isBytes32(ref) ? (ref.trim() as `0x${string}`) : undefined;
  const refNonZero = Boolean(parsedRef && parsedRef.toLowerCase() !== B32_ZERO);

  const fmMeta = useQuery({
    queryKey: ["onrampFundingMeta", fundingManager],
    enabled: !!client && !!fundingManager,
    queryFn: async () => {
      if (!client || !fundingManager) {
        return {
          campaignId: undefined,
          roleManager: undefined,
          settlementAsset: undefined,
          shareToken: undefined
        };
      }
      const [campaignId, roleManager, settlementAsset, shareToken] = await Promise.all([
        client.readContract({ address: fundingManager, abi: fundingManagerAbi, functionName: "campaignId" }).catch(() => undefined),
        client.readContract({ address: fundingManager, abi: fundingManagerAbi, functionName: "roleManager" }).catch(() => undefined),
        client.readContract({ address: fundingManager, abi: fundingManagerAbi, functionName: "settlementAsset" }).catch(() => undefined),
        client.readContract({ address: fundingManager, abi: fundingManagerAbi, functionName: "shareToken" }).catch(() => undefined)
      ]);
      return {
        campaignId: campaignId as `0x${string}` | undefined,
        roleManager: roleManager as `0x${string}` | undefined,
        settlementAsset: settlementAsset as `0x${string}` | undefined,
        shareToken: shareToken as `0x${string}` | undefined
      };
    }
  });

  const settlementMeta = useQuery({
    queryKey: ["onrampSettlementMeta", fmMeta.data?.settlementAsset],
    enabled: !!client && !!fmMeta.data?.settlementAsset,
    queryFn: async () => {
      if (!client || !fmMeta.data?.settlementAsset) {
        return { symbol: "ASSET", decimals: 6 };
      }
      const token = fmMeta.data.settlementAsset;
      const [symbol, decimals] = await Promise.all([
        client.readContract({ address: token, abi: erc20AllowanceAbi, functionName: "symbol" }).catch(() => "ASSET"),
        client.readContract({ address: token, abi: erc20DecimalsAbi, functionName: "decimals" }).catch(() => 6)
      ]);
      return {
        symbol: String(symbol || "ASSET"),
        decimals: Number(decimals ?? 6)
      };
    }
  });

  const shareMeta = useQuery({
    queryKey: ["onrampShareMeta", fmMeta.data?.shareToken],
    enabled: !!client && !!fmMeta.data?.shareToken,
    queryFn: async () => {
      if (!client || !fmMeta.data?.shareToken) {
        return { symbol: "SHARE", decimals: 18, compliance: undefined as `0x${string}` | undefined };
      }
      const shareToken = fmMeta.data.shareToken;
      const [symbol, decimals, compliance] = await Promise.all([
        client.readContract({ address: shareToken, abi: shareTokenAbi, functionName: "symbol" }).catch(() => "SHARE"),
        client.readContract({ address: shareToken, abi: shareTokenAbi, functionName: "decimals" }).catch(() => 18),
        client.readContract({ address: shareToken, abi: shareTokenAbi, functionName: "complianceModule" }).catch(() => undefined)
      ]);
      return {
        symbol: String(symbol || "SHARE"),
        decimals: Number(decimals ?? 18),
        compliance: compliance as `0x${string}` | undefined
      };
    }
  });

  const roleCheck = useQuery({
    queryKey: ["onrampRoleCheck", fmMeta.data?.roleManager, address],
    enabled: !!client && !!fmMeta.data?.roleManager && !!address,
    queryFn: async () => {
      if (!client || !fmMeta.data?.roleManager || !address) {
        return { allowed: false, byRole: [] as { label: string; ok: boolean }[] };
      }
      const roleManager = fmMeta.data.roleManager;
      const rolesToCheck = [
        { label: "OnRamp operator", role: ONRAMP_OPERATOR_ROLE },
        { label: "Treasury admin", role: TREASURY_ADMIN_ROLE },
        { label: "Governance", role: GOVERNANCE_ROLE },
        { label: "Default admin", role: DEFAULT_ADMIN_ROLE }
      ];
      const byRole = await Promise.all(
        rolesToCheck.map(async (r) => {
          const ok = Boolean(
            await client.readContract({
              address: roleManager,
              abi: roleManagerAbi,
              functionName: "hasRole",
              args: [r.role, address]
            }).catch(() => false)
          );
          return { label: r.label, ok };
        })
      );
      return {
        allowed: byRole.some((x) => x.ok),
        byRole
      };
    }
  });

  const refUsed = useQuery({
    queryKey: ["onrampRefUsed", fundingManager, parsedRef ?? "none"],
    enabled: !!client && !!fundingManager && !!parsedRef,
    queryFn: async () => {
      if (!client || !fundingManager || !parsedRef) return false;
      return Boolean(
        await client.readContract({
          address: fundingManager,
          abi: fundingManagerAbi,
          functionName: "usedSponsoredDepositRef",
          args: [parsedRef]
        }).catch(() => false)
      );
    }
  });

  const compliancePrecheck = useQuery({
    queryKey: ["onrampCompliancePrecheck", shareMeta.data?.compliance ?? "none", beneficiaryAddr ?? "none"],
    enabled: !!client && !!shareMeta.data?.compliance && !!beneficiaryAddr,
    queryFn: async () => {
      if (!client || !shareMeta.data?.compliance || !beneficiaryAddr) return true;
      return Boolean(
        await client.readContract({
          address: shareMeta.data.compliance,
          abi: complianceAbi,
          functionName: "canTransact",
          args: [beneficiaryAddr]
        }).catch(() => false)
      );
    }
  });

  const payerState = useQuery({
    queryKey: ["onrampPayerState", fmMeta.data?.settlementAsset ?? "none", fundingManager ?? "none", payerAddr ?? "none"],
    enabled: !!client && !!fmMeta.data?.settlementAsset && !!fundingManager && !!payerAddr,
    queryFn: async () => {
      if (!client || !fmMeta.data?.settlementAsset || !fundingManager || !payerAddr) {
        return { allowance: 0n, balance: 0n };
      }
      const token = fmMeta.data.settlementAsset;
      const [allowance, balance] = await Promise.all([
        client.readContract({
          address: token,
          abi: erc20AllowanceAbi,
          functionName: "allowance",
          args: [payerAddr, fundingManager]
        }).catch(() => 0n),
        client.readContract({
          address: token,
          abi: erc20Abi,
          functionName: "balanceOf",
          args: [payerAddr]
        }).catch(() => 0n)
      ]);
      return {
        allowance: BigInt(allowance as any),
        balance: BigInt(balance as any)
      };
    }
  });

  const assetSymbol = settlementMeta.data?.symbol ?? "ASSET";
  const assetDecimals = settlementMeta.data?.decimals ?? 6;
  const shareSymbol = shareMeta.data?.symbol ?? "SHARE";
  const shareDecimals = shareMeta.data?.decimals ?? 18;

  const parsedAssetsIn = parseAmount(amountIn, assetDecimals);
  const parsedMinSharesOut = parseAmount(minSharesOut, shareDecimals) ?? 0n;

  const builtRef = React.useMemo(() => {
    const campaignId = fmMeta.data?.campaignId;
    const ts = parseUint64(refTimestamp);
    const label = userRef.trim();
    if (!campaignId || !ts || !label) return "";
    return keccak256(encodePacked(["string", "uint64", "bytes32"], [label, ts, campaignId]));
  }, [userRef, refTimestamp, fmMeta.data?.campaignId]);

  const storageKey = React.useMemo(
    () => `uagri:onramp:audit:v1:${chainId}:${fundingManager ?? "none"}`,
    [chainId, fundingManager]
  );

  React.useEffect(() => {
    if (typeof window === "undefined") return;
    try {
      const raw = window.localStorage.getItem(storageKey);
      if (!raw) {
        setAuditEntries([]);
        return;
      }
      const parsed = JSON.parse(raw) as AuditEntry[];
      setAuditEntries(Array.isArray(parsed) ? parsed : []);
    } catch {
      setAuditEntries([]);
    }
  }, [storageKey]);

  React.useEffect(() => {
    if (typeof window === "undefined") return;
    window.localStorage.setItem(storageKey, JSON.stringify(auditEntries.slice(0, 80)));
  }, [auditEntries, storageKey]);

  const receiptStatus = useQuery({
    queryKey: ["onrampAuditReceipts", auditEntries.map((x) => x.txHash).join(",")],
    enabled: !!client && auditEntries.length > 0,
    refetchInterval: 15_000,
    queryFn: async () => {
      if (!client || auditEntries.length === 0) return {} as Record<string, "pending" | "success" | "reverted">;
      const map: Record<string, "pending" | "success" | "reverted"> = {};
      await Promise.all(
        auditEntries.map(async (entry) => {
          try {
            const receipt = await client.getTransactionReceipt({ hash: entry.txHash });
            map[entry.txHash] = receipt.status === "success" ? "success" : "reverted";
          } catch {
            map[entry.txHash] = "pending";
          }
        })
      );
      return map;
    }
  });

  const inputErrors: string[] = [];
  if (!fundingManager) inputErrors.push("FundingManager required");
  if (!payerAddr) inputErrors.push("Payer address invalid");
  if (!beneficiaryAddr) inputErrors.push("Beneficiary address invalid");
  if (!parsedAssetsIn || parsedAssetsIn <= 0n) inputErrors.push("amountIn must be > 0");
  if (!parsedDeadline) inputErrors.push("Deadline must be uint64");
  if (!parsedRef) inputErrors.push("ref must be bytes32");
  if (parsedRef && parsedRef.toLowerCase() === B32_ZERO) inputErrors.push("ref cannot be zero");
  if (refUsed.data) inputErrors.push("ref already used on-chain");
  if (!isConnected) inputErrors.push("Connect wallet");
  if (isConnected && roleCheck.data && !roleCheck.data.allowed) inputErrors.push("Wallet lacks onramp operator role");
  if (shareMeta.data?.compliance && beneficiaryAddr && compliancePrecheck.data === false) {
    inputErrors.push("Beneficiary blocked by compliance");
  }
  if (parsedAssetsIn && payerState.data && payerState.data.allowance < parsedAssetsIn) {
    inputErrors.push("Payer allowance too low");
  }
  if (parsedAssetsIn && payerState.data && payerState.data.balance < parsedAssetsIn) {
    inputErrors.push("Payer balance too low");
  }
  const complianceBlocked = Boolean(shareMeta.data?.compliance && beneficiaryAddr && compliancePrecheck.data === false);
  const complianceHref = queryHref("/compliance", {
    compliance: shareMeta.data?.compliance,
    from: beneficiaryAddr,
    to: beneficiaryAddr,
    amount: "1"
  });
  const onboardingHref = queryHref("/onboarding", {
    compliance: shareMeta.data?.compliance,
    account: beneficiaryAddr
  });

  const onUseBuiltRef = () => {
    if (!builtRef) return;
    setRef(builtRef);
  };

  const onSetNow = () => {
    setRefTimestamp(String(Math.floor(Date.now() / 1000)));
  };

  const onSubmit = async () => {
    if (!fundingManager || !payerAddr || !beneficiaryAddr || !parsedAssetsIn || !parsedDeadline || !parsedRef) return;
    const txHash = await sendTx({
      title: "OnRamp sponsored deposit",
      address: fundingManager,
      abi: fundingManagerAbi,
      functionName: "settleDepositExactAssetsFrom",
      args: [payerAddr, beneficiaryAddr, parsedAssetsIn, parsedMinSharesOut, parsedDeadline, parsedRef]
    } as any);

    const entry: AuditEntry = {
      ref: parsedRef,
      payer: payerAddr,
      beneficiary: beneficiaryAddr,
      amountIn: parsedAssetsIn.toString(),
      minSharesOut: parsedMinSharesOut.toString(),
      deadline: parsedDeadline.toString(),
      txHash,
      createdAt: Date.now()
    };
    setAuditEntries((prev) => [entry, ...prev.filter((x) => x.ref.toLowerCase() !== parsedRef.toLowerCase())].slice(0, 80));
    void refUsed.refetch();
    void receiptStatus.refetch();
  };

  return (
    <div className="pb-36 md:pb-0">
      <PageHeader
        title="Admin · OnRamp"
        subtitle="Sponsored FIAT deposit: payer sends settlement asset, beneficiary receives shares."
      />

      <div className="grid gap-4">
        <Card>
          <CardHeader>
            <CardTitle>Sponsored Deposit</CardTitle>
            <CardDescription>Calls `settleDepositExactAssetsFrom` with idempotent `ref` guard.</CardDescription>
          </CardHeader>
          <CardContent className="space-y-3">
            <div className="grid gap-2 md:grid-cols-2">
              <Input value={fundingManagerAddr} onChange={(e) => setFundingManagerAddr(e.target.value)} placeholder="FundingManager 0x..." />
              <Input value={payer} onChange={(e) => setPayer(e.target.value)} placeholder="Payer 0x..." />
              <Input value={beneficiary} onChange={(e) => setBeneficiary(e.target.value)} placeholder="Beneficiary 0x..." />
              <Input value={amountIn} onChange={(e) => setAmountIn(e.target.value)} placeholder={`amountIn (${assetSymbol})`} />
              <Input value={minSharesOut} onChange={(e) => setMinSharesOut(e.target.value)} placeholder={`minSharesOut (${shareSymbol})`} />
              <Input value={deadline} onChange={(e) => setDeadline(e.target.value)} placeholder="deadline (unix, uint64)" />
            </div>

            <Input value={ref} onChange={(e) => setRef(e.target.value)} placeholder="ref bytes32 (non-zero)" />

            <div className="flex flex-wrap items-center gap-2">
              <Badge tone={fundingManager ? "good" : "warn"}>{fundingManager ? "FundingManager OK" : "FundingManager missing"}</Badge>
              <Badge tone={refNonZero ? "good" : "warn"}>{refNonZero ? "ref non-zero" : "ref invalid/zero"}</Badge>
              <Badge tone={refUsed.data ? "bad" : "good"}>{refUsed.data ? "ref already used" : "ref unused"}</Badge>
              <Badge tone={shareMeta.data?.compliance ? (compliancePrecheck.data ? "good" : "bad") : "default"}>
                {shareMeta.data?.compliance
                  ? (compliancePrecheck.data ? "Beneficiary compliance OK" : "Beneficiary compliance denied")
                  : "No compliance module"}
              </Badge>
              <Badge tone={roleCheck.data?.allowed ? "good" : "warn"}>
                {roleCheck.data?.allowed ? "OnRamp role OK" : "OnRamp role missing"}
              </Badge>
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
              <div>CampaignId: {fmMeta.data?.campaignId ? shortHex32(fmMeta.data.campaignId) : "-"}</div>
              <div>Settlement asset: {fmMeta.data?.settlementAsset ? shortAddr(fmMeta.data.settlementAsset, 6) : "-"}</div>
              <div>Share token: {fmMeta.data?.shareToken ? shortAddr(fmMeta.data.shareToken, 6) : "-"}</div>
              <div>RoleManager: {fmMeta.data?.roleManager ? shortAddr(fmMeta.data.roleManager, 6) : "-"}</div>
              <div>
                Payer allowance:{" "}
                <span className="font-mono">{fmtAmount(payerState.data?.allowance ?? 0n, assetDecimals)} {assetSymbol}</span>
              </div>
              <div>
                Payer balance:{" "}
                <span className="font-mono">{fmtAmount(payerState.data?.balance ?? 0n, assetDecimals)} {assetSymbol}</span>
              </div>
            </div>

            {roleCheck.data?.byRole?.length ? (
              <div className="flex flex-wrap gap-2">
                {roleCheck.data.byRole.map((r) => (
                  <Badge key={r.label} tone={r.ok ? "good" : "default"}>{r.label}</Badge>
                ))}
              </div>
            ) : null}

            <div className="flex flex-wrap items-center gap-2">
              <Button onClick={onSubmit} disabled={inputErrors.length > 0}>
                settleDepositExactAssetsFrom
              </Button>
              <Button
                variant="secondary"
                onClick={() => {
                  void fmMeta.refetch();
                  void roleCheck.refetch();
                  void refUsed.refetch();
                  void compliancePrecheck.refetch();
                  void payerState.refetch();
                  void receiptStatus.refetch();
                }}
              >
                Refresh
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
            <CardTitle>Ref Builder</CardTitle>
            <CardDescription>Build `ref = keccak(userRef + timestamp + campaignId)` and copy/use it.</CardDescription>
          </CardHeader>
          <CardContent className="space-y-3">
            <div className="grid gap-2 md:grid-cols-[1fr_auto]">
              <Input value={userRef} onChange={(e) => setUserRef(e.target.value)} placeholder="userRef label (invoice / fiat id)" />
              <Button variant="secondary" onClick={onSetNow}>Now</Button>
            </div>
            <Input value={refTimestamp} onChange={(e) => setRefTimestamp(e.target.value)} placeholder="timestamp (unix, uint64)" />
            <Input value={builtRef} readOnly placeholder="keccak(userRef + timestamp + campaignId)" />
            <div className="flex flex-wrap items-center gap-2">
              <Button variant="secondary" onClick={onUseBuiltRef} disabled={!builtRef}>Use built ref</Button>
              <Button
                variant="secondary"
                onClick={() => navigator.clipboard.writeText(ref)}
                disabled={!isBytes32(ref)}
              >
                Copy ref
              </Button>
            </div>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Audit Table</CardTitle>
            <CardDescription>Local audit trail: `ref → txHash → status`.</CardDescription>
          </CardHeader>
          <CardContent>
            {auditEntries.length === 0 ? (
              <EmptyState title="No onramp records" description="Submit a sponsored deposit to populate audit entries." />
            ) : (
              <>
                <div className="hidden md:block">
                  <div className="overflow-x-auto rounded-xl border border-border/80">
                    <table className="w-full min-w-[980px] text-left text-sm">
                      <thead className="bg-muted text-text2">
                        <tr>
                          <th className="px-3 py-2 font-medium">Ref</th>
                          <th className="px-3 py-2 font-medium">Payer</th>
                          <th className="px-3 py-2 font-medium">Beneficiary</th>
                          <th className="px-3 py-2 font-medium">Amount In</th>
                          <th className="px-3 py-2 font-medium">Tx</th>
                          <th className="px-3 py-2 font-medium">Status</th>
                        </tr>
                      </thead>
                      <tbody>
                        {auditEntries.map((row) => {
                          const status = receiptStatus.data?.[row.txHash] ?? "pending";
                          return (
                            <tr key={`${row.ref}-${row.txHash}`} className="border-t border-border/70">
                              <td className="px-3 py-2 font-mono">{shortHex32(row.ref)}</td>
                              <td className="px-3 py-2">{shortAddr(row.payer, 6)}</td>
                              <td className="px-3 py-2">{shortAddr(row.beneficiary, 6)}</td>
                              <td className="px-3 py-2 font-mono">
                                {fmtAmount(BigInt(row.amountIn), assetDecimals)} {assetSymbol}
                              </td>
                              <td className="px-3 py-2">
                                <div className="flex items-center gap-2">
                                  <button
                                    type="button"
                                    className="rounded-md border border-border px-2 py-1 text-xs hover:bg-card"
                                    onClick={() => navigator.clipboard.writeText(row.txHash)}
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
                              </td>
                              <td className="px-3 py-2">
                                <Badge tone={statusTone(status)}>{status}</Badge>
                              </td>
                            </tr>
                          );
                        })}
                      </tbody>
                    </table>
                  </div>
                </div>

                <div className="grid gap-3 md:hidden">
                  {auditEntries.map((row) => {
                    const status = receiptStatus.data?.[row.txHash] ?? "pending";
                    return (
                      <div key={`${row.ref}-${row.txHash}`} className="rounded-xl border border-border/80 bg-card p-3">
                        <div className="flex items-start justify-between gap-2">
                          <div className="font-medium">Ref {shortHex32(row.ref)}</div>
                          <Badge tone={statusTone(status)}>{status}</Badge>
                        </div>
                        <div className="mt-2 text-xs text-text2">Payer: {shortAddr(row.payer, 6)}</div>
                        <div className="mt-1 text-xs text-text2">Beneficiary: {shortAddr(row.beneficiary, 6)}</div>
                        <div className="mt-1 text-xs text-text2">
                          Amount: {fmtAmount(BigInt(row.amountIn), assetDecimals)} {assetSymbol}
                        </div>
                        <div className="mt-1 text-xs text-text2">Created: {fmtTs(row.createdAt)}</div>
                        <div className="mt-3 flex flex-wrap items-center gap-2">
                          <button
                            type="button"
                            className="rounded-md border border-border px-2 py-1 text-xs hover:bg-muted"
                            onClick={() => navigator.clipboard.writeText(row.txHash)}
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
                      </div>
                    );
                  })}
                </div>
              </>
            )}
          </CardContent>
        </Card>
      </div>

      <MobileStickyBar testId="onramp-sticky-actions" ariaLabel="Onramp sticky actions">
        <div className="grid grid-cols-2 gap-2">
          <Button size="sm" onClick={onSubmit} disabled={inputErrors.length > 0} data-testid="onramp-sticky-submit">
            settleDepositExactAssetsFrom
          </Button>
          <Button
            size="sm"
            variant="secondary"
            onClick={() => {
              void fmMeta.refetch();
              void roleCheck.refetch();
              void refUsed.refetch();
              void compliancePrecheck.refetch();
              void payerState.refetch();
              void receiptStatus.refetch();
            }}
          >
            Refresh
          </Button>
        </div>
      </MobileStickyBar>
    </div>
  );
}
