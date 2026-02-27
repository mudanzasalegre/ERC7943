"use client";

import * as React from "react";
import { useAccount, useChainId, usePublicClient } from "wagmi";
import { keccak256, toHex, isHex } from "viem";

import { PageHeader } from "@/components/ui/PageHeader";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { Textarea } from "@/components/ui/Textarea";
import { Button } from "@/components/ui/Button";
import { Badge } from "@/components/ui/Badge";
import { Skeleton } from "@/components/ui/Skeleton";
import { ErrorState } from "@/components/ui/ErrorState";
import { EmptyState } from "@/components/ui/EmptyState";

import { campaignFactoryAbi } from "@/lib/abi";
import { resolveAddressesForChain } from "@/lib/addresses";
import { explorerAddressUrl } from "@/lib/explorer";
import { useTx } from "@/hooks/useTx";
import { useCampaigns } from "@/hooks/useCampaigns";

const B32_ZERO = ("0x" + "00".repeat(32)) as `0x${string}`;

type CreateCampaignCfg = any;
type CreateRolesCfg = any;

function toBigInt(v: any, fallback = 0n): bigint {
  try {
    if (typeof v === "bigint") return v;
    if (typeof v === "number") return BigInt(Math.trunc(v));
    if (typeof v === "string") {
      if (v.trim() === "") return fallback;
      return BigInt(v);
    }
    return fallback;
  } catch {
    return fallback;
  }
}

function toNum(v: any, fallback = 0): number {
  const n = typeof v === "string" ? Number(v) : typeof v === "bigint" ? Number(v) : typeof v === "number" ? v : fallback;
  return Number.isFinite(n) ? n : fallback;
}

function toAddr(v: any): `0x${string}` {
  const s = String(v ?? "").trim();
  return (s.startsWith("0x") ? s : "0x") as `0x${string}`;
}

function toBytes32(v: any): `0x${string}` {
  const s = String(v ?? "").trim();
  if (s.startsWith("0x") && s.length === 66) return s as `0x${string}`;
  // If a plain label was provided, hash it.
  if (s && !s.startsWith("0x")) return keccak256(toHex(s)) as `0x${string}`;
  return B32_ZERO;
}

function normalizeCreateArgs(cfg: CreateCampaignCfg, roles: CreateRolesCfg) {
  const campaign = cfg?.campaign ?? {};
  const viewGas = cfg?.viewGas ?? {};

  const normCfg = {
    campaign: {
      campaignId: toBytes32(campaign.campaignId),
      plotRef: toBytes32(campaign.plotRef),
      subPlotId: toBytes32(campaign.subPlotId),
      areaBps: toNum(campaign.areaBps, 10_000),
      startTs: toBigInt(campaign.startTs),
      endTs: toBigInt(campaign.endTs),
      settlementAsset: toAddr(campaign.settlementAsset),
      fundingCap: toBigInt(campaign.fundingCap),
      docsRootHash: toBytes32(campaign.docsRootHash),
      jurisdictionProfile: toBytes32(campaign.jurisdictionProfile),
      state: toNum(campaign.state, 0)
    },

    name: String(cfg?.name ?? "uAgri Campaign"),
    symbol: String(cfg?.symbol ?? "uAGRI"),
    decimals: toNum(cfg?.decimals, 18),

    enforceComplianceOnPay: !!cfg?.enforceComplianceOnPay,
    depositFeeBps: toNum(cfg?.depositFeeBps, 0),
    redeemFeeBps: toNum(cfg?.redeemFeeBps, 0),
    feeRecipient: toAddr(cfg?.feeRecipient),

    allowDepositsWhenActive: cfg?.allowDepositsWhenActive !== false,
    allowRedeemsDuringFunding: !!cfg?.allowRedeemsDuringFunding,
    enforceCustodyFreshOnRedeem: !!cfg?.enforceCustodyFreshOnRedeem,
    depositExactSharesMode: !!cfg?.depositExactSharesMode,

    enableForcedTransfers: !!cfg?.enableForcedTransfers,
    enableCustodyOracle: !!cfg?.enableCustodyOracle,
    enableTrace: !!cfg?.enableTrace,
    enableDocuments: !!cfg?.enableDocuments,
    enableBatchAnchor: !!cfg?.enableBatchAnchor,
    enableDistribution: !!cfg?.enableDistribution,

    rewardToken: toAddr(cfg?.rewardToken),
    enforceComplianceOnClaim: !!cfg?.enforceComplianceOnClaim,
    enableInsurance: !!cfg?.enableInsurance,

    viewGas: {
      complianceGas: toNum(viewGas?.complianceGas, 0),
      disasterGas: toNum(viewGas?.disasterGas, 0),
      freezeGas: toNum(viewGas?.freezeGas, 0),
      custodyGas: toNum(viewGas?.custodyGas, 0),
      extraGas: toNum(viewGas?.extraGas, 0)
    }
  };

  const normRoles = {
    governance: toAddr(roles?.governance),
    guardian: toAddr(roles?.guardian),
    treasuryAdmin: toAddr(roles?.treasuryAdmin),
    complianceOfficer: toAddr(roles?.complianceOfficer),
    farmOperator: toAddr(roles?.farmOperator),
    regulatorEnforcer: toAddr(roles?.regulatorEnforcer),
    disasterAdmin: toAddr(roles?.disasterAdmin),
    oracleUpdater: toAddr(roles?.oracleUpdater),
    custodyAttester: toAddr(roles?.custodyAttester),
    insuranceAdmin: toAddr(roles?.insuranceAdmin)
  };

  return { cfg: normCfg, roles: normRoles };
}

export default function AdminFactoryPage() {
  const chainId = useChainId();
  const chainAddresses = React.useMemo(() => resolveAddressesForChain(chainId), [chainId]);
  const client = usePublicClient();
  const { isConnected } = useAccount();
  const { sendTx } = useTx();

  const campaigns = useCampaigns();

  const [factoryAddr, setFactoryAddr] = React.useState<string>(chainAddresses.campaignFactory ?? "");

  React.useEffect(() => {
    setFactoryAddr(chainAddresses.campaignFactory ?? "");
  }, [chainAddresses.campaignFactory, chainId]);

  const defaultCfg = React.useMemo(
    () => ({
      campaign: {
        campaignId: B32_ZERO,
        plotRef: B32_ZERO,
        subPlotId: B32_ZERO,
        areaBps: 10_000,
        startTs: 0,
        endTs: 0,
        settlementAsset: "0x0000000000000000000000000000000000000000",
        fundingCap: "0",
        docsRootHash: B32_ZERO,
        jurisdictionProfile: B32_ZERO,
        state: 0
      },
      name: "uAgri Campaign",
      symbol: "uAGRI",
      decimals: 18,
      enforceComplianceOnPay: false,
      depositFeeBps: 0,
      redeemFeeBps: 0,
      feeRecipient: "0x0000000000000000000000000000000000000000",
      allowDepositsWhenActive: true,
      allowRedeemsDuringFunding: false,
      enforceCustodyFreshOnRedeem: false,
      depositExactSharesMode: false,
      enableForcedTransfers: false,
      enableCustodyOracle: false,
      enableTrace: true,
      enableDocuments: true,
      enableBatchAnchor: false,
      enableDistribution: false,
      rewardToken: "0x0000000000000000000000000000000000000000",
      enforceComplianceOnClaim: false,
      enableInsurance: false,
      viewGas: {
        complianceGas: 0,
        disasterGas: 0,
        freezeGas: 0,
        custodyGas: 0,
        extraGas: 0
      }
    }),
    []
  );

  const defaultRoles = React.useMemo(
    () => ({
      governance: "0x0000000000000000000000000000000000000000",
      guardian: "0x0000000000000000000000000000000000000000",
      treasuryAdmin: "0x0000000000000000000000000000000000000000",
      complianceOfficer: "0x0000000000000000000000000000000000000000",
      farmOperator: "0x0000000000000000000000000000000000000000",
      regulatorEnforcer: "0x0000000000000000000000000000000000000000",
      disasterAdmin: "0x0000000000000000000000000000000000000000",
      oracleUpdater: "0x0000000000000000000000000000000000000000",
      custodyAttester: "0x0000000000000000000000000000000000000000",
      insuranceAdmin: "0x0000000000000000000000000000000000000000"
    }),
    []
  );

  const [cfgJson, setCfgJson] = React.useState<string>(() => JSON.stringify(defaultCfg, null, 2));
  const [rolesJson, setRolesJson] = React.useState<string>(() => JSON.stringify(defaultRoles, null, 2));

  const [hashText, setHashText] = React.useState<string>("");
  const hashOut = React.useMemo(() => {
    if (!hashText.trim()) return "";
    return keccak256(toHex(hashText.trim()));
  }, [hashText]);

  const applyHashTo = (field: "campaignId" | "plotRef" | "subPlotId") => {
    try {
      const cfg = JSON.parse(cfgJson);
      cfg.campaign = cfg.campaign ?? {};
      cfg.campaign[field] = hashOut;
      setCfgJson(JSON.stringify(cfg, null, 2));
    } catch {
      // ignore
    }
  };

  const createCampaign = async () => {
    const addr = factoryAddr.trim();
    if (!addr.startsWith("0x") || addr.length !== 42) throw new Error("Invalid factory address");
    if (!isHex(addr)) throw new Error("Invalid hex address");

    let cfg: any;
    let roles: any;
    try {
      cfg = JSON.parse(cfgJson);
      roles = JSON.parse(rolesJson);
    } catch {
      throw new Error("Invalid JSON (cfg or roles)");
    }

    const norm = normalizeCreateArgs(cfg, roles);

    await sendTx({
      title: "Create campaign",
      address: addr as any,
      abi: campaignFactoryAbi,
      functionName: "createCampaign",
      args: [norm.cfg, norm.roles]
    } as any);
  };

  return (
    <div>
      <PageHeader title="Admin · Factory" subtitle="Create campaigns and inspect deployed stacks (100% on-chain mapping)." />

      <Card>
        <CardHeader>
          <CardTitle>CampaignFactory</CardTitle>
          <CardDescription>
            Auto-resolved from address book for {chainAddresses.chainName}. You can still paste an address manually.
          </CardDescription>
        </CardHeader>
        <CardContent className="grid gap-2 md:grid-cols-3">
          <Input value={factoryAddr} onChange={(e) => setFactoryAddr(e.target.value)} placeholder="0x… factory address" />
          <div className="flex items-center gap-2">
            <Badge tone={factoryAddr ? "good" : "warn"}>{factoryAddr ? "Configured" : "Missing"}</Badge>
            {factoryAddr && client ? (
              <a
                className="text-sm text-primary underline"
                href={explorerAddressUrl(chainId, factoryAddr as any)}
                target="_blank"
                rel="noreferrer"
              >
                View on explorer
              </a>
            ) : null}
          </div>
          <div className="text-sm text-text2">Chain: {chainId}</div>
        </CardContent>
      </Card>

      <div className="mt-4 grid gap-4 lg:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle>Create campaign</CardTitle>
            <CardDescription>
              Paste cfg/roles JSON. bytes32 fields accept either a 0x…66 hex value or a plain label (we hash it).
            </CardDescription>
          </CardHeader>
          <CardContent className="space-y-3">
            <div className="rounded-xl border border-border bg-muted p-3">
              <div className="text-xs text-text2">Quick bytes32 helper</div>
              <div className="mt-2 grid gap-2 md:grid-cols-2">
                <Input value={hashText} onChange={(e) => setHashText(e.target.value)} placeholder="Type a label (e.g., 'SAGUNTO-2026-Q1')" />
                <Input value={hashOut} readOnly placeholder="keccak256(label)" />
              </div>
              <div className="mt-2 flex flex-wrap gap-2">
                <Button variant="secondary" onClick={() => applyHashTo("campaignId")} disabled={!hashOut}>
                  Apply to campaignId
                </Button>
                <Button variant="secondary" onClick={() => applyHashTo("plotRef")} disabled={!hashOut}>
                  Apply to plotRef
                </Button>
                <Button variant="secondary" onClick={() => applyHashTo("subPlotId")} disabled={!hashOut}>
                  Apply to subPlotId
                </Button>
                <Button
                  variant="ghost"
                  onClick={() => {
                    setCfgJson(JSON.stringify(defaultCfg, null, 2));
                    setRolesJson(JSON.stringify(defaultRoles, null, 2));
                  }}
                >
                  Reset templates
                </Button>
              </div>
            </div>

            <div>
              <div className="mb-1 text-sm font-medium">cfg</div>
              <Textarea value={cfgJson} onChange={(e) => setCfgJson(e.target.value)} className="min-h-[260px] font-mono text-xs" />
            </div>

            <div>
              <div className="mb-1 text-sm font-medium">roles</div>
              <Textarea value={rolesJson} onChange={(e) => setRolesJson(e.target.value)} className="min-h-[220px] font-mono text-xs" />
            </div>

            <div className="flex items-center gap-2">
              <Button onClick={createCampaign} disabled={!isConnected}>
                Create campaign
              </Button>
              {!isConnected ? <Badge tone="warn">Connect wallet</Badge> : null}
            </div>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Deployed campaigns</CardTitle>
            <CardDescription>Discovered from factory logs (CampaignDeployed).</CardDescription>
          </CardHeader>
          <CardContent>
            {campaigns.isLoading ? (
              <div className="grid gap-2">
                <Skeleton className="h-16" />
                <Skeleton className="h-16" />
                <Skeleton className="h-16" />
              </div>
            ) : campaigns.error ? (
              <ErrorState title="Failed to load campaigns" description={(campaigns.error as any)?.message} onRetry={() => campaigns.refetch()} />
            ) : (campaigns.data?.length ?? 0) === 0 ? (
              <EmptyState title="No campaigns yet" description="Deploy at least one campaign to see it here." ctaLabel="Retry" onCta={() => campaigns.refetch()} />
            ) : (
              <div className="space-y-2">
                {campaigns.data!.slice(0, 20).map((c) => (
                  <div key={c.campaignId} className="rounded-xl border border-border bg-card p-3">
                    <div className="flex items-start justify-between gap-3">
                      <div>
                        <div className="text-sm font-semibold">{c.tokenMeta?.symbol ?? "Campaign"}</div>
                        <div className="mt-1 break-all font-mono text-xs text-text2">{c.campaignId}</div>
                      </div>
                      <a className="text-sm text-primary underline" href={`/campaigns/${c.campaignId}`}>
                        Open
                      </a>
                    </div>
                    <div className="mt-2 grid gap-2 md:grid-cols-2">
                      <div className="rounded-lg bg-muted p-2">
                        <div className="text-[11px] text-text2">ShareToken</div>
                        <div className="break-all font-mono text-xs">{c.stack?.shareToken ?? "—"}</div>
                      </div>
                      <div className="rounded-lg bg-muted p-2">
                        <div className="text-[11px] text-text2">SettlementQueue</div>
                        <div className="break-all font-mono text-xs">{c.stack?.settlementQueue ?? "—"}</div>
                      </div>
                    </div>
                  </div>
                ))}
              </div>
            )}
          </CardContent>
        </Card>
      </div>
    </div>
  );
}
