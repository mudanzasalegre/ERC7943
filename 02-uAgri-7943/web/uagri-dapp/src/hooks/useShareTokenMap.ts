"use client";

import { useQuery } from "@tanstack/react-query";
import { usePublicClient, useChainId } from "wagmi";
import { getPublicEnv } from "@/lib/env";
import { resolveAddressesForChain } from "@/lib/addresses";
import { campaignFactoryAbi, modulesUpdatedEventAbi, shareTokenAbi } from "@/lib/abi";
import { getLogsChunked, uniq } from "@/lib/discovery";
import { demoCampaigns } from "@/mock/demo";

export type ShareTokenInfo = {
  token: `0x${string}`;
  campaignId: `0x${string}`;
  name?: string;
  symbol?: string;
};

export function useShareTokenMap() {
  const client = usePublicClient();
  const chainId = useChainId();
  const env = getPublicEnv();
  const addresses = resolveAddressesForChain(chainId, env);

  return useQuery({
    queryKey: [
      "shareTokenMap",
      chainId,
      addresses.campaignFactory ?? "none",
      addresses.campaignRegistry ?? "none",
      env.NEXT_PUBLIC_DISCOVERY_FROM_BLOCK?.toString() ?? "auto"
    ],
    enabled: !Boolean(addresses.campaignFactory || addresses.campaignRegistry) || !!client,
    queryFn: async (): Promise<Record<string, ShareTokenInfo>> => {
      const hasOnchainForChain = Boolean(addresses.campaignFactory || addresses.campaignRegistry);

      if (!hasOnchainForChain) {
        const m: Record<string, ShareTokenInfo> = {};
        for (const c of demoCampaigns) {
          m[c.campaignId] = { token: c.shareToken, campaignId: c.campaignId, name: "uAgri Demo", symbol: "uAGRI" };
        }
        return m;
      }

      if (!client) return {};

      const head = await client.getBlockNumber();
      const fromEnv = env.NEXT_PUBLIC_DISCOVERY_FROM_BLOCK;
      const fromBlock = fromEnv ?? (head > 200_000n ? head - 200_000n : 0n);

      // If the factory is configured, it is the authoritative source.
      if (addresses.campaignFactory) {
        const logs = await getLogsChunked({
          client,
          fromBlock,
          toBlock: head,
          maxChunk: 5_000n,
          params: {
            address: addresses.campaignFactory,
            abi: campaignFactoryAbi,
            eventName: "CampaignDeployed"
          }
        });

        const map: Record<string, ShareTokenInfo> = {};
        for (const l of logs) {
          const event = l as any;
          const args: any = event.args;
          const campaignId = args?.campaignId as `0x${string}`;
          const token = (args?.shareToken ?? event.args?.shareToken) as `0x${string}`;
          if (!campaignId || !token) continue;
          try {
            const [name, symbol] = await Promise.all([
              client.readContract({ address: token, abi: shareTokenAbi, functionName: "name" }) as Promise<string>,
              client.readContract({ address: token, abi: shareTokenAbi, functionName: "symbol" }) as Promise<string>
            ]);
            map[campaignId] = { token, campaignId, name, symbol };
          } catch {
            map[campaignId] = { token, campaignId };
          }
        }
        return map;
      }

      // Scan for ShareToken deployments (AgriShareToken emits ModulesUpdated when initialized/wired).
      const logs = await getLogsChunked({
        client,
        fromBlock,
        toBlock: head,
        maxChunk: 3_000n,
        params: {
          abi: modulesUpdatedEventAbi,
          eventName: "ModulesUpdated"
        }
      });

      const tokenAddresses = uniq(
        logs.map((l) => l.address as `0x${string}`).filter(Boolean)
      );

      const map: Record<string, ShareTokenInfo> = {};

      for (const token of tokenAddresses) {
        try {
          const campaignId = (await client.readContract({
            address: token,
            abi: shareTokenAbi,
            functionName: "campaignId"
          })) as `0x${string}`;

          const [name, symbol] = await Promise.all([
            client.readContract({ address: token, abi: shareTokenAbi, functionName: "name" }) as Promise<string>,
            client.readContract({ address: token, abi: shareTokenAbi, functionName: "symbol" }) as Promise<string>
          ]);

          map[campaignId] = { token, campaignId, name, symbol };
        } catch {
          // Ignore non-token emitters or tokens that reverted on read.
        }
      }

      return map;
    }
  });
}
