"use client";

import { PageHeader } from "@/components/ui/PageHeader";
import { useCampaigns } from "@/hooks/useCampaigns";
import { Skeleton } from "@/components/ui/Skeleton";
import { ErrorState } from "@/components/ui/ErrorState";
import { EmptyState } from "@/components/ui/EmptyState";
import { CampaignCard } from "@/components/campaign/CampaignCard";

export default function CampaignsPage() {
  const campaigns = useCampaigns();

  const loading = campaigns.isLoading;
  const err = campaigns.error;

  return (
    <div>
      <PageHeader title="Campaigns" subtitle="Discovered from on-chain logs (or demo dataset)." />

      {loading ? (
        <div className="grid gap-3 md:grid-cols-2">
          <Skeleton className="h-32" />
          <Skeleton className="h-32" />
          <Skeleton className="h-32" />
          <Skeleton className="h-32" />
        </div>
      ) : err ? (
        <ErrorState
          title="Failed to load campaigns"
          description={(err as any)?.message}
          onRetry={() => {
            campaigns.refetch();
          }}
        />
      ) : (campaigns.data?.length ?? 0) === 0 ? (
        <EmptyState
          title="No campaigns found"
          description="If you just deployed, make sure CampaignDeployed events exist (factory mode) or CampaignCreated events (legacy mode), and your .env.local is set."
          ctaLabel="Retry"
          onCta={() => {
            campaigns.refetch();
          }}
        />
      ) : (
        <div className="grid gap-3 md:grid-cols-2">
          {campaigns.data!.map((c) => (
            <CampaignCard key={c.campaignId} c={c} />
          ))}
        </div>
      )}
    </div>
  );
}
