"use client";

import { useQuery } from "@tanstack/react-query";
import { zeroAddress } from "viem";
import { useChainId, usePublicClient } from "wagmi";
import type { AddressBook } from "@/lib/addresses";
import { resolveAddressesForChain } from "@/lib/addresses";
import {
  DISCOVERY_REFETCH_INTERVAL_MS,
  DISCOVERY_STALE_TIME_MS,
  fetchCampaignFromRegistry,
  fetchCampaignStack,
  fetchShareTokenMeta,
  getDemoCampaignViewById,
  normalizeCampaignId,
  type CampaignView
} from "@/lib/campaignDiscovery";
import { getPublicEnv } from "@/lib/env";

export async function fetchCampaignDetailsById(args: {
  client: any;
  addresses: AddressBook;
  campaignId: `0x${string}`;
}): Promise<CampaignView | undefined> {
  const { client, addresses, campaignId } = args;

  const stack = addresses.campaignFactory
    ? await fetchCampaignStack({
        client,
        factoryAddress: addresses.campaignFactory,
        campaignId
      })
    : undefined;

  const registryFromStack =
    stack?.registry && stack.registry !== zeroAddress ? stack.registry : undefined;
  const registryAddress = registryFromStack ?? addresses.campaignRegistry;
  if (!registryAddress || registryAddress === zeroAddress) return undefined;

  const campaign = await fetchCampaignFromRegistry({
    client,
    registryAddress,
    campaignId
  });
  if (!campaign) return undefined;

  const tokenMeta = await fetchShareTokenMeta({
    client,
    shareTokenAddress: stack?.shareToken
  });

  return {
    ...campaign,
    stack,
    tokenMeta
  };
}

export function useCampaignDetails(campaignId?: string) {
  const chainId = useChainId();
  const client = usePublicClient();
  const env = getPublicEnv();
  const addresses = resolveAddressesForChain(chainId, env);
  const normalizedCampaignId = normalizeCampaignId(campaignId);
  const hasOnchainForChain = Boolean(addresses.campaignFactory || addresses.campaignRegistry);

  return useQuery({
    queryKey: [
      "campaignDetails",
      chainId,
      normalizedCampaignId ?? "none",
      addresses.campaignFactory ?? "none",
      addresses.campaignRegistry ?? "none"
    ],
    enabled: Boolean(normalizedCampaignId) && (!hasOnchainForChain || Boolean(client)),
    staleTime: DISCOVERY_STALE_TIME_MS,
    refetchInterval: hasOnchainForChain ? DISCOVERY_REFETCH_INTERVAL_MS : false,
    queryFn: async (): Promise<CampaignView | undefined> => {
      if (!normalizedCampaignId) return undefined;

      if (!hasOnchainForChain) {
        return getDemoCampaignViewById(normalizedCampaignId);
      }

      if (!client) return undefined;

      return fetchCampaignDetailsById({
        client,
        addresses,
        campaignId: normalizedCampaignId
      });
    }
  });
}
