"use client";

import { createConfig, http, injected } from "wagmi";
import { base, baseSepolia } from "wagmi/chains";
import { coinbaseWallet, walletConnect } from "wagmi/connectors";
import { getPublicEnv } from "./env";

const env = getPublicEnv();

const defaultChainRaw = String(env.NEXT_PUBLIC_DEFAULT_CHAIN ?? "").trim().toLowerCase();
const hasBaseMainnetBook = Boolean(
  env.NEXT_PUBLIC_BASE_MAINNET_CAMPAIGN_FACTORY || env.NEXT_PUBLIC_BASE_MAINNET_CAMPAIGN_REGISTRY
);
const hasBaseSepoliaBook = Boolean(
  env.NEXT_PUBLIC_BASE_SEPOLIA_CAMPAIGN_FACTORY || env.NEXT_PUBLIC_BASE_SEPOLIA_CAMPAIGN_REGISTRY
);
const preferBaseSepolia =
  defaultChainRaw === "base-sepolia" ||
  defaultChainRaw === "sepolia" ||
  defaultChainRaw === "84532" ||
  (!defaultChainRaw && hasBaseSepoliaBook && !hasBaseMainnetBook);

export const appChains = preferBaseSepolia
  ? ([baseSepolia, base] as const)
  : ([base, baseSepolia] as const);

function isValidWalletConnectProjectId(value: string): boolean {
  return /^[a-fA-F0-9]{32}$/u.test(value);
}

const wcProjectIdRaw = String(env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID ?? "").trim();
const enableWC = isValidWalletConnectProjectId(wcProjectIdRaw);
const isBrowser = typeof window !== "undefined";

if (wcProjectIdRaw.length > 0 && !enableWC) {
  // eslint-disable-next-line no-console
  console.warn(
    "[wagmi] WalletConnect disabled: NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID must be a 32-char hex id."
  );
}

const connectors = [
  // MetaMask and most browser wallets come through the injected connector.
  injected({ shimDisconnect: true }),
  coinbaseWallet({ appName: "uAgri" }),
  ...(enableWC && isBrowser
    ? [
        walletConnect({
          projectId: wcProjectIdRaw,
          metadata: {
            name: "uAgri",
            description: "uAgri dApp",
            url: "http://localhost:3000",
            icons: ["http://localhost:3000/favicon.ico"]
          }
        })
      ]
    : [])
];

export const wagmiConfig = createConfig({
  chains: appChains,
  ssr: true,
  connectors,
  transports: {
    [base.id]: http(env.NEXT_PUBLIC_BASE_RPC_URL ?? base.rpcUrls.default.http[0]),
    [baseSepolia.id]: http(env.NEXT_PUBLIC_BASE_SEPOLIA_RPC_URL ?? baseSepolia.rpcUrls.default.http[0])
  }
});
