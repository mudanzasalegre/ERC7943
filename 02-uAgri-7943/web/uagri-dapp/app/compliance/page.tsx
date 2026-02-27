"use client";

import * as React from "react";
import { useQuery } from "@tanstack/react-query";
import { formatUnits, isAddress, parseUnits, zeroAddress } from "viem";
import { useAccount, usePublicClient } from "wagmi";
import { PageHeader } from "@/components/ui/PageHeader";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { Button } from "@/components/ui/Button";
import { Badge } from "@/components/ui/Badge";
import { EmptyState } from "@/components/ui/EmptyState";
import { complianceAbi, complianceModuleAbi, identityAttestationAbi, shareTokenAbi } from "@/lib/abi";
import { complianceReason, needsOnboarding } from "@/lib/compliance";
import { shortAddr } from "@/lib/format";

type IdentityPayload = {
  jurisdiction: number;
  tier: number;
  flags: number;
  expiry: bigint;
  lockupUntil: bigint;
  providerId: number;
};

const EMPTY_IDENTITY: IdentityPayload = {
  jurisdiction: 0,
  tier: 0,
  flags: 0,
  expiry: 0n,
  lockupUntil: 0n,
  providerId: 0
};

function canAddr(v: string): v is `0x${string}` {
  return isAddress(v);
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

function fromTs(ts: bigint): string {
  if (!ts || ts <= 0n) return "-";
  return new Date(Number(ts) * 1000).toLocaleString();
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

export default function CompliancePage() {
  const client = usePublicClient();
  const { address } = useAccount();

  const [tokenAddr, setTokenAddr] = React.useState("");
  const [complianceAddr, setComplianceAddr] = React.useState("");
  const [from, setFrom] = React.useState("");
  const [to, setTo] = React.useState("");
  const [amount, setAmount] = React.useState("1");

  React.useEffect(() => {
    if (typeof window === "undefined") return;
    const p = new URLSearchParams(window.location.search);
    const qToken = p.get("token") ?? "";
    const qCompliance = p.get("compliance") ?? p.get("addr") ?? "";
    const qFrom = p.get("from") ?? p.get("account") ?? "";
    const qTo = p.get("to") ?? "";
    const qAmount = p.get("amount") ?? "";
    if (qToken && canAddr(qToken) && !tokenAddr) setTokenAddr(qToken);
    if (qCompliance && canAddr(qCompliance) && !complianceAddr) setComplianceAddr(qCompliance);
    if (qFrom && canAddr(qFrom) && !from) setFrom(qFrom);
    if (qTo && canAddr(qTo) && !to) setTo(qTo);
    if (qAmount && !amount) setAmount(qAmount);
  }, [amount, complianceAddr, from, to, tokenAddr]);

  React.useEffect(() => {
    if (!address) return;
    if (!from) setFrom(address);
    if (!to) setTo(address);
  }, [address, from, to]);

  const token = canAddr(tokenAddr) ? tokenAddr : undefined;
  const complianceInput = canAddr(complianceAddr) ? complianceAddr : undefined;
  const fromAddr = canAddr(from) ? from : undefined;
  const toAddr = canAddr(to) ? to : undefined;

  const tokenMeta = useQuery({
    queryKey: ["complianceTokenMeta", token],
    enabled: !!client && !!token,
    queryFn: async () => {
      if (!client || !token) {
        return { symbol: "SHARE", decimals: 18, compliance: undefined as `0x${string}` | undefined };
      }
      const [symbol, decimals, compliance] = await Promise.all([
        client.readContract({ address: token, abi: shareTokenAbi, functionName: "symbol" }).catch(() => "SHARE"),
        client.readContract({ address: token, abi: shareTokenAbi, functionName: "decimals" }).catch(() => 18),
        client.readContract({ address: token, abi: shareTokenAbi, functionName: "complianceModule" }).catch(() => undefined)
      ]);
      return {
        symbol: String(symbol || "SHARE"),
        decimals: Number(decimals ?? 18),
        compliance: (compliance as `0x${string}` | undefined) ?? undefined
      };
    }
  });

  const shareSymbol = tokenMeta.data?.symbol ?? "SHARE";
  const shareDecimals = tokenMeta.data?.decimals ?? 18;
  const parsedAmount = parseAmount(amount, shareDecimals);
  const compliance = complianceInput ?? tokenMeta.data?.compliance;

  const checks = useQuery({
    queryKey: [
      "complianceChecks",
      compliance ?? "none",
      fromAddr ?? "none",
      toAddr ?? "none",
      parsedAmount?.toString() ?? "none"
    ],
    enabled: !!client && !!compliance && !!fromAddr && !!toAddr && !!parsedAmount,
    queryFn: async () => {
      if (!client || !compliance || !fromAddr || !toAddr || !parsedAmount) {
        return undefined;
      }

      const [canTransact, canTransfer, transactStatusRaw, transferStatusRaw, paused, isExemptFrom, isDenyFrom, isSanctionFrom, isExemptTo, isDenyTo, isSanctionTo, identityAttestation] =
        await Promise.all([
          client.readContract({ address: compliance, abi: complianceAbi, functionName: "canTransact", args: [fromAddr] }).catch(() => false),
          client.readContract({ address: compliance, abi: complianceAbi, functionName: "canTransfer", args: [fromAddr, toAddr, parsedAmount] }).catch(() => false),
          client.readContract({ address: compliance, abi: complianceModuleAbi, functionName: "transactStatus", args: [fromAddr] }).catch(() => undefined),
          client.readContract({ address: compliance, abi: complianceModuleAbi, functionName: "transferStatus", args: [fromAddr, toAddr, parsedAmount] }).catch(() => undefined),
          client.readContract({ address: compliance, abi: complianceModuleAbi, functionName: "paused" }).catch(() => false),
          client.readContract({ address: compliance, abi: complianceModuleAbi, functionName: "isExempt", args: [fromAddr] }).catch(() => false),
          client.readContract({ address: compliance, abi: complianceModuleAbi, functionName: "isDenylisted", args: [fromAddr] }).catch(() => false),
          client.readContract({ address: compliance, abi: complianceModuleAbi, functionName: "isSanctioned", args: [fromAddr] }).catch(() => false),
          client.readContract({ address: compliance, abi: complianceModuleAbi, functionName: "isExempt", args: [toAddr] }).catch(() => false),
          client.readContract({ address: compliance, abi: complianceModuleAbi, functionName: "isDenylisted", args: [toAddr] }).catch(() => false),
          client.readContract({ address: compliance, abi: complianceModuleAbi, functionName: "isSanctioned", args: [toAddr] }).catch(() => false),
          client.readContract({ address: compliance, abi: complianceModuleAbi, functionName: "identityAttestation" }).catch(() => undefined)
        ]);

      const txStatusOk = Boolean((transactStatusRaw as any)?.ok ?? (transactStatusRaw as any)?.[0] ?? canTransact);
      const txCode = Number((transactStatusRaw as any)?.code ?? (transactStatusRaw as any)?.[1] ?? (canTransact ? 0 : 255));
      const trStatusOk = Boolean((transferStatusRaw as any)?.ok ?? (transferStatusRaw as any)?.[0] ?? canTransfer);
      const trCode = Number((transferStatusRaw as any)?.code ?? (transferStatusRaw as any)?.[1] ?? (canTransfer ? 0 : 255));

      const identityModule = canAddr(String(identityAttestation ?? "")) ? (identityAttestation as `0x${string}`) : undefined;

      let fromIdentity = EMPTY_IDENTITY;
      let toIdentity = EMPTY_IDENTITY;
      if (identityModule) {
        const [fromRaw, toRaw] = await Promise.all([
          client.readContract({ address: identityModule, abi: identityAttestationAbi, functionName: "identityOf", args: [fromAddr] }).catch(() => undefined),
          client.readContract({ address: identityModule, abi: identityAttestationAbi, functionName: "identityOf", args: [toAddr] }).catch(() => undefined)
        ]);
        fromIdentity = {
          jurisdiction: Number((fromRaw as any)?.jurisdiction ?? (fromRaw as any)?.[0] ?? 0),
          tier: Number((fromRaw as any)?.tier ?? (fromRaw as any)?.[1] ?? 0),
          flags: Number((fromRaw as any)?.flags ?? (fromRaw as any)?.[2] ?? 0),
          expiry: BigInt((fromRaw as any)?.expiry ?? (fromRaw as any)?.[3] ?? 0),
          lockupUntil: BigInt((fromRaw as any)?.lockupUntil ?? (fromRaw as any)?.[4] ?? 0),
          providerId: Number((fromRaw as any)?.providerId ?? (fromRaw as any)?.[5] ?? 0)
        };
        toIdentity = {
          jurisdiction: Number((toRaw as any)?.jurisdiction ?? (toRaw as any)?.[0] ?? 0),
          tier: Number((toRaw as any)?.tier ?? (toRaw as any)?.[1] ?? 0),
          flags: Number((toRaw as any)?.flags ?? (toRaw as any)?.[2] ?? 0),
          expiry: BigInt((toRaw as any)?.expiry ?? (toRaw as any)?.[3] ?? 0),
          lockupUntil: BigInt((toRaw as any)?.lockupUntil ?? (toRaw as any)?.[4] ?? 0),
          providerId: Number((toRaw as any)?.providerId ?? (toRaw as any)?.[5] ?? 0)
        };
      }

      return {
        canTransact: Boolean(canTransact),
        canTransfer: Boolean(canTransfer),
        transactStatusOk: txStatusOk,
        transferStatusOk: trStatusOk,
        transactCode: txCode,
        transferCode: trCode,
        paused: Boolean(paused),
        identityModule,
        fromFlags: { exempt: Boolean(isExemptFrom), denylisted: Boolean(isDenyFrom), sanctioned: Boolean(isSanctionFrom) },
        toFlags: { exempt: Boolean(isExemptTo), denylisted: Boolean(isDenyTo), sanctioned: Boolean(isSanctionTo) },
        fromIdentity,
        toIdentity
      };
    }
  });

  const txReason = complianceReason(checks.data?.transactCode);
  const trReason = complianceReason(checks.data?.transferCode);
  const blocked = checks.data ? !checks.data.canTransact || !checks.data.canTransfer : false;
  const onboardingCta = blocked && (needsOnboarding(checks.data?.transactCode) || needsOnboarding(checks.data?.transferCode));
  const onboardingHref = queryHref("/onboarding", {
    token,
    compliance,
    identity: checks.data?.identityModule,
    account: fromAddr
  });

  return (
    <div>
      <PageHeader
        title="Compliance"
        subtitle="Run canTransact/canTransfer checks with reason codes and clear remediation path."
      />

      <div className="grid gap-4">
        <Card>
          <CardHeader>
            <CardTitle>Checker</CardTitle>
            <CardDescription>Resolve compliance module from token or set it directly.</CardDescription>
          </CardHeader>
          <CardContent className="space-y-3">
            <div className="grid gap-2 md:grid-cols-2">
              <Input value={tokenAddr} onChange={(e) => setTokenAddr(e.target.value)} placeholder="Share token 0x..." />
              <Input value={complianceAddr} onChange={(e) => setComplianceAddr(e.target.value)} placeholder="Compliance module 0x..." />
              <Input value={from} onChange={(e) => setFrom(e.target.value)} placeholder="from / account 0x..." />
              <Input value={to} onChange={(e) => setTo(e.target.value)} placeholder="to 0x..." />
              <Input value={amount} onChange={(e) => setAmount(e.target.value)} placeholder={`amount (${shareSymbol})`} />
            </div>
            <div className="flex flex-wrap items-center gap-2">
              <Badge tone={token ? "good" : "default"}>{token ? "Token OK" : "Token optional"}</Badge>
              <Badge tone={compliance ? "good" : "warn"}>{compliance ? "Compliance resolved" : "Compliance required"}</Badge>
              <Badge tone={fromAddr ? "good" : "warn"}>{fromAddr ? "From OK" : "From invalid"}</Badge>
              <Badge tone={toAddr ? "good" : "warn"}>{toAddr ? "To OK" : "To invalid"}</Badge>
              <Badge tone={parsedAmount ? "good" : "warn"}>
                {parsedAmount ? `Amount ${formatUnits(parsedAmount, shareDecimals)} ${shareSymbol}` : "Amount invalid"}
              </Badge>
            </div>
            <div className="flex flex-wrap items-center gap-2">
              <Button
                variant="secondary"
                onClick={() => {
                  void tokenMeta.refetch();
                  void checks.refetch();
                }}
              >
                Refresh checks
              </Button>
              {onboardingCta ? (
                <a href={onboardingHref} className="rounded-xl border border-border bg-card px-3 py-2 text-sm hover:shadow-soft">
                  Start onboarding
                </a>
              ) : null}
            </div>
          </CardContent>
        </Card>

        {!checks.data ? (
          <Card>
            <CardContent className="pt-6">
              <EmptyState title="No compliance result yet" description="Complete addresses and amount, then refresh checks." />
            </CardContent>
          </Card>
        ) : (
          <>
            <Card>
              <CardHeader>
                <CardTitle>Status</CardTitle>
                <CardDescription>Reason codes from `transactStatus` and `transferStatus`.</CardDescription>
              </CardHeader>
              <CardContent className="space-y-3">
                <div className="flex flex-wrap items-center gap-2">
                  <Badge tone={checks.data.canTransact ? "good" : "bad"}>canTransact: {checks.data.canTransact ? "true" : "false"}</Badge>
                  <Badge tone={checks.data.canTransfer ? "good" : "bad"}>canTransfer: {checks.data.canTransfer ? "true" : "false"}</Badge>
                  <Badge tone={checks.data.paused ? "bad" : "good"}>{checks.data.paused ? "Paused" : "Not paused"}</Badge>
                </div>
                <div className="grid gap-3 md:grid-cols-2">
                  <div className="rounded-xl border border-border/80 bg-muted p-3">
                    <div className="text-xs text-text2">Transact reason</div>
                    <div className="mt-1 text-sm font-semibold">{txReason.label} (code {txReason.code})</div>
                    <div className="mt-1 text-xs text-text2">{txReason.description}</div>
                  </div>
                  <div className="rounded-xl border border-border/80 bg-muted p-3">
                    <div className="text-xs text-text2">Transfer reason</div>
                    <div className="mt-1 text-sm font-semibold">{trReason.label} (code {trReason.code})</div>
                    <div className="mt-1 text-xs text-text2">{trReason.description}</div>
                  </div>
                </div>
              </CardContent>
            </Card>

            <Card>
              <CardHeader>
                <CardTitle>Diagnostics</CardTitle>
                <CardDescription>Explain why account may be blocked and what to fix.</CardDescription>
              </CardHeader>
              <CardContent className="space-y-3">
                <div className="grid gap-2 text-sm md:grid-cols-2">
                  <div className="rounded-xl border border-border/80 bg-card p-3">
                    <div className="text-xs text-text2">From</div>
                    <div className="mt-1 font-mono text-xs">{fromAddr ? shortAddr(fromAddr, 6) : "-"}</div>
                    <div className="mt-2 flex flex-wrap gap-2">
                      <Badge tone={checks.data.fromFlags.exempt ? "accent" : "default"}>Exempt {checks.data.fromFlags.exempt ? "yes" : "no"}</Badge>
                      <Badge tone={checks.data.fromFlags.denylisted ? "bad" : "good"}>Denylisted {checks.data.fromFlags.denylisted ? "yes" : "no"}</Badge>
                      <Badge tone={checks.data.fromFlags.sanctioned ? "bad" : "good"}>Sanctioned {checks.data.fromFlags.sanctioned ? "yes" : "no"}</Badge>
                    </div>
                    <div className="mt-2 text-xs text-text2">
                      Identity: provider={checks.data.fromIdentity.providerId}, jurisdiction={checks.data.fromIdentity.jurisdiction}, tier={checks.data.fromIdentity.tier}
                    </div>
                    <div className="mt-1 text-xs text-text2">
                      Expiry={fromTs(checks.data.fromIdentity.expiry)}, lockupUntil={fromTs(checks.data.fromIdentity.lockupUntil)}
                    </div>
                  </div>
                  <div className="rounded-xl border border-border/80 bg-card p-3">
                    <div className="text-xs text-text2">To</div>
                    <div className="mt-1 font-mono text-xs">{toAddr ? shortAddr(toAddr, 6) : "-"}</div>
                    <div className="mt-2 flex flex-wrap gap-2">
                      <Badge tone={checks.data.toFlags.exempt ? "accent" : "default"}>Exempt {checks.data.toFlags.exempt ? "yes" : "no"}</Badge>
                      <Badge tone={checks.data.toFlags.denylisted ? "bad" : "good"}>Denylisted {checks.data.toFlags.denylisted ? "yes" : "no"}</Badge>
                      <Badge tone={checks.data.toFlags.sanctioned ? "bad" : "good"}>Sanctioned {checks.data.toFlags.sanctioned ? "yes" : "no"}</Badge>
                    </div>
                    <div className="mt-2 text-xs text-text2">
                      Identity: provider={checks.data.toIdentity.providerId}, jurisdiction={checks.data.toIdentity.jurisdiction}, tier={checks.data.toIdentity.tier}
                    </div>
                    <div className="mt-1 text-xs text-text2">
                      Expiry={fromTs(checks.data.toIdentity.expiry)}, lockupUntil={fromTs(checks.data.toIdentity.lockupUntil)}
                    </div>
                  </div>
                </div>
                {checks.data.identityModule && checks.data.identityModule !== zeroAddress ? (
                  <div className="text-xs text-text2">
                    Identity module: <span className="font-mono text-text">{checks.data.identityModule}</span>
                  </div>
                ) : (
                  <div className="text-xs text-warn">Identity module unavailable from compliance contract.</div>
                )}
                {onboardingCta ? (
                  <div className="flex flex-wrap items-center gap-2">
                    <Badge tone="warn">Identity onboarding required</Badge>
                    <a href={onboardingHref} className="rounded-xl border border-border bg-card px-3 py-2 text-sm hover:shadow-soft">
                      Go to onboarding
                    </a>
                  </div>
                ) : null}
              </CardContent>
            </Card>
          </>
        )}
      </div>
    </div>
  );
}
