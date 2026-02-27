"use client";

import * as React from "react";
import { WagmiProvider } from "wagmi";
import { RainbowKitProvider, lightTheme, darkTheme } from "@rainbow-me/rainbowkit";
import "@rainbow-me/rainbowkit/styles.css";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { wagmiConfig } from "@/lib/wagmi";
import { ToasterProvider } from "@/components/tx/ToasterProvider";

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 20_000,
      gcTime: 5 * 60_000,
      retry: 1
    }
  }
});

export default function Providers({ children }: { children: React.ReactNode }) {
  // Keep theme minimal; you can switch by adding a toggle later.
  const isDark = false;

  return (
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        <RainbowKitProvider
          theme={
            isDark
              ? darkTheme({ borderRadius: "medium", accentColor: "#3d9a61", accentColorForeground: "#ffffff" })
              : lightTheme({ borderRadius: "medium", accentColor: "#2f7d4c", accentColorForeground: "#ffffff" })
          }
          modalSize="compact"
          showRecentTransactions={true}
        >
          <ToasterProvider>{children}</ToasterProvider>
        </RainbowKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  );
}
