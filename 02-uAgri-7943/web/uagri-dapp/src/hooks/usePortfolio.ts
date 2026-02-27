"use client";

import { useQuery } from "@tanstack/react-query";
import { useAccount, usePublicClient } from "wagmi";
import { useCampaigns } from "./useCampaigns";
import { useShareTokenMap } from "./useShareTokenMap";
import { shareTokenAbi } from "@/lib/abi";

export type Holding = {
  campaignId: `0x${string}`;
  token: `0x${string}`;
  symbol?: string;
  balance: bigint;
};

export function usePortfolio() {
  const { address } = useAccount();
  const client = usePublicClient();
  const campaigns = useCampaigns();
  const tokenMap = useShareTokenMap();

  return useQuery({
    queryKey: ["portfolio", address, tokenMap.data],
    enabled: !!client && !!address && !!tokenMap.data && !tokenMap.isLoading,
    queryFn: async (): Promise<Holding[]> => {
      if (!client || !address) return [];
      const holdings: Holding[] = [];
      const map = tokenMap.data ?? {};
      for (const [campaignId, info] of Object.entries(map)) {
        try {
          const [balance, symbol] = await Promise.all([
            client.readContract({ address: info.token, abi: shareTokenAbi, functionName: "balanceOf", args: [address] }) as Promise<bigint>,
            client.readContract({ address: info.token, abi: shareTokenAbi, functionName: "symbol" }) as Promise<string>
          ]);
          holdings.push({ campaignId: campaignId as any, token: info.token, symbol, balance });
        } catch {
          // ignore
        }
      }
      holdings.sort((a, b) => Number(b.balance - a.balance));
      return holdings;
    }
  });
}
