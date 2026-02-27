"use client";

import { useQuery } from "@tanstack/react-query";
import { zeroAddress } from "viem";
import { usePublicClient } from "wagmi";
import {
  batchMerkleAnchorAbi,
  campaignRegistryAbi,
  distributionAbi,
  documentRegistryAbi,
  settlementQueueAbi,
  traceAbi
} from "@/lib/abi";
import { getPublicEnv } from "@/lib/env";
import { getLogsChunked, uniq } from "@/lib/discovery";
import {
  DISCOVERY_REFETCH_INTERVAL_MS,
  DISCOVERY_STALE_TIME_MS,
  resolveDiscoveryFromBlock,
  type CampaignView
} from "@/lib/campaignDiscovery";
import type { TokenModules } from "./useTokenModules";

export type CampaignActivityEvent = {
  id: string;
  source: "registry" | "queue" | "distribution" | "docs" | "trace" | "anchor";
  event: string;
  summary: string;
  txHash?: `0x${string}`;
  blockNumber: bigint;
  logIndex: number;
  timestamp?: number;
};

function safeLower(value?: string): string {
  return String(value ?? "").toLowerCase();
}

export function useCampaignActivity(campaign?: CampaignView, modules?: Partial<TokenModules>) {
  const client = usePublicClient();
  const env = getPublicEnv();

  const registry = campaign?.stack?.registry;
  const settlementQueue = modules?.settlementQueue ?? campaign?.stack?.settlementQueue;
  const distribution = modules?.distribution ?? campaign?.stack?.distribution;
  const docs = modules?.documentRegistry ?? campaign?.stack?.documentRegistry;
  const trace = modules?.trace ?? campaign?.stack?.trace;
  const batchAnchor = campaign?.stack?.batchAnchor;

  return useQuery({
    queryKey: [
      "campaignActivity",
      campaign?.campaignId ?? "none",
      registry ?? "none",
      settlementQueue ?? "none",
      distribution ?? "none",
      docs ?? "none",
      trace ?? "none",
      batchAnchor ?? "none",
      env.NEXT_PUBLIC_DISCOVERY_FROM_BLOCK?.toString() ?? "auto"
    ],
    enabled: Boolean(client && campaign),
    staleTime: DISCOVERY_STALE_TIME_MS,
    refetchInterval: DISCOVERY_REFETCH_INTERVAL_MS,
    queryFn: async (): Promise<CampaignActivityEvent[]> => {
      if (!client || !campaign) return [];
      const publicClient = client;

      const out: CampaignActivityEvent[] = [];
      const seen = new Set<string>();
      const head = await publicClient.getBlockNumber();
      const fromBlock = resolveDiscoveryFromBlock(head, env.NEXT_PUBLIC_DISCOVERY_FROM_BLOCK);

      async function pushEvents(args: {
        address?: `0x${string}`;
        abi: any;
        eventName: string;
        source: CampaignActivityEvent["source"];
        mapSummary: (eventArgs: any) => string;
        filter?: (eventArgs: any) => boolean;
      }) {
        const { address, abi, eventName, source, mapSummary, filter } = args;
        if (!address || address === zeroAddress) return;
        try {
          const logs = await getLogsChunked({
            client: publicClient,
            fromBlock,
            toBlock: head,
            maxChunk: 5_000n,
            params: { address, abi, eventName }
          });

          for (const log of logs as any[]) {
            const eventArgs = log?.args ?? {};
            if (filter && !filter(eventArgs)) continue;
            const dedupe = `${eventName}:${String(log.transactionHash ?? "")}:${String(log.logIndex ?? 0)}`;
            if (seen.has(dedupe)) continue;
            seen.add(dedupe);
            out.push({
              id: `${source}-${eventName}-${log.transactionHash ?? "nohash"}-${String(log.logIndex ?? 0)}`,
              source,
              event: eventName,
              summary: mapSummary(eventArgs),
              txHash: log.transactionHash as `0x${string}` | undefined,
              blockNumber: BigInt(log.blockNumber ?? 0),
              logIndex: Number(log.logIndex ?? 0)
            });
          }
        } catch {
          // ignore event stream errors and keep best-effort feed
        }
      }

      await pushEvents({
        address: registry,
        abi: campaignRegistryAbi,
        eventName: "CampaignStateUpdated",
        source: "registry",
        filter: (args) => safeLower(args?.campaignId) === safeLower(campaign.campaignId),
        mapSummary: (args) => `State updated to ${String(args?.state ?? "?")}`
      });

      await pushEvents({
        address: registry,
        abi: campaignRegistryAbi,
        eventName: "CampaignDocsRootUpdated",
        source: "registry",
        filter: (args) => safeLower(args?.campaignId) === safeLower(campaign.campaignId),
        mapSummary: (args) => `Docs root updated to ${String(args?.newRootHash ?? "").slice(0, 12)}...`
      });

      await pushEvents({
        address: settlementQueue,
        abi: settlementQueueAbi,
        eventName: "RequestCreated",
        source: "queue",
        mapSummary: (args) =>
          `Request #${String(args?.id ?? "?")} created (kind ${String(args?.kind ?? "?")}, amount ${String(args?.amount ?? "0")})`
      });

      await pushEvents({
        address: settlementQueue,
        abi: settlementQueueAbi,
        eventName: "RequestProcessed",
        source: "queue",
        mapSummary: (args) =>
          `Request #${String(args?.id ?? "?")} processed (out ${String(args?.outAmount ?? "0")})`
      });

      await pushEvents({
        address: settlementQueue,
        abi: settlementQueueAbi,
        eventName: "RequestCancelled",
        source: "queue",
        mapSummary: (args) => `Request #${String(args?.id ?? "?")} cancelled`
      });

      await pushEvents({
        address: distribution,
        abi: distributionAbi,
        eventName: "RewardNotified",
        source: "distribution",
        mapSummary: (args) =>
          `Reward notified (amount ${String(args?.amount ?? "0")}, liquidation ${String(args?.liquidationId ?? "?")})`
      });

      await pushEvents({
        address: distribution,
        abi: distributionAbi,
        eventName: "Claimed",
        source: "distribution",
        mapSummary: (args) =>
          `Claimed ${String(args?.amount ?? "0")} by ${String(args?.account ?? "").slice(0, 10)}...`
      });

      await pushEvents({
        address: docs,
        abi: documentRegistryAbi,
        eventName: "DocRegistered",
        source: "docs",
        filter: (args) => safeLower(args?.campaignId) === safeLower(campaign.campaignId),
        mapSummary: (args) =>
          `Document registered (${String(args?.docHash ?? "").slice(0, 12)}..., type ${String(args?.docType ?? "?")})`
      });

      await pushEvents({
        address: trace,
        abi: traceAbi,
        eventName: "TraceEvent",
        source: "trace",
        filter: (args) => safeLower(args?.campaignId) === safeLower(campaign.campaignId),
        mapSummary: (args) =>
          `Trace event type ${String(args?.eventType ?? "?")} for lot ${String(args?.lotId ?? "").slice(0, 10)}...`
      });

      await pushEvents({
        address: trace,
        abi: traceAbi,
        eventName: "BatchRootAnchored",
        source: "anchor",
        filter: (args) => safeLower(args?.campaignId) === safeLower(campaign.campaignId),
        mapSummary: (args) =>
          `Batch root anchored (${String(args?.root ?? "").slice(0, 12)}..., batch ${String(args?.batchType ?? "?")})`
      });

      await pushEvents({
        address: batchAnchor,
        abi: batchMerkleAnchorAbi,
        eventName: "BatchRootAnchored",
        source: "anchor",
        filter: (args) => safeLower(args?.campaignId) === safeLower(campaign.campaignId),
        mapSummary: (args) =>
          `Merkle root anchored (${String(args?.root ?? "").slice(0, 12)}..., batch ${String(args?.batchType ?? "?")})`
      });

      out.sort((a, b) => {
        if (a.blockNumber === b.blockNumber) return b.logIndex - a.logIndex;
        return a.blockNumber > b.blockNumber ? -1 : 1;
      });

      const sliced = out.slice(0, 60);
      const blockKeys = uniq(sliced.map((x) => x.blockNumber.toString()));
      const byBlock = new Map<string, number>();

      await Promise.all(
        blockKeys.map(async (k) => {
          try {
            const b = await publicClient.getBlock({ blockNumber: BigInt(k) });
            byBlock.set(k, Number(b.timestamp));
          } catch {
            // ignore timestamp fetch failures
          }
        })
      );

      return sliced.map((x) => ({
        ...x,
        timestamp: byBlock.get(x.blockNumber.toString())
      }));
    }
  });
}
