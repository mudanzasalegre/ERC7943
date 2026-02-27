import { zeroAddress } from "viem";

export type DemoCampaign = {
  campaignId: `0x${string}`; // bytes32
  plotRef: `0x${string}`;
  settlementAsset: `0x${string}`;
  fundingCap: bigint;
  startTs: number;
  endTs: number;
  state: number;
  shareToken: `0x${string}`;
};

// NOTE: keep demo data deterministic to avoid SSR/client hydration mismatches.
const NOW = 1735689600; // 2025-01-01T00:00:00Z

export const demoCampaigns: DemoCampaign[] = [
  {
    campaignId: "0x1111111111111111111111111111111111111111111111111111111111111111",
    plotRef: "0xaaaa000000000000000000000000000000000000000000000000000000000000",
    settlementAsset: zeroAddress,
    fundingCap: 2_000_000n * 10n ** 6n,
    startTs: NOW - 14 * 24 * 3600,
    endTs: NOW + 90 * 24 * 3600,
    state: 0,
    shareToken: "0x000000000000000000000000000000000000dEaD"
  },
  {
    campaignId: "0x2222222222222222222222222222222222222222222222222222222222222222",
    plotRef: "0xbbbb000000000000000000000000000000000000000000000000000000000000",
    settlementAsset: zeroAddress,
    fundingCap: 1_200_000n * 10n ** 6n,
    startTs: NOW - 60 * 24 * 3600,
    endTs: NOW + 30 * 24 * 3600,
    state: 1,
    shareToken: "0x000000000000000000000000000000000000bEEF"
  }
];

export function demoBalanceFor(campaignId: string): bigint {
  return campaignId.startsWith("0x11") ? 250n * 10n ** 18n : 0n;
}
