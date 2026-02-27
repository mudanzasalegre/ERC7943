"use client";

import { useQuery } from "@tanstack/react-query";
import { useChainId, usePublicClient } from "wagmi";
import { getPublicEnv } from "@/lib/env";
import { resolveAddressesForChain } from "@/lib/addresses";
import {
  DISCOVERY_REFETCH_INTERVAL_MS,
  DISCOVERY_STALE_TIME_MS,
  fetchCampaignStack,
  normalizeCampaignId,
  type CampaignStack
} from "@/lib/campaignDiscovery";

export function useCampaignStack(campaignId?: string) {
  const chainId = useChainId();
  const client = usePublicClient();
  const env = getPublicEnv();
  const addresses = resolveAddressesForChain(chainId, env);
  const normalizedCampaignId = normalizeCampaignId(campaignId);

  return useQuery({
    queryKey: [
      "campaignStack",
      chainId,
      addresses.campaignFactory ?? "none",
      normalizedCampaignId ?? "none"
    ],
    enabled: Boolean(client && addresses.campaignFactory && normalizedCampaignId),
    staleTime: DISCOVERY_STALE_TIME_MS,
    refetchInterval: DISCOVERY_REFETCH_INTERVAL_MS,
    queryFn: async (): Promise<CampaignStack | undefined> => {
      if (!client || !addresses.campaignFactory || !normalizedCampaignId) return undefined;

      return fetchCampaignStack({
        client,
        factoryAddress: addresses.campaignFactory,
        campaignId: normalizedCampaignId
      });
    }
  });
}
