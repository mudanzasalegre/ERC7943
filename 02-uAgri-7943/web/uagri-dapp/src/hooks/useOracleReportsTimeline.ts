"use client";

import { useQuery } from "@tanstack/react-query";
import { isAddress, zeroAddress } from "viem";
import { usePublicClient } from "wagmi";
import {
  custodyOracleAbi,
  disasterEvidenceOracleAbi,
  harvestOracleAbi,
  salesProceedsOracleAbi
} from "@/lib/abi";
import { getLogsChunked, uniq } from "@/lib/discovery";
import { getPublicEnv } from "@/lib/env";
import {
  DISCOVERY_REFETCH_INTERVAL_MS,
  DISCOVERY_STALE_TIME_MS,
  resolveDiscoveryFromBlock
} from "@/lib/campaignDiscovery";
import { ZERO_BYTES32, isBytes32 } from "@/lib/bytes32";

export type OracleKind = "harvest" | "sales" | "custody" | "disaster";

type OracleConfig = {
  kind: OracleKind;
  label: string;
  abi: unknown;
};

const ORACLE_CONFIGS: OracleConfig[] = [
  { kind: "harvest", label: "Harvest", abi: harvestOracleAbi },
  { kind: "sales", label: "Sales/Proceeds", abi: salesProceedsOracleAbi },
  { kind: "custody", label: "Custody", abi: custodyOracleAbi },
  { kind: "disaster", label: "Disaster Evidence", abi: disasterEvidenceOracleAbi }
];

const ABI_BY_KIND: Record<OracleKind, unknown> = {
  harvest: harvestOracleAbi,
  sales: salesProceedsOracleAbi,
  custody: custodyOracleAbi,
  disaster: disasterEvidenceOracleAbi
};

export type OracleReportTimelineRow = {
  id: string;
  oracle: OracleKind;
  oracleLabel: string;
  oracleAddress: `0x${string}`;
  campaignId: `0x${string}`;
  epoch: bigint;
  reportHash: `0x${string}`;
  payloadHash?: `0x${string}`;
  signer?: `0x${string}`;
  asOf: bigint;
  validUntil: bigint;
  validNow?: boolean;
  txHash?: `0x${string}`;
  blockNumber: bigint;
  logIndex: number;
  timestamp?: number;
};

function normalizeAddress(value?: string): `0x${string}` | undefined {
  if (!value) return undefined;
  if (!isAddress(value)) return undefined;
  if (value.toLowerCase() === zeroAddress) return undefined;
  return value as `0x${string}`;
}

function safeLower(value?: string): string {
  return String(value ?? "").toLowerCase();
}

export function useOracleReportsTimeline(args: {
  campaignId?: string;
  oracleAddresses?: Partial<Record<OracleKind, string>>;
  enabled?: boolean;
  limit?: number;
}) {
  const client = usePublicClient();
  const env = getPublicEnv();
  const enabled = args.enabled ?? true;
  const limit = args.limit ?? 80;

  const campaignId = isBytes32(args.campaignId ?? "")
    ? ((args.campaignId as string).trim() as `0x${string}`)
    : undefined;

  const addresses: Partial<Record<OracleKind, `0x${string}`>> = {
    harvest: normalizeAddress(args.oracleAddresses?.harvest),
    sales: normalizeAddress(args.oracleAddresses?.sales),
    custody: normalizeAddress(args.oracleAddresses?.custody),
    disaster: normalizeAddress(args.oracleAddresses?.disaster)
  };

  return useQuery({
    queryKey: [
      "oracleReportsTimeline",
      campaignId ?? "none",
      addresses.harvest ?? "none",
      addresses.sales ?? "none",
      addresses.custody ?? "none",
      addresses.disaster ?? "none",
      env.NEXT_PUBLIC_DISCOVERY_FROM_BLOCK?.toString() ?? "auto"
    ],
    enabled: Boolean(
      enabled &&
        client &&
        campaignId &&
        (addresses.harvest || addresses.sales || addresses.custody || addresses.disaster)
    ),
    staleTime: DISCOVERY_STALE_TIME_MS,
    refetchInterval: DISCOVERY_REFETCH_INTERVAL_MS,
    queryFn: async (): Promise<OracleReportTimelineRow[]> => {
      if (!client || !campaignId) return [];
      const publicClient = client;

      const head = await publicClient.getBlockNumber();
      const fromBlock = resolveDiscoveryFromBlock(head, env.NEXT_PUBLIC_DISCOVERY_FROM_BLOCK);
      const rows: OracleReportTimelineRow[] = [];

      for (const oracle of ORACLE_CONFIGS) {
        const oracleAddress = addresses[oracle.kind];
        if (!oracleAddress) continue;

        const [reportLogs, attestationLogs] = await Promise.all([
          getLogsChunked({
            client: publicClient,
            fromBlock,
            toBlock: head,
            maxChunk: 5_000n,
            params: {
              address: oracleAddress,
              abi: oracle.abi,
              eventName: "OracleReportSubmitted"
            }
          }),
          getLogsChunked({
            client: publicClient,
            fromBlock,
            toBlock: head,
            maxChunk: 5_000n,
            params: {
              address: oracleAddress,
              abi: oracle.abi,
              eventName: "AttestationSubmitted"
            }
          }).catch(() => [])
        ]);

        const attestationByTxEpoch = new Map<string, { payloadHash?: `0x${string}`; signer?: `0x${string}` }>();

        for (const log of attestationLogs as any[]) {
          const eventArgs = log?.args ?? {};
          if (safeLower(eventArgs?.campaignId) !== safeLower(campaignId)) continue;
          const txHash = log?.transactionHash as `0x${string}` | undefined;
          if (!txHash) continue;
          const epoch = BigInt(eventArgs?.epoch ?? 0);
          if (epoch <= 0n) continue;

          const key = `${txHash.toLowerCase()}:${epoch.toString()}`;
          attestationByTxEpoch.set(key, {
            payloadHash: eventArgs?.payloadHash as `0x${string}` | undefined,
            signer: eventArgs?.signer as `0x${string}` | undefined
          });
        }

        for (const log of reportLogs as any[]) {
          const eventArgs = log?.args ?? {};
          if (safeLower(eventArgs?.campaignId) !== safeLower(campaignId)) continue;

          const txHash = log?.transactionHash as `0x${string}` | undefined;
          const epoch = BigInt(eventArgs?.epoch ?? 0);
          if (epoch <= 0n) continue;

          const mapKey = txHash ? `${txHash.toLowerCase()}:${epoch.toString()}` : "";
          const attestationMeta = mapKey ? attestationByTxEpoch.get(mapKey) : undefined;

          rows.push({
            id: `${oracle.kind}:${String(txHash ?? "nohash")}:${String(log?.logIndex ?? 0)}`,
            oracle: oracle.kind,
            oracleLabel: oracle.label,
            oracleAddress,
            campaignId,
            epoch,
            reportHash: (eventArgs?.reportHash ?? ZERO_BYTES32) as `0x${string}`,
            payloadHash: attestationMeta?.payloadHash,
            signer: attestationMeta?.signer,
            asOf: BigInt(eventArgs?.asOf ?? 0),
            validUntil: BigInt(eventArgs?.validUntil ?? 0),
            txHash,
            blockNumber: BigInt(log?.blockNumber ?? 0),
            logIndex: Number(log?.logIndex ?? 0)
          });
        }
      }

      rows.sort((a, b) => {
        if (a.blockNumber === b.blockNumber) return b.logIndex - a.logIndex;
        return a.blockNumber > b.blockNumber ? -1 : 1;
      });

      const sliced = rows.slice(0, limit);

      const enriched = await Promise.all(
        sliced.map(async (row) => {
          const abi = ABI_BY_KIND[row.oracle];
          let payloadHash = row.payloadHash;
          let validNow = row.validNow;
          try {
            const [validRaw, payloadRaw] = await Promise.all([
              publicClient.readContract({
                address: row.oracleAddress,
                abi: abi as any,
                functionName: "isReportValid",
                args: [row.campaignId, row.epoch]
              }),
              payloadHash
                ? Promise.resolve(payloadHash)
                : publicClient.readContract({
                    address: row.oracleAddress,
                    abi: abi as any,
                    functionName: "payloadHash",
                    args: [row.campaignId, row.epoch]
                  })
            ]);
            validNow = Boolean(validRaw);
            payloadHash = payloadRaw as `0x${string}`;
          } catch {
            // keep best-effort list even if some reads fail
          }
          return {
            ...row,
            payloadHash,
            validNow
          };
        })
      );

      const blockKeys = uniq(enriched.map((entry) => entry.blockNumber.toString()));
      const byBlock = new Map<string, number>();
      await Promise.all(
        blockKeys.map(async (key) => {
          try {
            const block = await publicClient.getBlock({ blockNumber: BigInt(key) });
            byBlock.set(key, Number(block.timestamp));
          } catch {
            // timestamp lookup best-effort
          }
        })
      );

      return enriched.map((entry) => ({
        ...entry,
        timestamp: byBlock.get(entry.blockNumber.toString())
      }));
    }
  });
}
