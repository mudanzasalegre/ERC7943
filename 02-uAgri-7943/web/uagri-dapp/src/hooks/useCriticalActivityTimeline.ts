"use client";

import { useQuery } from "@tanstack/react-query";
import { isAddress, zeroAddress } from "viem";
import { usePublicClient } from "wagmi";
import { disasterAdminAbi, shareTokenAbi } from "@/lib/abi";
import { getPublicEnv } from "@/lib/env";
import { getLogsChunked, uniq } from "@/lib/discovery";
import {
  DISCOVERY_REFETCH_INTERVAL_MS,
  DISCOVERY_STALE_TIME_MS,
  resolveDiscoveryFromBlock
} from "@/lib/campaignDiscovery";

const BYTES32_HEX_RE = /^0x[0-9a-fA-F]{64}$/u;

function safeLower(value?: string): string {
  return String(value ?? "").toLowerCase();
}

export type CriticalActivityEvent = {
  id: string;
  source: "disaster" | "freeze";
  event: string;
  summary: string;
  txHash?: `0x${string}`;
  blockNumber: bigint;
  logIndex: number;
  timestamp?: number;
};

type Options = {
  disasterModule?: string;
  shareToken?: string;
  campaignId?: string;
  enabled?: boolean;
  maxEvents?: number;
};

export function useCriticalActivityTimeline(options: Options) {
  const client = usePublicClient();
  const env = getPublicEnv();
  const enabled = options.enabled ?? true;
  const maxEvents = options.maxEvents ?? 80;

  const disasterModule =
    options.disasterModule && isAddress(options.disasterModule) && options.disasterModule !== zeroAddress
      ? (options.disasterModule as `0x${string}`)
      : undefined;
  const shareToken =
    options.shareToken && isAddress(options.shareToken) && options.shareToken !== zeroAddress
      ? (options.shareToken as `0x${string}`)
      : undefined;
  const campaignId =
    options.campaignId && BYTES32_HEX_RE.test(options.campaignId)
      ? (options.campaignId as `0x${string}`)
      : undefined;

  return useQuery({
    queryKey: [
      "criticalActivityTimeline",
      disasterModule ?? "none",
      shareToken ?? "none",
      campaignId ?? "none",
      env.NEXT_PUBLIC_DISCOVERY_FROM_BLOCK?.toString() ?? "auto"
    ],
    enabled: Boolean(enabled && client && disasterModule && campaignId),
    staleTime: DISCOVERY_STALE_TIME_MS,
    refetchInterval: DISCOVERY_REFETCH_INTERVAL_MS,
    queryFn: async (): Promise<CriticalActivityEvent[]> => {
      if (!client || !disasterModule || !campaignId) return [];
      const publicClient = client;

      const head = await publicClient.getBlockNumber();
      const fromBlock = resolveDiscoveryFromBlock(head, env.NEXT_PUBLIC_DISCOVERY_FROM_BLOCK);
      const out: CriticalActivityEvent[] = [];

      async function pushEvents(args: {
        address: `0x${string}`;
        abi: any;
        eventName: string;
        source: CriticalActivityEvent["source"];
        mapSummary: (eventArgs: any) => string;
        filter?: (eventArgs: any) => boolean;
      }) {
        const { address, abi, eventName, source, mapSummary, filter } = args;
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
          // Best-effort activity feed. Ignore stream-specific failures.
        }
      }

      await pushEvents({
        address: disasterModule,
        abi: disasterAdminAbi,
        eventName: "DisasterDeclared",
        source: "disaster",
        filter: (eventArgs) => safeLower(eventArgs?.campaignId) === safeLower(campaignId),
        mapSummary: (eventArgs) =>
          `Declared severity ${String(eventArgs?.severity ?? "?")} flags ${String(eventArgs?.flags ?? "0")}`
      });

      await pushEvents({
        address: disasterModule,
        abi: disasterAdminAbi,
        eventName: "DisasterConfirmed",
        source: "disaster",
        filter: (eventArgs) => safeLower(eventArgs?.campaignId) === safeLower(campaignId),
        mapSummary: (eventArgs) =>
          `Confirmed severity ${String(eventArgs?.severity ?? "?")} flags ${String(eventArgs?.flags ?? "0")}`
      });

      await pushEvents({
        address: disasterModule,
        abi: disasterAdminAbi,
        eventName: "DisasterCleared",
        source: "disaster",
        filter: (eventArgs) => safeLower(eventArgs?.campaignId) === safeLower(campaignId),
        mapSummary: () => "Disaster state cleared"
      });

      if (shareToken) {
        await pushEvents({
          address: shareToken,
          abi: shareTokenAbi,
          eventName: "Frozen",
          source: "freeze",
          mapSummary: (eventArgs) =>
            `Frozen account ${String(eventArgs?.account ?? "").slice(0, 10)} amount ${String(eventArgs?.amount ?? "0")}`
        });

        await pushEvents({
          address: shareToken,
          abi: shareTokenAbi,
          eventName: "ForcedTransfer",
          source: "freeze",
          mapSummary: (eventArgs) =>
            `Forced transfer ${String(eventArgs?.from ?? "").slice(0, 8)} -> ${String(eventArgs?.to ?? "").slice(0, 8)} amount ${String(eventArgs?.amount ?? "0")}`
        });
      }

      out.sort((a, b) => {
        if (a.blockNumber === b.blockNumber) return b.logIndex - a.logIndex;
        return a.blockNumber > b.blockNumber ? -1 : 1;
      });

      const sliced = out.slice(0, maxEvents);
      const blockKeys = uniq(sliced.map((x) => x.blockNumber.toString()));
      const byBlock = new Map<string, number>();

      await Promise.all(
        blockKeys.map(async (k) => {
          try {
            const block = await publicClient.getBlock({ blockNumber: BigInt(k) });
            byBlock.set(k, Number(block.timestamp));
          } catch {
            // ignore timestamp fetch failures
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
