"use client";

import { useQuery } from "@tanstack/react-query";
import { zeroAddress } from "viem";
import { usePublicClient } from "wagmi";
import { batchMerkleAnchorAbi, documentRegistryAbi, traceAbi } from "@/lib/abi";
import { getLogsChunked, uniq } from "@/lib/discovery";
import { getPublicEnv } from "@/lib/env";
import {
  DISCOVERY_REFETCH_INTERVAL_MS,
  DISCOVERY_STALE_TIME_MS,
  resolveDiscoveryFromBlock
} from "@/lib/campaignDiscovery";

type TimelineSource = "trace" | "docs" | "anchor";

export type TraceabilityTimelineEvent = {
  id: string;
  source: TimelineSource;
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

function liveAddress(addr?: `0x${string}`): addr is `0x${string}` {
  return Boolean(addr && addr !== zeroAddress);
}

export function useTraceabilityTimeline(args: {
  campaignId?: `0x${string}`;
  traceAddress?: `0x${string}`;
  documentRegistryAddress?: `0x${string}`;
  batchAnchorAddress?: `0x${string}`;
  enabled?: boolean;
  limit?: number;
}) {
  const client = usePublicClient();
  const env = getPublicEnv();
  const enabled = args.enabled ?? true;
  const limit = args.limit ?? 80;

  return useQuery({
    queryKey: [
      "traceabilityTimeline",
      args.campaignId ?? "none",
      args.traceAddress ?? "none",
      args.documentRegistryAddress ?? "none",
      args.batchAnchorAddress ?? "none",
      env.NEXT_PUBLIC_DISCOVERY_FROM_BLOCK?.toString() ?? "auto"
    ],
    enabled: Boolean(enabled && client && args.campaignId),
    staleTime: DISCOVERY_STALE_TIME_MS,
    refetchInterval: DISCOVERY_REFETCH_INTERVAL_MS,
    queryFn: async (): Promise<TraceabilityTimelineEvent[]> => {
      if (!client || !args.campaignId) return [];
      const publicClient = client;

      const out: TraceabilityTimelineEvent[] = [];
      const seen = new Set<string>();

      const head = await publicClient.getBlockNumber();
      const fromBlock = resolveDiscoveryFromBlock(head, env.NEXT_PUBLIC_DISCOVERY_FROM_BLOCK);

      async function pushEvents(config: {
        address?: `0x${string}`;
        abi: any;
        eventName: string;
        source: TimelineSource;
        mapSummary: (eventArgs: any) => string;
      }) {
        const { address, abi, eventName, source, mapSummary } = config;
        if (!liveAddress(address)) return;

        try {
          const logs = await getLogsChunked({
            client: publicClient,
            fromBlock,
            toBlock: head,
            maxChunk: 5_000n,
            params: {
              address,
              abi,
              eventName
            }
          });

          for (const log of logs as any[]) {
            const eventArgs = log?.args ?? {};
            if (safeLower(eventArgs?.campaignId) !== safeLower(args.campaignId)) continue;

            const dedupeKey = `${eventName}:${String(log.transactionHash ?? "")}:${String(log.logIndex ?? 0)}`;
            if (seen.has(dedupeKey)) continue;
            seen.add(dedupeKey);

            out.push({
              id: `${source}-${eventName}-${String(log.transactionHash ?? "nohash")}-${String(log.logIndex ?? 0)}`,
              source,
              event: eventName,
              summary: mapSummary(eventArgs),
              txHash: log.transactionHash as `0x${string}` | undefined,
              blockNumber: BigInt(log.blockNumber ?? 0),
              logIndex: Number(log.logIndex ?? 0)
            });
          }
        } catch {
          // Keep best-effort behavior for timeline rendering.
        }
      }

      await pushEvents({
        address: args.traceAddress,
        abi: traceAbi,
        eventName: "TraceEvent",
        source: "trace",
        mapSummary: (eventArgs) =>
          `Event ${String(eventArgs?.eventType ?? "?")} lot ${String(eventArgs?.lotId ?? "").slice(0, 10)} data ${String(eventArgs?.dataHash ?? "").slice(0, 10)}`
      });

      await pushEvents({
        address: args.documentRegistryAddress,
        abi: documentRegistryAbi,
        eventName: "DocRegistered",
        source: "docs",
        mapSummary: (eventArgs) =>
          `Doc type ${String(eventArgs?.docType ?? "?")} hash ${String(eventArgs?.docHash ?? "").slice(0, 10)}`
      });

      const anchorTargets = uniq(
        [args.batchAnchorAddress, args.traceAddress].filter((addr): addr is `0x${string}` => liveAddress(addr))
      );
      for (const address of anchorTargets) {
        await pushEvents({
          address,
          abi: liveAddress(args.batchAnchorAddress) && address.toLowerCase() === args.batchAnchorAddress.toLowerCase() ? batchMerkleAnchorAbi : traceAbi,
          eventName: "BatchRootAnchored",
          source: "anchor",
          mapSummary: (eventArgs) =>
            `Batch ${String(eventArgs?.batchType ?? "?")} root ${String(eventArgs?.root ?? "").slice(0, 10)}`
        });
      }

      out.sort((a, b) => {
        if (a.blockNumber === b.blockNumber) return b.logIndex - a.logIndex;
        return a.blockNumber > b.blockNumber ? -1 : 1;
      });

      const sliced = out.slice(0, limit);
      const blockKeys = uniq(sliced.map((entry) => entry.blockNumber.toString()));
      const byBlock = new Map<string, number>();

      await Promise.all(
        blockKeys.map(async (k) => {
          try {
            const block = await publicClient.getBlock({ blockNumber: BigInt(k) });
            byBlock.set(k, Number(block.timestamp));
          } catch {
            // ignore timestamp errors
          }
        })
      );

      return sliced.map((entry) => ({
        ...entry,
        timestamp: byBlock.get(entry.blockNumber.toString())
      }));
    }
  });
}

