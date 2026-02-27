"use client";

import { useQuery } from "@tanstack/react-query";
import { useChainId, usePublicClient } from "wagmi";
import { getPublicEnv } from "@/lib/env";
import { resolveAddressesForChain } from "@/lib/addresses";
import {
  DISCOVERY_REFETCH_INTERVAL_MS,
  DISCOVERY_STALE_TIME_MS,
  fetchFactoryCampaignIds,
  resolveDiscoveryFromBlock
} from "@/lib/campaignDiscovery";

export function useFactoryCampaignIds() {
  const chainId = useChainId();
  const client = usePublicClient();
  const env = getPublicEnv();
  const addresses = resolveAddressesForChain(chainId, env);

  return useQuery({
    queryKey: [
      "factoryCampaignIds",
      chainId,
      addresses.campaignFactory ?? "none",
      env.NEXT_PUBLIC_DISCOVERY_FROM_BLOCK?.toString() ?? "auto"
    ],
    enabled: Boolean(client && addresses.campaignFactory),
    staleTime: DISCOVERY_STALE_TIME_MS,
    refetchInterval: DISCOVERY_REFETCH_INTERVAL_MS,
    queryFn: async (): Promise<`0x${string}`[]> => {
      if (!client || !addresses.campaignFactory) return [];

      const head = await client.getBlockNumber();
      const fromBlock = resolveDiscoveryFromBlock(head, env.NEXT_PUBLIC_DISCOVERY_FROM_BLOCK);

      return fetchFactoryCampaignIds({
        client,
        factoryAddress: addresses.campaignFactory,
        fromBlock,
        toBlock: head
      });
    }
  });
}
