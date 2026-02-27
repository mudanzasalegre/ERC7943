"use client";

import * as React from "react";
import { useChainId } from "wagmi";
import type { CampaignView } from "@/lib/campaignDiscovery";
import { explorerTxUrl } from "@/lib/explorer";
import { shortHex32 } from "@/lib/format";
import { Badge } from "@/components/ui/Badge";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/Card";
import { EmptyState } from "@/components/ui/EmptyState";
import { ErrorState } from "@/components/ui/ErrorState";
import { Skeleton } from "@/components/ui/Skeleton";
import type { CampaignActivityEvent } from "@/hooks/useCampaignActivity";

type QueryLike = {
  data?: CampaignActivityEvent[];
  isLoading: boolean;
  isError: boolean;
  error: unknown;
  refetch: () => void;
};

const ZERO_B32 = (`0x${"00".repeat(32)}`).toLowerCase();

function fmtTs(ts?: number): string {
  if (!ts || ts <= 0) return "Timestamp unavailable";
  return new Date(ts * 1000).toLocaleString();
}

function sourceTone(source: CampaignActivityEvent["source"]): "default" | "good" | "warn" | "bad" | "accent" {
  if (source === "registry") return "accent";
  if (source === "queue") return "warn";
  if (source === "distribution") return "good";
  if (source === "anchor") return "accent";
  if (source === "docs") return "default";
  return "default";
}

function buildFallbackEvents(campaign: CampaignView): CampaignActivityEvent[] {
  const start = campaign.startTs;
  const end = campaign.endTs;
  const midpoint = Math.floor((start + end) / 2);
  const docsReady = campaign.docsRootHash.toLowerCase() !== ZERO_B32;

  return [
    {
      id: `fallback-distribution-${campaign.campaignId}`,
      source: "distribution",
      event: "RewardsWindow",
      summary: "Rewards and claims appear here after settlement/liquidation events.",
      blockNumber: 0n,
      logIndex: 0,
      timestamp: end + 3_600
    },
    {
      id: `fallback-queue-${campaign.campaignId}`,
      source: "queue",
      event: "QueueMonitoring",
      summary: "Deposit/redeem requests and processing events are tracked in this feed.",
      blockNumber: 0n,
      logIndex: 0,
      timestamp: midpoint
    },
    {
      id: `fallback-docs-${campaign.campaignId}`,
      source: "docs",
      event: "DocsRoot",
      summary: docsReady
        ? `docsRootHash detected (${shortHex32(campaign.docsRootHash)}).`
        : "No docs root anchored yet for this campaign.",
      blockNumber: 0n,
      logIndex: 0,
      timestamp: start + 1_800
    },
    {
      id: `fallback-registry-${campaign.campaignId}`,
      source: "registry",
      event: "CampaignLoaded",
      summary: "Campaign metadata is available. On-chain events will populate automatically when detected.",
      blockNumber: 0n,
      logIndex: 0,
      timestamp: Math.max(1, start - 1_800)
    }
  ];
}

export function CampaignActivityPanel({
  campaign,
  mode,
  query
}: {
  campaign: CampaignView;
  mode: "demo" | "onchain";
  query: QueryLike;
}) {
  const chainId = useChainId();
  const fallback = React.useMemo(() => buildFallbackEvents(campaign), [campaign]);
  const onchainEvents = query.data ?? [];
  const hasOnchain = onchainEvents.length > 0;
  const events = hasOnchain ? onchainEvents : fallback;
  const usingFallback = !query.isLoading && !hasOnchain;

  if (query.isLoading && !hasOnchain) {
    return (
      <Card>
        <CardHeader>
          <CardTitle>Activity</CardTitle>
          <CardDescription>Loading campaign event stream...</CardDescription>
        </CardHeader>
        <CardContent className="space-y-3">
          <Skeleton className="h-16" />
          <Skeleton className="h-16" />
          <Skeleton className="h-16" />
        </CardContent>
      </Card>
    );
  }

  return (
    <div className="grid gap-4">
      {query.isError ? (
        <ErrorState
          title="Could not load on-chain activity"
          description={(query.error as any)?.message ?? "Showing fallback timeline."}
          onRetry={() => query.refetch()}
        />
      ) : null}

      {usingFallback ? (
        <Card>
          <CardContent>
            <div className="text-sm text-text2">
              {mode === "demo"
                ? "Demo mode: showing deterministic timeline until on-chain logs are available."
                : "No relevant RPC logs found yet. Showing fallback timeline for this campaign."}
            </div>
          </CardContent>
        </Card>
      ) : null}

      {events.length === 0 ? (
        <EmptyState
          title="No activity yet"
          description="Important events from registry, settlement queue, rewards, docs and trace will appear here."
        />
      ) : (
        <Card>
          <CardHeader>
            <CardTitle>Campaign Activity</CardTitle>
            <CardDescription>
              {hasOnchain
                ? `Latest ${events.length} on-chain events across registry, queue, rewards, docs and trace modules.`
                : "Fallback activity timeline while event discovery catches up."}
            </CardDescription>
          </CardHeader>
          <CardContent className="space-y-3">
            {events.map((entry) => (
              <div key={entry.id} className="rounded-xl border border-border bg-muted p-3">
                <div className="flex flex-wrap items-center gap-2">
                  <Badge tone={sourceTone(entry.source)}>{entry.source}</Badge>
                  <span className="text-sm font-semibold">{entry.event}</span>
                  {entry.blockNumber > 0n ? (
                    <span className="font-mono text-xs text-text2">block {entry.blockNumber.toString()}</span>
                  ) : null}
                </div>

                <div className="mt-2 text-sm text-text">{entry.summary}</div>

                <div className="mt-2 flex flex-wrap items-center gap-3 text-xs text-text2">
                  <span>{fmtTs(entry.timestamp)}</span>
                  {entry.txHash ? (
                    <a
                      href={explorerTxUrl(chainId, entry.txHash)}
                      className="text-primary hover:underline"
                      target="_blank"
                      rel="noreferrer"
                    >
                      View tx
                    </a>
                  ) : null}
                </div>
              </div>
            ))}
          </CardContent>
        </Card>
      )}
    </div>
  );
}
