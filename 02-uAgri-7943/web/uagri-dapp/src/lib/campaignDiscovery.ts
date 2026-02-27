import { zeroAddress } from "viem";
import { campaignFactoryAbi, campaignRegistryAbi, shareTokenAbi } from "@/lib/abi";
import { getLogsChunked, uniq } from "@/lib/discovery";
import { demoCampaigns } from "@/mock/demo";

export const DISCOVERY_STALE_TIME_MS = 15_000;
export const DISCOVERY_REFETCH_INTERVAL_MS = 30_000;
export const DISCOVERY_MAX_CHUNK = 5_000n;
export const DISCOVERY_DEFAULT_LOOKBACK = 200_000n;

const BYTES32_HEX_RE = /^0x[0-9a-fA-F]{64}$/u;
const ZERO_B32 = ("0x" + "00".repeat(32)) as `0x${string}`;

export type CampaignStack = {
  roleManager?: `0x${string}`;
  registry?: `0x${string}`;
  shareToken?: `0x${string}`;
  treasury?: `0x${string}`;
  fundingManager?: `0x${string}`;
  settlementQueue?: `0x${string}`;

  identityAttestation?: `0x${string}`;
  compliance?: `0x${string}`;
  disaster?: `0x${string}`;
  freezeModule?: `0x${string}`;
  forcedTransferController?: `0x${string}`;
  custody?: `0x${string}`;
  trace?: `0x${string}`;
  documentRegistry?: `0x${string}`;
  batchAnchor?: `0x${string}`;
  snapshot?: `0x${string}`;
  distribution?: `0x${string}`;
  insurance?: `0x${string}`;
};

export type CampaignTokenMeta = {
  name?: string;
  symbol?: string;
  decimals?: number;
};

export type CampaignBase = {
  campaignId: `0x${string}`;
  plotRef: `0x${string}`;
  subPlotId: `0x${string}`;
  areaBps: number;
  startTs: number;
  endTs: number;
  settlementAsset: `0x${string}`;
  fundingCap: bigint;
  docsRootHash: `0x${string}`;
  jurisdictionProfile: `0x${string}`;
  state: number;
};

export type CampaignView = CampaignBase & {
  stack?: CampaignStack;
  tokenMeta?: CampaignTokenMeta;
};

export function normalizeCampaignId(value?: string): `0x${string}` | undefined {
  const raw = String(value ?? "").trim();
  if (!BYTES32_HEX_RE.test(raw)) return undefined;
  return raw as `0x${string}`;
}

export function resolveDiscoveryFromBlock(head: bigint, fromEnv?: bigint): bigint {
  if (typeof fromEnv === "bigint") return fromEnv;
  return head > DISCOVERY_DEFAULT_LOOKBACK ? head - DISCOVERY_DEFAULT_LOOKBACK : 0n;
}

export async function fetchFactoryCampaignIds(args: {
  client: any;
  factoryAddress: `0x${string}`;
  fromBlock: bigint;
  toBlock: bigint;
}): Promise<`0x${string}`[]> {
  const { client, factoryAddress, fromBlock, toBlock } = args;

  const deployedLogs = await getLogsChunked({
    client,
    fromBlock,
    toBlock,
    maxChunk: DISCOVERY_MAX_CHUNK,
    params: {
      address: factoryAddress,
      abi: campaignFactoryAbi,
      eventName: "CampaignDeployed"
    }
  });

  const deployedIds = uniq(
    deployedLogs.map((l) => ((l as any).args as any)?.campaignId as `0x${string}`).filter(Boolean)
  );

  if (deployedIds.length > 0) return deployedIds;

  // Compatibility path for older deployments that may emit CampaignCreated.
  try {
    const legacyLogs = await getLogsChunked({
      client,
      fromBlock,
      toBlock,
      maxChunk: DISCOVERY_MAX_CHUNK,
      params: {
        address: factoryAddress,
        abi: campaignRegistryAbi,
        eventName: "CampaignCreated"
      }
    });

    return uniq(
      legacyLogs.map((l) => ((l as any).args as any)?.campaignId as `0x${string}`).filter(Boolean)
    );
  } catch {
    return deployedIds;
  }
}

export async function fetchRegistryCampaignIds(args: {
  client: any;
  registryAddress: `0x${string}`;
  fromBlock: bigint;
  toBlock: bigint;
}): Promise<`0x${string}`[]> {
  const { client, registryAddress, fromBlock, toBlock } = args;

  const logs = await getLogsChunked({
    client,
    fromBlock,
    toBlock,
    maxChunk: DISCOVERY_MAX_CHUNK,
    params: {
      address: registryAddress,
      abi: campaignRegistryAbi,
      eventName: "CampaignCreated"
    }
  });

  return uniq(
    logs.map((l) => ((l as any).args as any)?.campaignId as `0x${string}`).filter(Boolean)
  );
}

export function normalizeCampaignStack(stackRaw: any): CampaignStack {
  if (!stackRaw) return {};

  return {
    roleManager: (stackRaw.roleManager ?? stackRaw[0]) as `0x${string}`,
    registry: (stackRaw.registry ?? stackRaw[1]) as `0x${string}`,
    shareToken: (stackRaw.shareToken ?? stackRaw[2]) as `0x${string}`,
    treasury: (stackRaw.treasury ?? stackRaw[3]) as `0x${string}`,
    fundingManager: (stackRaw.fundingManager ?? stackRaw[4]) as `0x${string}`,
    settlementQueue: (stackRaw.settlementQueue ?? stackRaw[5]) as `0x${string}`,
    identityAttestation: (stackRaw.identityAttestation ?? stackRaw[6]) as `0x${string}`,
    compliance: (stackRaw.compliance ?? stackRaw[7]) as `0x${string}`,
    disaster: (stackRaw.disaster ?? stackRaw[8]) as `0x${string}`,
    freezeModule: (stackRaw.freezeModule ?? stackRaw[9]) as `0x${string}`,
    forcedTransferController: (stackRaw.forcedTransferController ?? stackRaw[10]) as `0x${string}`,
    custody: (stackRaw.custody ?? stackRaw[11]) as `0x${string}`,
    trace: (stackRaw.trace ?? stackRaw[12]) as `0x${string}`,
    documentRegistry: (stackRaw.documentRegistry ?? stackRaw[13]) as `0x${string}`,
    batchAnchor: (stackRaw.batchAnchor ?? stackRaw[14]) as `0x${string}`,
    snapshot: (stackRaw.snapshot ?? stackRaw[15]) as `0x${string}`,
    distribution: (stackRaw.distribution ?? stackRaw[16]) as `0x${string}`,
    insurance: (stackRaw.insurance ?? stackRaw[17]) as `0x${string}`
  };
}

export async function fetchCampaignStack(args: {
  client: any;
  factoryAddress: `0x${string}`;
  campaignId: `0x${string}`;
}): Promise<CampaignStack | undefined> {
  const { client, factoryAddress, campaignId } = args;
  try {
    const raw = await client.readContract({
      address: factoryAddress,
      abi: campaignFactoryAbi,
      functionName: "stacks",
      args: [campaignId]
    });
    return normalizeCampaignStack(raw as any);
  } catch {
    return undefined;
  }
}

export async function fetchCampaignFromRegistry(args: {
  client: any;
  registryAddress: `0x${string}`;
  campaignId: `0x${string}`;
}): Promise<CampaignBase | undefined> {
  const { client, registryAddress, campaignId } = args;

  try {
    const c = (await client.readContract({
      address: registryAddress,
      abi: campaignRegistryAbi,
      functionName: "getCampaign",
      args: [campaignId]
    })) as any;

    return {
      campaignId: c.campaignId as `0x${string}`,
      plotRef: c.plotRef as `0x${string}`,
      subPlotId: c.subPlotId as `0x${string}`,
      areaBps: Number(c.areaBps),
      startTs: Number(c.startTs),
      endTs: Number(c.endTs),
      settlementAsset: c.settlementAsset as `0x${string}`,
      fundingCap: BigInt(c.fundingCap),
      docsRootHash: c.docsRootHash as `0x${string}`,
      jurisdictionProfile: c.jurisdictionProfile as `0x${string}`,
      state: Number(c.state)
    };
  } catch {
    return undefined;
  }
}

export async function fetchShareTokenMeta(args: {
  client: any;
  shareTokenAddress?: `0x${string}`;
}): Promise<CampaignTokenMeta | undefined> {
  const { client, shareTokenAddress } = args;
  if (!shareTokenAddress || shareTokenAddress === zeroAddress) return undefined;

  try {
    const [name, symbol, decimals] = await Promise.all([
      client.readContract({ address: shareTokenAddress, abi: shareTokenAbi, functionName: "name" }) as Promise<string>,
      client.readContract({ address: shareTokenAddress, abi: shareTokenAbi, functionName: "symbol" }) as Promise<string>,
      client.readContract({ address: shareTokenAddress, abi: shareTokenAbi, functionName: "decimals" }) as Promise<number>
    ]);

    return { name, symbol, decimals: Number(decimals) };
  } catch {
    return undefined;
  }
}

export function demoCampaignToView(c: (typeof demoCampaigns)[number]): CampaignView {
  return {
    campaignId: c.campaignId,
    plotRef: c.plotRef,
    subPlotId: ZERO_B32,
    areaBps: 10_000,
    startTs: c.startTs,
    endTs: c.endTs,
    settlementAsset: c.settlementAsset,
    fundingCap: c.fundingCap,
    docsRootHash: ZERO_B32,
    jurisdictionProfile: ZERO_B32,
    state: c.state,
    stack: {
      roleManager: zeroAddress,
      registry: zeroAddress,
      shareToken: c.shareToken,
      treasury: zeroAddress,
      fundingManager: zeroAddress,
      settlementQueue: zeroAddress
    },
    tokenMeta: {
      name: "uAgri Demo",
      symbol: "uAGRI",
      decimals: 18
    }
  };
}

export function getDemoCampaignsView(): CampaignView[] {
  return demoCampaigns.map(demoCampaignToView);
}

export function getDemoCampaignViewById(campaignId: `0x${string}`): CampaignView | undefined {
  const c = demoCampaigns.find((x) => x.campaignId.toLowerCase() === campaignId.toLowerCase());
  return c ? demoCampaignToView(c) : undefined;
}
