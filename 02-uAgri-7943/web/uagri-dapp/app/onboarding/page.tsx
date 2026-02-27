"use client";

import * as React from "react";
import { useQuery } from "@tanstack/react-query";
import { isAddress } from "viem";
import { useAccount, useChainId, usePublicClient, useSignTypedData } from "wagmi";
import { PageHeader } from "@/components/ui/PageHeader";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { Textarea } from "@/components/ui/Textarea";
import { Button } from "@/components/ui/Button";
import { Badge } from "@/components/ui/Badge";
import { EmptyState } from "@/components/ui/EmptyState";
import { complianceModuleAbi, identityAttestationAbi, shareTokenAbi } from "@/lib/abi";
import { useTx } from "@/hooks/useTx";

const UINT8_MAX = 2n ** 8n - 1n;
const UINT16_MAX = 2n ** 16n - 1n;
const UINT32_MAX = 2n ** 32n - 1n;
const UINT64_MAX = 2n ** 64n - 1n;
const HEX_BYTES_RE = /^0x(?:[0-9a-fA-F]{2})+$/u;

type PayloadStruct = {
  jurisdiction: bigint;
  tier: bigint;
  flags: bigint;
  expiry: bigint;
  lockupUntil: bigint;
  providerId: bigint;
};

function canAddr(v: string): v is `0x${string}` {
  return isAddress(v);
}

function isHexBytes(v: string): v is `0x${string}` {
  return HEX_BYTES_RE.test(v.trim());
}

function parseUInt(v: string, max: bigint): bigint | undefined {
  const raw = v.trim();
  if (!/^\d+$/u.test(raw)) return undefined;
  try {
    const n = BigInt(raw);
    if (n < 0n || n > max) return undefined;
    return n;
  } catch {
    return undefined;
  }
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

export default function OnboardingPage() {
  const chainId = useChainId();
  const client = usePublicClient();
  const { address, isConnected } = useAccount();
  const { sendTx } = useTx();
  const { signTypedDataAsync, isPending: isSigning } = useSignTypedData();

  const [tokenAddr, setTokenAddr] = React.useState("");
  const [complianceAddr, setComplianceAddr] = React.useState("");
  const [identityAddr, setIdentityAddr] = React.useState("");
  const [account, setAccount] = React.useState("");
  const [providerSigner, setProviderSigner] = React.useState("");

  const [jurisdiction, setJurisdiction] = React.useState("0");
  const [tier, setTier] = React.useState("0");
  const [flags, setFlags] = React.useState("0");
  const [expiry, setExpiry] = React.useState(() => String(Math.floor(Date.now() / 1000) + 365 * 24 * 3600));
  const [lockupUntil, setLockupUntil] = React.useState("0");
  const [providerId, setProviderId] = React.useState("1");
  const [deadline, setDeadline] = React.useState(() => String(Math.floor(Date.now() / 1000) + 3600));

  const [signature, setSignature] = React.useState("");
  const [signError, setSignError] = React.useState("");
  const [payloadJson, setPayloadJson] = React.useState("");
  const [payloadError, setPayloadError] = React.useState("");

  React.useEffect(() => {
    if (typeof window === "undefined") return;
    const p = new URLSearchParams(window.location.search);
    const qToken = p.get("token") ?? "";
    const qCompliance = p.get("compliance") ?? "";
    const qIdentity = p.get("identity") ?? "";
    const qAccount = p.get("account") ?? "";
    if (qToken && canAddr(qToken) && !tokenAddr) setTokenAddr(qToken);
    if (qCompliance && canAddr(qCompliance) && !complianceAddr) setComplianceAddr(qCompliance);
    if (qIdentity && canAddr(qIdentity) && !identityAddr) setIdentityAddr(qIdentity);
    if (qAccount && canAddr(qAccount) && !account) setAccount(qAccount);
  }, [account, complianceAddr, identityAddr, tokenAddr]);

  React.useEffect(() => {
    if (!address) return;
    if (!account) setAccount(address);
    if (!providerSigner) setProviderSigner(address);
  }, [address, account, providerSigner]);

  const token = canAddr(tokenAddr) ? tokenAddr : undefined;
  const complianceInput = canAddr(complianceAddr) ? complianceAddr : undefined;
  const identityInput = canAddr(identityAddr) ? identityAddr : undefined;
  const accountAddr = canAddr(account) ? account : undefined;
  const providerSignerAddr = canAddr(providerSigner) ? providerSigner : undefined;
  const parsedJurisdiction = parseUInt(jurisdiction, UINT16_MAX);
  const parsedTier = parseUInt(tier, UINT8_MAX);
  const parsedFlags = parseUInt(flags, UINT32_MAX);
  const parsedExpiry = parseUInt(expiry, UINT64_MAX);
  const parsedLockupUntil = parseUInt(lockupUntil, UINT64_MAX);
  const parsedProviderId = parseUInt(providerId, UINT32_MAX);
  const parsedDeadline = parseUInt(deadline, UINT64_MAX);
  const signatureHex = isHexBytes(signature) ? (signature.trim() as `0x${string}`) : undefined;

  const tokenMeta = useQuery({
    queryKey: ["onboardingTokenMeta", token],
    enabled: !!client && !!token,
    queryFn: async () => {
      if (!client || !token) return { compliance: undefined as `0x${string}` | undefined };
      const compliance = await client.readContract({ address: token, abi: shareTokenAbi, functionName: "complianceModule" }).catch(() => undefined);
      return { compliance: (compliance as `0x${string}` | undefined) ?? undefined };
    }
  });

  const compliance = complianceInput ?? tokenMeta.data?.compliance;

  const complianceMeta = useQuery({
    queryKey: ["onboardingComplianceMeta", compliance],
    enabled: !!client && !!compliance,
    queryFn: async () => {
      if (!client || !compliance) return { identityAttestation: undefined as `0x${string}` | undefined };
      const identityAttestation = await client.readContract({
        address: compliance,
        abi: complianceModuleAbi,
        functionName: "identityAttestation"
      }).catch(() => undefined);
      return { identityAttestation: (identityAttestation as `0x${string}` | undefined) ?? undefined };
    }
  });

  const identity = identityInput ?? complianceMeta.data?.identityAttestation;

  const parsedPayload: PayloadStruct | undefined =
    parsedJurisdiction !== undefined &&
    parsedTier !== undefined &&
    parsedFlags !== undefined &&
    parsedExpiry !== undefined &&
    parsedLockupUntil !== undefined &&
    parsedProviderId !== undefined
      ? {
          jurisdiction: parsedJurisdiction,
          tier: parsedTier,
          flags: parsedFlags,
          expiry: parsedExpiry,
          lockupUntil: parsedLockupUntil,
          providerId: parsedProviderId
        }
      : undefined;

  const nonceData = useQuery({
    queryKey: ["onboardingNonce", identity, accountAddr ?? "none", parsedProviderId?.toString() ?? "none"],
    enabled: !!client && !!identity && !!accountAddr && !!parsedProviderId,
    queryFn: async () => {
      if (!client || !identity || !accountAddr || !parsedProviderId) return 0n;
      return client.readContract({
        address: identity,
        abi: identityAttestationAbi,
        functionName: "nonces",
        args: [accountAddr, Number(parsedProviderId)]
      }) as Promise<bigint>;
    }
  });

  const digestData = useQuery({
    queryKey: [
      "onboardingDigest",
      identity,
      accountAddr ?? "none",
      parsedPayload ? JSON.stringify({
        jurisdiction: parsedPayload.jurisdiction.toString(),
        tier: parsedPayload.tier.toString(),
        flags: parsedPayload.flags.toString(),
        expiry: parsedPayload.expiry.toString(),
        lockupUntil: parsedPayload.lockupUntil.toString(),
        providerId: parsedPayload.providerId.toString()
      }) : "none",
      parsedDeadline?.toString() ?? "none"
    ],
    enabled: !!client && !!identity && !!accountAddr && !!parsedPayload && !!parsedDeadline,
    queryFn: async () => {
      if (!client || !identity || !accountAddr || !parsedPayload || !parsedDeadline) return undefined;
      const [digest, nonce] = await client.readContract({
        address: identity,
        abi: identityAttestationAbi,
        functionName: "hashRegisterWithNonce",
        args: [
          accountAddr,
          {
            jurisdiction: Number(parsedPayload.jurisdiction),
            tier: Number(parsedPayload.tier),
            flags: Number(parsedPayload.flags),
            expiry: parsedPayload.expiry,
            lockupUntil: parsedPayload.lockupUntil,
            providerId: Number(parsedPayload.providerId)
          },
          parsedDeadline
        ]
      }) as [ `0x${string}`, bigint ];
      return { digest, nonce };
    }
  });

  const providerSelfCheck = useQuery({
    queryKey: ["onboardingProviderSelf", identity, parsedProviderId?.toString() ?? "none", address ?? "none"],
    enabled: !!client && !!identity && !!parsedProviderId && !!address,
    queryFn: async () => {
      if (!client || !identity || !parsedProviderId || !address) return false;
      return Boolean(
        await client.readContract({
          address: identity,
          abi: identityAttestationAbi,
          functionName: "isProvider",
          args: [Number(parsedProviderId), address]
        }).catch(() => false)
      );
    }
  });

  const providerFieldCheck = useQuery({
    queryKey: ["onboardingProviderField", identity, parsedProviderId?.toString() ?? "none", providerSignerAddr ?? "none"],
    enabled: !!client && !!identity && !!parsedProviderId && !!providerSignerAddr,
    queryFn: async () => {
      if (!client || !identity || !parsedProviderId || !providerSignerAddr) return false;
      return Boolean(
        await client.readContract({
          address: identity,
          abi: identityAttestationAbi,
          functionName: "isProvider",
          args: [Number(parsedProviderId), providerSignerAddr]
        }).catch(() => false)
      );
    }
  });

  const currentIdentity = useQuery({
    queryKey: ["onboardingCurrentIdentity", identity, accountAddr ?? "none"],
    enabled: !!client && !!identity && !!accountAddr,
    queryFn: async () => {
      if (!client || !identity || !accountAddr) return undefined;
      return client.readContract({
        address: identity,
        abi: identityAttestationAbi,
        functionName: "identityOf",
        args: [accountAddr]
      }).catch(() => undefined) as Promise<any>;
    }
  });

  const inputErrors: string[] = [];
  if (!identity) inputErrors.push("IdentityAttestation required");
  if (!accountAddr) inputErrors.push("Account invalid");
  if (!parsedPayload) inputErrors.push("Payload fields invalid");
  if (!parsedProviderId || parsedProviderId === 0n) inputErrors.push("providerId must be > 0");
  if (!parsedDeadline) inputErrors.push("Deadline must be uint64");
  if (!signatureHex) inputErrors.push("Signature required (0x bytes)");

  const signDisabled =
    !isConnected ||
    !identity ||
    !accountAddr ||
    !parsedPayload ||
    !parsedDeadline ||
    !providerSelfCheck.data;

  const onSign = async () => {
    if (!identity || !accountAddr || !parsedPayload || !parsedDeadline || !nonceData.data) return;
    setSignError("");
    try {
      const sig = await signTypedDataAsync({
        domain: {
          name: "uAgri Identity Attestation",
          version: "1",
          chainId,
          verifyingContract: identity
        },
        types: {
          Register: [
            { name: "account", type: "address" },
            { name: "jurisdiction", type: "uint16" },
            { name: "tier", type: "uint8" },
            { name: "flags", type: "uint32" },
            { name: "expiry", type: "uint64" },
            { name: "lockupUntil", type: "uint64" },
            { name: "providerId", type: "uint32" },
            { name: "nonce", type: "uint256" },
            { name: "deadline", type: "uint64" }
          ]
        },
        primaryType: "Register",
        message: {
          account: accountAddr,
          jurisdiction: Number(parsedPayload.jurisdiction),
          tier: Number(parsedPayload.tier),
          flags: Number(parsedPayload.flags),
          expiry: parsedPayload.expiry,
          lockupUntil: parsedPayload.lockupUntil,
          providerId: Number(parsedPayload.providerId),
          nonce: nonceData.data,
          deadline: parsedDeadline
        }
      } as any);
      setSignature(sig);
    } catch (error: any) {
      setSignError(error?.shortMessage || error?.message || "Sign failed");
    }
  };

  const onSubmit = async () => {
    if (!identity || !accountAddr || !parsedPayload || !parsedDeadline || !signatureHex) return;
    await sendTx({
      title: "Register identity attestation",
      address: identity,
      abi: identityAttestationAbi,
      functionName: "register",
      args: [
        accountAddr,
        {
          jurisdiction: Number(parsedPayload.jurisdiction),
          tier: Number(parsedPayload.tier),
          flags: Number(parsedPayload.flags),
          expiry: parsedPayload.expiry,
          lockupUntil: parsedPayload.lockupUntil,
          providerId: Number(parsedPayload.providerId)
        },
        parsedDeadline,
        signatureHex
      ]
    } as any);
    await Promise.all([nonceData.refetch(), currentIdentity.refetch()]);
  };

  const onLoadPayload = () => {
    setPayloadError("");
    try {
      const p = JSON.parse(payloadJson) as any;
      if (!p || typeof p !== "object") {
        setPayloadError("Payload JSON invalid");
        return;
      }
      if (typeof p.token === "string" && canAddr(p.token)) setTokenAddr(p.token);
      if (typeof p.compliance === "string" && canAddr(p.compliance)) setComplianceAddr(p.compliance);
      if (typeof p.identity === "string" && canAddr(p.identity)) setIdentityAddr(p.identity);
      if (typeof p.account === "string" && canAddr(p.account)) setAccount(p.account);
      if (typeof p.providerSigner === "string" && canAddr(p.providerSigner)) setProviderSigner(p.providerSigner);
      if (typeof p.jurisdiction === "string") setJurisdiction(p.jurisdiction);
      if (typeof p.tier === "string") setTier(p.tier);
      if (typeof p.flags === "string") setFlags(p.flags);
      if (typeof p.expiry === "string") setExpiry(p.expiry);
      if (typeof p.lockupUntil === "string") setLockupUntil(p.lockupUntil);
      if (typeof p.providerId === "string") setProviderId(p.providerId);
      if (typeof p.deadline === "string") setDeadline(p.deadline);
      if (typeof p.signature === "string") setSignature(p.signature);
    } catch (error: any) {
      setPayloadError(error?.message || "Invalid JSON");
    }
  };

  const complianceHref = queryHref("/compliance", {
    token,
    compliance,
    from: accountAddr,
    to: accountAddr,
    amount: "1"
  });

  return (
    <div>
      <PageHeader
        title="Onboarding"
        subtitle="Identity attestation EIP-712 flow: build payload, sign with provider, submit register."
      />

      <div className="grid gap-4">
        <Card>
          <CardHeader>
            <CardTitle>Attestation Setup</CardTitle>
            <CardDescription>No PII: only jurisdiction/tier/flags/expiry/lockup/providerId.</CardDescription>
          </CardHeader>
          <CardContent className="space-y-3">
            <div className="grid gap-2 md:grid-cols-2">
              <Input value={tokenAddr} onChange={(e) => setTokenAddr(e.target.value)} placeholder="Token 0x... (optional)" />
              <Input value={complianceAddr} onChange={(e) => setComplianceAddr(e.target.value)} placeholder="Compliance 0x... (optional)" />
              <Input value={identityAddr} onChange={(e) => setIdentityAddr(e.target.value)} placeholder="IdentityAttestation 0x..." />
              <Input value={account} onChange={(e) => setAccount(e.target.value)} placeholder="Account to onboard 0x..." />
              <Input value={providerSigner} onChange={(e) => setProviderSigner(e.target.value)} placeholder="Provider signer 0x..." />
              <Input value={providerId} onChange={(e) => setProviderId(e.target.value)} placeholder="providerId (uint32)" />
              <Input value={jurisdiction} onChange={(e) => setJurisdiction(e.target.value)} placeholder="jurisdiction (uint16)" />
              <Input value={tier} onChange={(e) => setTier(e.target.value)} placeholder="tier (uint8)" />
              <Input value={flags} onChange={(e) => setFlags(e.target.value)} placeholder="flags (uint32 bitmap)" />
              <Input value={expiry} onChange={(e) => setExpiry(e.target.value)} placeholder="expiry (unix, uint64)" />
              <Input value={lockupUntil} onChange={(e) => setLockupUntil(e.target.value)} placeholder="lockupUntil (unix, uint64)" />
              <Input value={deadline} onChange={(e) => setDeadline(e.target.value)} placeholder="deadline (unix, uint64)" />
            </div>

            <div className="flex flex-wrap items-center gap-2">
              <Badge tone={identity ? "good" : "warn"}>{identity ? "Identity module resolved" : "Identity module required"}</Badge>
              <Badge tone={accountAddr ? "good" : "warn"}>{accountAddr ? "Account OK" : "Account invalid"}</Badge>
              <Badge tone={providerSelfCheck.data ? "good" : "warn"}>
                {providerSelfCheck.data ? "Connected wallet is provider" : "Connected wallet not provider"}
              </Badge>
              <Badge tone={providerFieldCheck.data ? "good" : "warn"}>
                {providerFieldCheck.data ? "Provider signer allowlisted" : "Provider signer not allowlisted"}
              </Badge>
              <Badge tone={nonceData.data !== undefined ? "good" : "default"}>Nonce: {nonceData.data?.toString() ?? "-"}</Badge>
            </div>

            <div className="grid gap-2 md:grid-cols-[1fr_auto]">
              <Textarea value={payloadJson} onChange={(e) => setPayloadJson(e.target.value)} placeholder="Optional payload JSON to load values" className="min-h-[110px]" />
              <div className="flex flex-col gap-2">
                <Button variant="secondary" onClick={onLoadPayload}>Load payload</Button>
                <Button variant="secondary" onClick={() => navigator.clipboard.writeText(JSON.stringify({
                  token: token ?? "",
                  compliance: compliance ?? "",
                  identity: identity ?? "",
                  account: accountAddr ?? "",
                  providerSigner: providerSignerAddr ?? "",
                  jurisdiction,
                  tier,
                  flags,
                  expiry,
                  lockupUntil,
                  providerId,
                  deadline,
                  signature
                }, null, 2))}>
                  Copy payload
                </Button>
              </div>
            </div>
            {payloadError ? <div className="rounded-xl border border-bad/30 bg-bad/10 p-3 text-sm text-bad">{payloadError}</div> : null}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Signature + Submit</CardTitle>
            <CardDescription>Sign EIP-712 `Register` and call `register(account, payload, deadline, sig)`.</CardDescription>
          </CardHeader>
          <CardContent className="space-y-3">
            <Textarea value={signature} onChange={(e) => setSignature(e.target.value)} placeholder="Provider signature (0x...)" className="min-h-[90px]" />
            <div className="grid gap-2 text-xs text-text2 md:grid-cols-2">
              <div>Digest: <span className="font-mono text-text">{digestData.data?.digest ?? "-"}</span></div>
              <div>Digest nonce: <span className="font-mono text-text">{digestData.data?.nonce?.toString() ?? "-"}</span></div>
              <div>Current nonce: <span className="font-mono text-text">{nonceData.data?.toString() ?? "-"}</span></div>
              <div>Deadline: <span className="font-mono text-text">{deadline}</span></div>
            </div>

            <div className="flex flex-wrap items-center gap-2">
              <Button onClick={onSign} disabled={signDisabled || isSigning}>
                {isSigning ? "Signing..." : "Sign with connected provider"}
              </Button>
              <Button onClick={onSubmit} disabled={inputErrors.length > 0}>
                submit attestation
              </Button>
              <Button variant="secondary" onClick={() => navigator.clipboard.writeText(signature)} disabled={!signatureHex}>
                Copy signature
              </Button>
              <a href={complianceHref} className="rounded-xl border border-border bg-card px-3 py-2 text-sm hover:shadow-soft">
                Check compliance
              </a>
            </div>

            {signError ? <div className="rounded-xl border border-bad/30 bg-bad/10 p-3 text-sm text-bad">{signError}</div> : null}
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
            <CardTitle>Current Identity</CardTitle>
            <CardDescription>Latest on-chain payload for account after registration.</CardDescription>
          </CardHeader>
          <CardContent>
            {!currentIdentity.data ? (
              <EmptyState title="No identity payload found" description="Submit attestation to create/update identity payload." />
            ) : (
              <div className="grid gap-2 rounded-xl border border-border/80 bg-muted p-3 text-sm md:grid-cols-2">
                <div>providerId: {String((currentIdentity.data as any)?.providerId ?? (currentIdentity.data as any)?.[5] ?? 0)}</div>
                <div>jurisdiction: {String((currentIdentity.data as any)?.jurisdiction ?? (currentIdentity.data as any)?.[0] ?? 0)}</div>
                <div>tier: {String((currentIdentity.data as any)?.tier ?? (currentIdentity.data as any)?.[1] ?? 0)}</div>
                <div>flags: {String((currentIdentity.data as any)?.flags ?? (currentIdentity.data as any)?.[2] ?? 0)}</div>
                <div>expiry: {String((currentIdentity.data as any)?.expiry ?? (currentIdentity.data as any)?.[3] ?? 0)}</div>
                <div>lockupUntil: {String((currentIdentity.data as any)?.lockupUntil ?? (currentIdentity.data as any)?.[4] ?? 0)}</div>
              </div>
            )}
          </CardContent>
        </Card>
      </div>
    </div>
  );
}
