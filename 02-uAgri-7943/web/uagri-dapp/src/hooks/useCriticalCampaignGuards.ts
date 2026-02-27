"use client";

import * as React from "react";
import { useQuery } from "@tanstack/react-query";
import { isAddress, zeroAddress } from "viem";
import { usePublicClient } from "wagmi";
import { disasterViewAbi } from "@/lib/abi";
import {
  DISCOVERY_REFETCH_INTERVAL_MS,
  DISCOVERY_STALE_TIME_MS,
  type CampaignView
} from "@/lib/campaignDiscovery";
import { useCampaigns } from "./useCampaigns";

export type CriticalCampaignGuard = {
  campaignId: `0x${string}`;
  symbol?: string;
  disaster: `0x${string}`;
  restricted: boolean;
  hardFrozen: boolean;
  flags: bigint;
};

type UseCriticalCampaignGuardsOptions = {
  maxCampaigns?: number;
};

export function useCriticalCampaignGuards(options: UseCriticalCampaignGuardsOptions = {}) {
  const client = usePublicClient();
  const campaignsQuery = useCampaigns();
  const maxCampaigns = options.maxCampaigns ?? 24;

  const targets = React.useMemo(
    () =>
      (campaignsQuery.data ?? [])
        .slice(0, maxCampaigns)
        .filter(
          (campaign): campaign is CampaignView & { stack: NonNullable<CampaignView["stack"]> } =>
            Boolean(campaign.stack?.disaster && campaign.stack.disaster !== zeroAddress && isAddress(campaign.stack.disaster))
        ),
    [campaignsQuery.data, maxCampaigns]
  );

  const statusQuery = useQuery({
    queryKey: [
      "criticalCampaignGuards",
      targets.map((t) => `${t.campaignId}:${t.stack!.disaster?.toLowerCase()}`).join("|")
    ],
    enabled: Boolean(client && targets.length > 0),
    staleTime: DISCOVERY_STALE_TIME_MS,
    refetchInterval: DISCOVERY_REFETCH_INTERVAL_MS,
    queryFn: async (): Promise<CriticalCampaignGuard[]> => {
      if (!client || targets.length === 0) return [];

      const checks = await Promise.all(
        targets.map(async (campaign) => {
          const disaster = campaign.stack!.disaster as `0x${string}`;

          const [flagsRaw, restrictedRaw, hardFrozenRaw] = await Promise.all([
            client
              .readContract({
                address: disaster,
                abi: disasterViewAbi,
                functionName: "campaignFlags",
                args: [campaign.campaignId]
              })
              .catch(() => 0n),
            client
              .readContract({
                address: disaster,
                abi: disasterViewAbi,
                functionName: "isRestricted",
                args: [campaign.campaignId]
              })
              .catch(() => false),
            client
              .readContract({
                address: disaster,
                abi: disasterViewAbi,
                functionName: "isHardFrozen",
                args: [campaign.campaignId]
              })
              .catch(() => false)
          ]);

          return {
            campaignId: campaign.campaignId,
            symbol: campaign.tokenMeta?.symbol,
            disaster,
            restricted: Boolean(restrictedRaw),
            hardFrozen: Boolean(hardFrozenRaw),
            flags: BigInt(flagsRaw as bigint)
          } satisfies CriticalCampaignGuard;
        })
      );

      return checks;
    }
  });

  const impacted = React.useMemo(
    () => (statusQuery.data ?? []).filter((x) => x.restricted || x.hardFrozen || x.flags > 0n),
    [statusQuery.data]
  );

  return {
    campaignsQuery,
    statusQuery,
    impacted,
    totalTracked: targets.length
  };
}

