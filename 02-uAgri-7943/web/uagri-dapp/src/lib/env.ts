export type PublicEnv = {
  // Chain-specific address book (preferred)
  NEXT_PUBLIC_BASE_MAINNET_CAMPAIGN_FACTORY?: `0x${string}`;
  NEXT_PUBLIC_BASE_MAINNET_CAMPAIGN_REGISTRY?: `0x${string}`;
  NEXT_PUBLIC_BASE_MAINNET_ROLE_MANAGER?: `0x${string}`;
  NEXT_PUBLIC_BASE_SEPOLIA_CAMPAIGN_FACTORY?: `0x${string}`;
  NEXT_PUBLIC_BASE_SEPOLIA_CAMPAIGN_REGISTRY?: `0x${string}`;
  NEXT_PUBLIC_BASE_SEPOLIA_ROLE_MANAGER?: `0x${string}`;

  // Legacy fallback (global, chain-agnostic)
  NEXT_PUBLIC_CAMPAIGN_FACTORY?: `0x${string}`;
  NEXT_PUBLIC_CAMPAIGN_REGISTRY?: `0x${string}`;
  NEXT_PUBLIC_ROLE_MANAGER?: `0x${string}`;

  NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID?: string;
  NEXT_PUBLIC_BASE_RPC_URL?: string;
  NEXT_PUBLIC_BASE_SEPOLIA_RPC_URL?: string;
  NEXT_PUBLIC_DEFAULT_CHAIN?: string;
  NEXT_PUBLIC_DISCOVERY_FROM_BLOCK?: bigint;
};

export function getPublicEnv(): PublicEnv {
  const baseMainnetFactory = process.env.NEXT_PUBLIC_BASE_MAINNET_CAMPAIGN_FACTORY as any;
  const baseMainnetRegistry = process.env.NEXT_PUBLIC_BASE_MAINNET_CAMPAIGN_REGISTRY as any;
  const baseMainnetRole = process.env.NEXT_PUBLIC_BASE_MAINNET_ROLE_MANAGER as any;
  const baseSepoliaFactory = process.env.NEXT_PUBLIC_BASE_SEPOLIA_CAMPAIGN_FACTORY as any;
  const baseSepoliaRegistry = process.env.NEXT_PUBLIC_BASE_SEPOLIA_CAMPAIGN_REGISTRY as any;
  const baseSepoliaRole = process.env.NEXT_PUBLIC_BASE_SEPOLIA_ROLE_MANAGER as any;

  const factory = process.env.NEXT_PUBLIC_CAMPAIGN_FACTORY as any;
  const registry = process.env.NEXT_PUBLIC_CAMPAIGN_REGISTRY as any;
  const role = process.env.NEXT_PUBLIC_ROLE_MANAGER as any;
  const wc = process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID as any;
  const baseRpc = process.env.NEXT_PUBLIC_BASE_RPC_URL as any;
  const baseSepoliaRpc = process.env.NEXT_PUBLIC_BASE_SEPOLIA_RPC_URL as any;
  const defaultChain = process.env.NEXT_PUBLIC_DEFAULT_CHAIN as any;
  const from = process.env.NEXT_PUBLIC_DISCOVERY_FROM_BLOCK as any;

  return {
    NEXT_PUBLIC_BASE_MAINNET_CAMPAIGN_FACTORY: baseMainnetFactory?.trim?.() || undefined,
    NEXT_PUBLIC_BASE_MAINNET_CAMPAIGN_REGISTRY: baseMainnetRegistry?.trim?.() || undefined,
    NEXT_PUBLIC_BASE_MAINNET_ROLE_MANAGER: baseMainnetRole?.trim?.() || undefined,
    NEXT_PUBLIC_BASE_SEPOLIA_CAMPAIGN_FACTORY: baseSepoliaFactory?.trim?.() || undefined,
    NEXT_PUBLIC_BASE_SEPOLIA_CAMPAIGN_REGISTRY: baseSepoliaRegistry?.trim?.() || undefined,
    NEXT_PUBLIC_BASE_SEPOLIA_ROLE_MANAGER: baseSepoliaRole?.trim?.() || undefined,
    NEXT_PUBLIC_CAMPAIGN_FACTORY: factory?.trim?.() || undefined,
    NEXT_PUBLIC_CAMPAIGN_REGISTRY: registry?.trim?.() || undefined,
    NEXT_PUBLIC_ROLE_MANAGER: role?.trim?.() || undefined,
    NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID: wc?.trim?.() || undefined,
    NEXT_PUBLIC_BASE_RPC_URL: baseRpc?.trim?.() || undefined,
    NEXT_PUBLIC_BASE_SEPOLIA_RPC_URL: baseSepoliaRpc?.trim?.() || undefined,
    NEXT_PUBLIC_DEFAULT_CHAIN: defaultChain?.trim?.() || undefined,
    NEXT_PUBLIC_DISCOVERY_FROM_BLOCK: from ? BigInt(from) : undefined
  };
}
