import { getAddress, isAddress } from "viem";
import { base, baseSepolia } from "wagmi/chains";
import baseMainnetJson from "@/addresses/base-mainnet.json";
import baseSepoliaJson from "@/addresses/base-sepolia.json";
import { getPublicEnv, type PublicEnv } from "./env";

export type AddressBook = {
  chainId: number;
  chainName: string;
  campaignFactory?: `0x${string}`;
  campaignRegistry?: `0x${string}`;
  roleManager?: `0x${string}`;
  isConfigured: boolean;
};

type AddressBookJson = {
  chainId: number;
  chainName: string;
  campaignFactory?: string;
  campaignRegistry?: string;
  roleManager?: string;
};

const byChainJson: Record<number, AddressBookJson> = {
  [base.id]: baseMainnetJson as AddressBookJson,
  [baseSepolia.id]: baseSepoliaJson as AddressBookJson
};

export const supportedAddressChains = [base.id, baseSepolia.id] as const;

function normalizeAddress(value?: string): `0x${string}` | undefined {
  const raw = String(value ?? "").trim();
  if (!raw) return undefined;
  if (!isAddress(raw)) return undefined;
  return getAddress(raw) as `0x${string}`;
}

function getChainName(chainId: number): string {
  if (chainId === base.id) return "Base";
  if (chainId === baseSepolia.id) return "Base Sepolia";
  return `Chain ${chainId}`;
}

function getBookFromJson(chainId: number) {
  const data = byChainJson[chainId];
  if (!data) return {};
  return {
    campaignFactory: normalizeAddress(data.campaignFactory),
    campaignRegistry: normalizeAddress(data.campaignRegistry),
    roleManager: normalizeAddress(data.roleManager)
  };
}

function getBookFromEnv(chainId: number, env: PublicEnv) {
  if (chainId === base.id) {
    return {
      campaignFactory:
        normalizeAddress(env.NEXT_PUBLIC_BASE_MAINNET_CAMPAIGN_FACTORY) ??
        normalizeAddress(env.NEXT_PUBLIC_CAMPAIGN_FACTORY),
      campaignRegistry:
        normalizeAddress(env.NEXT_PUBLIC_BASE_MAINNET_CAMPAIGN_REGISTRY) ??
        normalizeAddress(env.NEXT_PUBLIC_CAMPAIGN_REGISTRY),
      roleManager:
        normalizeAddress(env.NEXT_PUBLIC_BASE_MAINNET_ROLE_MANAGER) ??
        normalizeAddress(env.NEXT_PUBLIC_ROLE_MANAGER)
    };
  }

  if (chainId === baseSepolia.id) {
    return {
      campaignFactory:
        normalizeAddress(env.NEXT_PUBLIC_BASE_SEPOLIA_CAMPAIGN_FACTORY) ??
        normalizeAddress(env.NEXT_PUBLIC_CAMPAIGN_FACTORY),
      campaignRegistry:
        normalizeAddress(env.NEXT_PUBLIC_BASE_SEPOLIA_CAMPAIGN_REGISTRY) ??
        normalizeAddress(env.NEXT_PUBLIC_CAMPAIGN_REGISTRY),
      roleManager:
        normalizeAddress(env.NEXT_PUBLIC_BASE_SEPOLIA_ROLE_MANAGER) ??
        normalizeAddress(env.NEXT_PUBLIC_ROLE_MANAGER)
    };
  }

  return {};
}

export function resolveAddressesForChain(chainId: number | undefined, env: PublicEnv = getPublicEnv()): AddressBook {
  const id = Number(chainId ?? baseSepolia.id);
  const fromJson = getBookFromJson(id);
  const fromEnv = getBookFromEnv(id, env);

  const campaignFactory = fromEnv.campaignFactory ?? fromJson.campaignFactory;
  const campaignRegistry = fromEnv.campaignRegistry ?? fromJson.campaignRegistry;
  const roleManager = fromEnv.roleManager ?? fromJson.roleManager;

  return {
    chainId: id,
    chainName: getChainName(id),
    campaignFactory,
    campaignRegistry,
    roleManager,
    isConfigured: Boolean(campaignFactory || campaignRegistry || roleManager)
  };
}

export function hasAnyConfiguredAddressBook(env: PublicEnv = getPublicEnv()): boolean {
  return supportedAddressChains.some((chainId) => {
    const book = resolveAddressesForChain(chainId, env);
    return book.isConfigured;
  });
}
