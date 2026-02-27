"use client";

import * as React from "react";
import { useParams } from "next/navigation";
import { zeroAddress } from "viem";
import { useChainId } from "wagmi";
import { PageHeader } from "@/components/ui/PageHeader";
import { Skeleton } from "@/components/ui/Skeleton";
import { ErrorState } from "@/components/ui/ErrorState";
import { EmptyState } from "@/components/ui/EmptyState";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/Card";
import { Badge } from "@/components/ui/Badge";
import { Tabs, type TabItem } from "@/components/ui/Tabs";
import { CampaignActions } from "@/components/campaign/CampaignActions";
import { CampaignModules } from "@/components/campaign/CampaignModules";
import { CampaignDocsPanel } from "@/components/campaign/CampaignDocsPanel";
import { CampaignActivityPanel } from "@/components/campaign/CampaignActivityPanel";
import { useCampaignDetail } from "@/hooks/useCampaignDetail";
import { useTokenModules } from "@/hooks/useTokenModules";
import { useCampaignActivity } from "@/hooks/useCampaignActivity";
import { useAppMode } from "@/hooks/useAppMode";
import { explorerAddressUrl } from "@/lib/explorer";
import { shortAddr, shortHex32 } from "@/lib/format";

type CampaignTab = "overview" | "invest" | "rewards" | "docs" | "activity";

const STATE_LABEL = ["FUNDING", "ACTIVE", "HARVESTED", "SETTLED", "CLOSED"] as const;

function formatDate(ts: number): string {
  if (!Number.isFinite(ts) || ts <= 0) return "-";
  return new Date(ts * 1000).toLocaleDateString();
}

function stateTone(state: number): "default" | "good" | "warn" | "bad" | "accent" {
  if (state === 0) return "good";
  if (state === 4) return "bad";
  if (state === 1) return "accent";
  return "default";
}

type CampaignPageParams = {
  campaignId?: string | string[];
};

export default function CampaignDetailPage() {
  const chainId = useChainId();
  const mode = useAppMode();
  const params = useParams<CampaignPageParams>();
  const campaignIdRaw = params?.campaignId;
  const campaignId = Array.isArray(campaignIdRaw) ? campaignIdRaw[0] : campaignIdRaw;

  const detail = useCampaignDetail(campaignId);
  const campaign = detail.campaign;
  const token = detail.token;

  const modules = useTokenModules(token);
  const activity = useCampaignActivity(campaign, modules.data);

  const [activeTab, setActiveTab] = React.useState<CampaignTab>("overview");

  React.useEffect(() => {
    setActiveTab("overview");
  }, [campaignId]);

  const activityCount = activity.data?.length ?? 0;

  const tabItems = React.useMemo<TabItem[]>(() => {
    return [
      { value: "overview", label: "Overview" },
      { value: "invest", label: "Invest" },
      { value: "rewards", label: "Rewards" },
      { value: "docs", label: "Docs" },
      {
        value: "activity",
        label: "Activity",
        count: activityCount > 0 ? activityCount : undefined
      }
    ];
  }, [activityCount]);

  if (detail.loading) {
    return (
      <div>
        <PageHeader title="Campaign" subtitle="Loading..." />
        <Skeleton className="h-44" />
        <div className="mt-4 grid gap-3 md:grid-cols-2">
          <Skeleton className="h-40" />
          <Skeleton className="h-40" />
        </div>
      </div>
    );
  }

  if (detail.error) {
    return (
      <div>
        <PageHeader title="Campaign" subtitle="Error" />
        <ErrorState
          title="Failed to load campaign"
          description={(detail.error as any)?.message}
          onRetry={() => location.reload()}
        />
      </div>
    );
  }

  if (!campaign) {
    return (
      <div>
        <PageHeader title="Campaign" subtitle="Not found" />
        <EmptyState
          title="Campaign not found"
          description="Check the URL or wait for discovery to index the deployment events."
          ctaLabel="Back to campaigns"
          onCta={() => {
            window.location.href = "/campaigns";
          }}
        />
      </div>
    );
  }

  const label = STATE_LABEL[campaign.state] ?? "UNKNOWN";
  const docsAddress = modules.data?.documentRegistry ?? campaign.stack?.documentRegistry;
  const traceAddress = modules.data?.trace ?? campaign.stack?.trace;
  const batchAnchorAddress = campaign.stack?.batchAnchor;

  return (
    <div>
      <PageHeader
        title={`Campaign ${shortHex32(campaign.campaignId)}`}
        subtitle={`Plot ${shortHex32(campaign.plotRef)} | State ${label}`}
        right={
          <div className="flex items-center gap-2">
            <Badge tone={stateTone(campaign.state)}>{label}</Badge>
            <Badge tone={mode.mode === "demo" ? "warn" : "good"}>
              {mode.mode === "demo" ? "Demo mode" : "On-chain mode"}
            </Badge>
          </div>
        }
      />

      <Tabs
        ariaLabel="Campaign detail tabs"
        items={tabItems}
        value={activeTab}
        onChange={(v) => setActiveTab(v as CampaignTab)}
      />

      <div className="mt-4">
        {activeTab === "overview" ? (
          <div className="grid gap-4">
            <Card>
              <CardHeader>
                <CardTitle>Overview</CardTitle>
                <CardDescription>
                  Campaign metadata from registry/factory discovery with deterministic demo fallback.
                </CardDescription>
              </CardHeader>
              <CardContent className="grid gap-3 md:grid-cols-2">
                <div className="rounded-xl border border-border bg-muted p-3">
                  <div className="text-xs text-text2">CampaignId</div>
                  <div className="mt-1 break-all font-mono text-sm">{campaign.campaignId}</div>
                </div>

                <div className="rounded-xl border border-border bg-muted p-3">
                  <div className="text-xs text-text2">PlotRef</div>
                  <div className="mt-1 break-all font-mono text-sm">{campaign.plotRef}</div>
                </div>

                <div className="rounded-xl border border-border bg-muted p-3">
                  <div className="text-xs text-text2">Start / End</div>
                  <div className="mt-1 text-sm">
                    {formatDate(campaign.startTs)} to {formatDate(campaign.endTs)}
                  </div>
                </div>

                <div className="rounded-xl border border-border bg-muted p-3">
                  <div className="text-xs text-text2">Funding Cap</div>
                  <div className="mt-1 break-all font-mono text-sm">{campaign.fundingCap.toString()}</div>
                </div>

                <div className="rounded-xl border border-border bg-muted p-3">
                  <div className="text-xs text-text2">Settlement Asset</div>
                  {campaign.settlementAsset === zeroAddress ? (
                    <div className="mt-1 text-sm text-text2">Zero address (demo or unconfigured asset)</div>
                  ) : (
                    <a
                      className="mt-1 inline-flex font-mono text-sm text-primary hover:underline"
                      href={explorerAddressUrl(chainId, campaign.settlementAsset)}
                      target="_blank"
                      rel="noreferrer"
                    >
                      {shortAddr(campaign.settlementAsset, 6)}
                    </a>
                  )}
                </div>

                <div className="rounded-xl border border-border bg-muted p-3">
                  <div className="text-xs text-text2">ShareToken</div>
                  {token ? (
                    <a
                      className="mt-1 inline-flex font-mono text-sm text-primary hover:underline"
                      href={explorerAddressUrl(chainId, token)}
                      target="_blank"
                      rel="noreferrer"
                    >
                      {shortAddr(token, 6)}
                    </a>
                  ) : (
                    <div className="mt-1 text-sm text-text2">Not discovered yet (waiting for stack/module discovery).</div>
                  )}
                </div>
              </CardContent>
            </Card>

            {token ? (
              <CampaignModules token={token} batchAnchorAddress={campaign.stack?.batchAnchor} />
            ) : (
              <EmptyState
                title="Connected modules unavailable"
                description="ShareToken is not resolved yet, so module addresses are not queryable. This can happen right after deployment or in partial wiring states."
                ctaLabel="Retry discovery"
                onCta={() => {
                  location.reload();
                }}
              />
            )}
          </div>
        ) : null}

        {activeTab === "invest" ? (
          token ? (
            <CampaignActions
              token={token}
              campaignId={campaign.campaignId}
              settlementAsset={campaign.settlementAsset}
              shareDecimals={campaign.tokenMeta?.decimals ?? 18}
              showInvest
              showRewards={false}
            />
          ) : (
            <EmptyState
              title="Invest actions unavailable"
              description="ShareToken/SettlementQueue not discovered yet. Once module wiring is available, deposit/redeem requests will appear here."
              ctaLabel="Retry discovery"
              onCta={() => location.reload()}
            />
          )
        ) : null}

        {activeTab === "rewards" ? (
          token ? (
            <CampaignActions
              token={token}
              campaignId={campaign.campaignId}
              settlementAsset={campaign.settlementAsset}
              shareDecimals={campaign.tokenMeta?.decimals ?? 18}
              showInvest={false}
              showRewards
            />
          ) : (
            <EmptyState
              title="Rewards unavailable"
              description="Distribution module is not resolved yet for this campaign."
              ctaLabel="Retry discovery"
              onCta={() => location.reload()}
            />
          )
        ) : null}

        {activeTab === "docs" ? (
          <CampaignDocsPanel
            campaign={campaign}
            documentRegistryAddress={docsAddress}
            traceAddress={traceAddress}
            batchAnchorAddress={batchAnchorAddress}
            loadingAddress={Boolean(token) && modules.isLoading}
          />
        ) : null}

        {activeTab === "activity" ? (
          <CampaignActivityPanel
            campaign={campaign}
            mode={mode.mode}
            query={{
              data: activity.data,
              isLoading: activity.isLoading,
              isError: activity.isError,
              error: activity.error,
              refetch: () => {
                void activity.refetch();
              }
            }}
          />
        ) : null}
      </div>
    </div>
  );
}
