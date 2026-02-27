"use client";

import { useQuery } from "@tanstack/react-query";
import { useChainId, usePublicClient } from "wagmi";
import { resolveAddressesForChain } from "@/lib/addresses";
import {
  DISCOVERY_REFETCH_INTERVAL_MS,
  DISCOVERY_STALE_TIME_MS,
  fetchFactoryCampaignIds,
  fetchRegistryCampaignIds,
  getDemoCampaignsView,
  resolveDiscoveryFromBlock,
  type CampaignView
} from "@/lib/campaignDiscovery";
import { uniq } from "@/lib/discovery";
import { getPublicEnv } from "@/lib/env";
import { fetchCampaignDetailsById } from "./useCampaignDetails";

export type { CampaignView } from "@/lib/campaignDiscovery";

export function useCampaigns() {
  const chainId = useChainId();
  const client = usePublicClient();
  const env = getPublicEnv();
  const addresses = resolveAddressesForChain(chainId, env);
  const hasOnchainForChain = Boolean(addresses.campaignFactory || addresses.campaignRegistry);

  return useQuery({
    queryKey: [
      "campaigns",
      chainId,
      addresses.campaignFactory ?? "none",
      addresses.campaignRegistry ?? "none",
      env.NEXT_PUBLIC_DISCOVERY_FROM_BLOCK?.toString() ?? "auto"
    ],
    enabled: !hasOnchainForChain || Boolean(client),
    staleTime: DISCOVERY_STALE_TIME_MS,
    refetchInterval: hasOnchainForChain ? DISCOVERY_REFETCH_INTERVAL_MS : false,
    queryFn: async (): Promise<CampaignView[]> => {
      if (!hasOnchainForChain) {
        return getDemoCampaignsView();
      }

      if (!client) return [];

      const head = await client.getBlockNumber();
      const fromBlock = resolveDiscoveryFromBlock(head, env.NEXT_PUBLIC_DISCOVERY_FROM_BLOCK);

      const discoveredIds: `0x${string}`[] = [];

      if (addresses.campaignFactory) {
        const factoryIds = await fetchFactoryCampaignIds({
          client,
          factoryAddress: addresses.campaignFactory,
          fromBlock,
          toBlock: head
        });
        discoveredIds.push(...factoryIds);
      }

      if (addresses.campaignRegistry) {
        const registryIds = await fetchRegistryCampaignIds({
          client,
          registryAddress: addresses.campaignRegistry,
          fromBlock,
          toBlock: head
        });
        discoveredIds.push(...registryIds);
      }

      const ids = uniq(discoveredIds);
      const campaigns = await Promise.all(
        ids.map((campaignId) =>
          fetchCampaignDetailsById({
            client,
            addresses,
            campaignId
          })
        )
      );

      return campaigns
        .filter((c): c is CampaignView => Boolean(c))
        .sort((a, b) => b.startTs - a.startTs);
    }
  });
}
