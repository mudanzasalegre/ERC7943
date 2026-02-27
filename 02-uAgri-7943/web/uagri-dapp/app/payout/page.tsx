"use client";

import * as React from "react";
import { useQuery } from "@tanstack/react-query";
import { encodePacked, formatUnits, isAddress, keccak256, parseUnits, toHex } from "viem";
import { useAccount, useChainId, usePublicClient, useSignTypedData } from "wagmi";
import { PageHeader } from "@/components/ui/PageHeader";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { Button } from "@/components/ui/Button";
import { Badge } from "@/components/ui/Badge";
import { EmptyState } from "@/components/ui/EmptyState";
import { MobileStickyBar } from "@/components/ui/MobileStickyBar";
import { complianceAbi, distributionAbi, erc20AllowanceAbi, erc20DecimalsAbi, shareTokenAbi, yieldAccumulatorAbi } from "@/lib/abi";
import { shortAddr, shortHex32 } from "@/lib/format";

const B32_ZERO = ("0x" + "00".repeat(32)) as `0x${string}`;
const B32_RE = /^0x[0-9a-fA-F]{64}$/u;
const UINT64_MAX = 2n ** 64n - 1n;

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

function queryHref(path: string, params: Record<string, string | undefined>): string {
  const q = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) {
    if (!v) continue;
    q.set(k, v);
  }
  const qs = q.toString();
  return qs ? `${path}?${qs}` : path;
}

export default function PayoutPage() {
  const chainId = useChainId();
  const client = usePublicClient();
  const { address, isConnected } = useAccount();
  const { signTypedDataAsync, isPending: isSigning } = useSignTypedData();

  const [distributionAddr, setDistributionAddr] = React.useState<string>("");
  const [to, setTo] = React.useState<string>("");
  const [maxAmount, setMaxAmount] = React.useState<string>("0");
  const [deadline, setDeadline] = React.useState<string>(() => String(Math.floor(Date.now() / 1000) + 3600));
  const [ref, setRef] = React.useState<string>(B32_ZERO);
  const [payoutRailHash, setPayoutRailHash] = React.useState<string>(B32_ZERO);
  const [signature, setSignature] = React.useState<string>("");
  const [signedAt, setSignedAt] = React.useState<number | null>(null);
  const [signError, setSignError] = React.useState<string>("");

  const [userRef, setUserRef] = React.useState<string>("");
  const [refTimestamp, setRefTimestamp] = React.useState<string>(() => String(Math.floor(Date.now() / 1000)));
  const [railText, setRailText] = React.useState<string>("");

  React.useEffect(() => {
    if (typeof window === "undefined") return;
    const q = new URLSearchParams(window.location.search).get("addr") ?? "";
    if (q && canAddr(q) && !distributionAddr) setDistributionAddr(q);
  }, [distributionAddr]);

  React.useEffect(() => {
    if (!address) return;
    if (!to) setTo(address);
  }, [address, to]);

  const distribution = canAddr(distributionAddr) ? distributionAddr : undefined;
  const toAddr = canAddr(to) ? to : undefined;
  const parsedDeadline = parseUint64(deadline);
  const parsedRef = isBytes32(ref) ? (ref.trim() as `0x${string}`) : undefined;
  const parsedRailHash = isBytes32(payoutRailHash) ? (payoutRailHash.trim() as `0x${string}`) : undefined;

  const distributionMeta = useQuery({
    queryKey: ["payoutDistributionMeta", distribution],
    enabled: !!client && !!distribution,
    queryFn: async () => {
      if (!client || !distribution) {
        return { campaignId: undefined, rewardToken: undefined, shareToken: undefined, enforceComplianceOnClaim: false };
      }
      const [campaignId, rewardToken, shareToken, enforceComplianceOnClaim] = await Promise.all([
        client.readContract({ address: distribution, abi: yieldAccumulatorAbi, functionName: "campaignId" }).catch(() => undefined),
        client.readContract({ address: distribution, abi: yieldAccumulatorAbi, functionName: "rewardToken" }).catch(() => undefined),
        client.readContract({ address: distribution, abi: yieldAccumulatorAbi, functionName: "shareToken" }).catch(() => undefined),
        client.readContract({ address: distribution, abi: yieldAccumulatorAbi, functionName: "enforceComplianceOnClaim" }).catch(() => false)
      ]);
      return {
        campaignId: campaignId as `0x${string}` | undefined,
        rewardToken: rewardToken as `0x${string}` | undefined,
        shareToken: shareToken as `0x${string}` | undefined,
        enforceComplianceOnClaim: Boolean(enforceComplianceOnClaim)
      };
    }
  });

  const complianceModule = useQuery({
    queryKey: ["payoutComplianceModule", distributionMeta.data?.shareToken],
    enabled: !!client && !!distributionMeta.data?.shareToken,
    queryFn: async () => {
      if (!client || !distributionMeta.data?.shareToken) return undefined;
      return client.readContract({
        address: distributionMeta.data.shareToken,
        abi: shareTokenAbi,
        functionName: "complianceModule"
      }).catch(() => undefined) as Promise<`0x${string}` | undefined>;
    }
  });

  const compliancePrecheck = useQuery({
    queryKey: ["payoutComplianceCheck", complianceModule.data ?? "none", address ?? "none"],
    enabled: !!client && !!complianceModule.data && !!address && !!distributionMeta.data?.enforceComplianceOnClaim,
    queryFn: async () => {
      if (!client || !complianceModule.data || !address) return true;
      return Boolean(
        await client.readContract({
          address: complianceModule.data,
          abi: complianceAbi,
          functionName: "canTransact",
          args: [address]
        }).catch(() => false)
      );
    }
  });

  const rewardMeta = useQuery({
    queryKey: ["payoutRewardMeta", distributionMeta.data?.rewardToken],
    enabled: !!client && !!distributionMeta.data?.rewardToken,
    queryFn: async () => {
      if (!client || !distributionMeta.data?.rewardToken) return { symbol: "RWD", decimals: 18 };
      const token = distributionMeta.data.rewardToken;
      const [symbol, decimals] = await Promise.all([
        client.readContract({ address: token, abi: erc20AllowanceAbi, functionName: "symbol" }).catch(() => "RWD"),
        client.readContract({ address: token, abi: erc20DecimalsAbi, functionName: "decimals" }).catch(() => 18)
      ]);
      return {
        symbol: String(symbol || "RWD"),
        decimals: Number(decimals ?? 18)
      };
    }
  });

  const pending = useQuery({
    queryKey: ["payoutPending", distribution, address],
    enabled: !!client && !!distribution && !!address,
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

  const refUsed = useQuery({
    queryKey: ["payoutRefUsed", distribution, parsedRef ?? "none"],
    enabled: !!client && !!distribution && !!parsedRef,
    queryFn: async () => {
      if (!client || !distribution || !parsedRef) return false;
      return Boolean(
        await client.readContract({
          address: distribution,
          abi: yieldAccumulatorAbi,
          functionName: "usedPayoutRef",
          args: [parsedRef]
        }).catch(() => false)
      );
    }
  });

  const rewardSymbol = rewardMeta.data?.symbol ?? "RWD";
  const rewardDecimals = rewardMeta.data?.decimals ?? 18;
  const parsedMaxAmount = parseAmount(maxAmount, rewardDecimals);

  const builtRef = React.useMemo(() => {
    const campaignId = distributionMeta.data?.campaignId;
    const ts = parseUint64(refTimestamp);
    const label = userRef.trim();
    if (!campaignId || !ts || !label) return "";
    return keccak256(encodePacked(["string", "uint64", "bytes32"], [label, ts, campaignId]));
  }, [userRef, refTimestamp, distributionMeta.data?.campaignId]);

  const builtRailHash = React.useMemo(() => {
    const t = railText.trim();
    if (!t) return "";
    return keccak256(toHex(t));
  }, [railText]);

  const digest = useQuery({
    queryKey: [
      "payoutDigest",
      distribution,
      address ?? "none",
      toAddr ?? "none",
      parsedMaxAmount?.toString() ?? "none",
      parsedDeadline?.toString() ?? "none",
      parsedRef ?? "none",
      parsedRailHash ?? "none"
    ],
    enabled:
      !!client &&
      !!distribution &&
      !!address &&
      !!toAddr &&
      !!parsedMaxAmount &&
      !!parsedDeadline &&
      !!parsedRef &&
      !!parsedRailHash,
    queryFn: async () => {
      if (!client || !distribution || !address || !toAddr || !parsedMaxAmount || !parsedDeadline || !parsedRef || !parsedRailHash) {
        return undefined;
      }
      return client.readContract({
        address: distribution,
        abi: yieldAccumulatorAbi,
        functionName: "hashPayoutClaim",
        args: [address, toAddr, parsedMaxAmount, parsedDeadline, parsedRef, parsedRailHash]
      }) as Promise<`0x${string}`>;
    }
  });

  React.useEffect(() => {
    setSignature("");
    setSignedAt(null);
    setSignError("");
  }, [distribution, address, to, maxAmount, deadline, ref, payoutRailHash]);

  const inputErrors: string[] = [];
  if (!distribution) inputErrors.push("Distribution required");
  if (!isConnected || !address) inputErrors.push("Connect wallet");
  if (!toAddr) inputErrors.push("Destination address invalid");
  if (!parsedMaxAmount || parsedMaxAmount <= 0n) inputErrors.push("maxAmount must be > 0");
  if (!parsedDeadline) inputErrors.push("Deadline must be uint64");
  if (!parsedRef) inputErrors.push("ref must be bytes32");
  if (parsedRef && parsedRef.toLowerCase() === B32_ZERO) inputErrors.push("ref cannot be zero");
  if (refUsed.data) inputErrors.push("ref already used");
  if (!parsedRailHash) inputErrors.push("payoutRailHash must be bytes32");
  if (parsedRailHash && parsedRailHash.toLowerCase() === B32_ZERO) inputErrors.push("payoutRailHash cannot be zero");
  if (distributionMeta.data?.enforceComplianceOnClaim && compliancePrecheck.data === false) inputErrors.push("Compliance denied");
  const complianceBlocked = Boolean(distributionMeta.data?.enforceComplianceOnClaim && compliancePrecheck.data === false);
  const complianceHref = queryHref("/compliance", {
    token: distributionMeta.data?.shareToken,
    compliance: complianceModule.data,
    from: address,
    to: address,
    amount: "1"
  });
  const onboardingHref = queryHref("/onboarding", {
    token: distributionMeta.data?.shareToken,
    compliance: complianceModule.data,
    account: address
  });

  const onSign = async () => {
    if (!distribution || !address || !toAddr || !parsedMaxAmount || !parsedDeadline || !parsedRef || !parsedRailHash) return;
    setSignError("");
    try {
      const sig = await signTypedDataAsync({
        domain: {
          name: "uAgri Payout",
          version: "1",
          chainId,
          verifyingContract: distribution
        },
        types: {
          ClaimToWithSig: [
            { name: "account", type: "address" },
            { name: "to", type: "address" },
            { name: "maxAmount", type: "uint256" },
            { name: "deadline", type: "uint64" },
            { name: "ref", type: "bytes32" },
            { name: "payoutRailHash", type: "bytes32" }
          ]
        },
        primaryType: "ClaimToWithSig",
        message: {
          account: address,
          to: toAddr,
          maxAmount: parsedMaxAmount,
          deadline: parsedDeadline,
          ref: parsedRef,
          payoutRailHash: parsedRailHash
        }
      } as any);
      setSignature(sig);
      setSignedAt(Date.now());
    } catch (error: any) {
      setSignError(error?.shortMessage || error?.message || "Signature failed");
    }
  };

  const payload = React.useMemo(() => {
    if (!distribution || !address || !toAddr || !parsedMaxAmount || !parsedDeadline || !parsedRef || !parsedRailHash || !signature) {
      return null;
    }
    return {
      type: "uagri.payout.claimToWithSig.v1",
      distribution,
      chainId,
      account: address,
      to: toAddr,
      maxAmountInput: maxAmount,
      maxAmountWei: parsedMaxAmount.toString(),
      deadline: parsedDeadline.toString(),
      ref: parsedRef,
      payoutRailHash: parsedRailHash,
      signature,
      digest: digest.data ?? null,
      createdAt: signedAt ?? Date.now()
    };
  }, [distribution, address, toAddr, parsedMaxAmount, parsedDeadline, parsedRef, parsedRailHash, signature, maxAmount, chainId, digest.data, signedAt]);

  const payloadJson = payload ? JSON.stringify(payload, null, 2) : "";

  return (
    <div className="pb-36 md:pb-0">
      <PageHeader
        title="Payout"
        subtitle="Generate EIP-712 signature for off-ramp claim and share payload with operator."
      />

      <div className="grid gap-4">
        <Card>
          <CardHeader>
            <CardTitle>Claim Signature</CardTitle>
            <CardDescription>Sign `ClaimToWithSig` for a payout operator to execute on-chain.</CardDescription>
          </CardHeader>
          <CardContent className="space-y-3">
            <div className="grid gap-2 md:grid-cols-2">
              <Input value={distributionAddr} onChange={(e) => setDistributionAddr(e.target.value)} placeholder="Distribution (YieldAccumulator) 0x..." />
              <Input value={to} onChange={(e) => setTo(e.target.value)} placeholder="to (destination wallet) 0x..." />
              <Input value={maxAmount} onChange={(e) => setMaxAmount(e.target.value)} placeholder={`maxAmount (${rewardSymbol})`} />
              <Input value={deadline} onChange={(e) => setDeadline(e.target.value)} placeholder="deadline (unix, uint64)" />
              <Input value={ref} onChange={(e) => setRef(e.target.value)} placeholder="ref bytes32 (non-zero)" />
              <Input value={payoutRailHash} onChange={(e) => setPayoutRailHash(e.target.value)} placeholder="payoutRailHash bytes32 (non-zero)" />
            </div>

            <div className="flex flex-wrap items-center gap-2">
              <Badge tone={distribution ? "good" : "warn"}>{distribution ? "Distribution OK" : "Distribution missing"}</Badge>
              <Badge tone={refUsed.data ? "bad" : "good"}>{refUsed.data ? "ref used" : "ref unused"}</Badge>
              <Badge tone={pending.data && pending.data > 0n ? "good" : "default"}>
                Pending: {pending.isLoading ? "..." : `${fmtAmount(pending.data ?? 0n, rewardDecimals)} ${rewardSymbol}`}
              </Badge>
              <Badge tone={signature ? "good" : "default"}>{signature ? "Signed" : "Not signed"}</Badge>
              {distributionMeta.data?.enforceComplianceOnClaim ? (
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
              <div>CampaignId: {distributionMeta.data?.campaignId ? shortHex32(distributionMeta.data.campaignId) : "-"}</div>
              <div>Reward token: {distributionMeta.data?.rewardToken ? shortAddr(distributionMeta.data.rewardToken, 6) : "-"}</div>
              <div>Share token: {distributionMeta.data?.shareToken ? shortAddr(distributionMeta.data.shareToken, 6) : "-"}</div>
              <div>Compliance: {complianceModule.data ? shortAddr(complianceModule.data, 6) : "-"}</div>
              <div>Digest: {digest.data ? shortHex32(digest.data) : "-"}</div>
              <div>Signed at: {signedAt ? new Date(signedAt).toLocaleString() : "-"}</div>
            </div>

            <div className="flex flex-wrap items-center gap-2">
              <Button onClick={onSign} disabled={isSigning || inputErrors.length > 0}>
                {isSigning ? "Signing..." : "Sign claim payload"}
              </Button>
              <Button
                variant="secondary"
                onClick={() => navigator.clipboard.writeText(payloadJson)}
                disabled={!payload}
              >
                Copy payload
              </Button>
              <Button
                variant="secondary"
                onClick={() => navigator.clipboard.writeText(signature)}
                disabled={!signature}
              >
                Copy signature
              </Button>
            </div>

            {signError ? <div className="rounded-xl border border-bad/30 bg-bad/10 p-3 text-sm text-bad">{signError}</div> : null}

            {inputErrors.length > 0 ? (
              <div className="flex flex-wrap gap-2">
                {inputErrors.map((e) => (
                  <Badge key={e} tone="warn">{e}</Badge>
                ))}
              </div>
            ) : null}

            {payload ? (
              <pre className="overflow-x-auto rounded-xl border border-border/80 bg-muted p-3 text-xs">{payloadJson}</pre>
            ) : (
              <EmptyState title="No payload yet" description="Fill inputs and sign to generate payload JSON." />
            )}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Helpers</CardTitle>
            <CardDescription>Build `ref` and `payoutRailHash` quickly from plain text inputs.</CardDescription>
          </CardHeader>
          <CardContent className="space-y-3">
            <div className="grid gap-2 md:grid-cols-[1fr_auto]">
              <Input value={userRef} onChange={(e) => setUserRef(e.target.value)} placeholder="userRef (invoice / ticket / off-ramp id)" />
              <Button variant="secondary" onClick={() => setRefTimestamp(String(Math.floor(Date.now() / 1000)))}>
                Now
              </Button>
            </div>
            <Input value={refTimestamp} onChange={(e) => setRefTimestamp(e.target.value)} placeholder="ref timestamp (unix, uint64)" />
            <Input value={builtRef} readOnly placeholder="keccak(userRef + timestamp + campaignId)" />
            <div className="flex flex-wrap items-center gap-2">
              <Button variant="secondary" onClick={() => builtRef && setRef(builtRef)} disabled={!builtRef}>
                Use built ref
              </Button>
            </div>

            <Input value={railText} onChange={(e) => setRailText(e.target.value)} placeholder="rail text (bank transfer id / wire id)" />
            <Input value={builtRailHash} readOnly placeholder="keccak(rail text)" />
            <div className="flex flex-wrap items-center gap-2">
              <Button variant="secondary" onClick={() => builtRailHash && setPayoutRailHash(builtRailHash)} disabled={!builtRailHash}>
                Use rail hash
              </Button>
            </div>
          </CardContent>
        </Card>
      </div>

      <MobileStickyBar testId="payout-sticky-actions" ariaLabel="Payout sticky actions">
        <div className="grid grid-cols-2 gap-2">
          <Button
            size="sm"
            onClick={onSign}
            disabled={isSigning || inputErrors.length > 0}
            data-testid="payout-sticky-sign"
          >
            {isSigning ? "Signing..." : "Sign claim payload"}
          </Button>
          <Button
            size="sm"
            variant="secondary"
            onClick={() => navigator.clipboard.writeText(payload ? payloadJson : signature)}
            disabled={!payload && !signature}
          >
            {payload ? "Copy payload" : "Copy signature"}
          </Button>
        </div>
      </MobileStickyBar>
    </div>
  );
}
