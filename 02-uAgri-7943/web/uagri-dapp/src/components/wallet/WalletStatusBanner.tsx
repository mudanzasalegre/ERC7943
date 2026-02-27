"use client";

import * as React from "react";
import { useAccount, useChainId, useSwitchChain } from "wagmi";
import { base, baseSepolia } from "wagmi/chains";
import { AlertTriangle, PlugZap } from "lucide-react";
import { Button } from "@/components/ui/Button";
import { useMounted } from "@/hooks/useMounted";

export default function WalletStatusBanner() {
  const mounted = useMounted();
  const { isConnected } = useAccount();
  const chainId = useChainId();
  const { switchChain, isPending } = useSwitchChain();

  const supported = chainId === base.id || chainId === baseSepolia.id;
  const chainName = chainId === base.id ? "Base" : chainId === baseSepolia.id ? "Base Sepolia" : `Chain ${chainId}`;
  const alternateChainId = chainId === base.id ? baseSepolia.id : base.id;
  const alternateChainName = alternateChainId === base.id ? "Base" : "Base Sepolia";

  // During SSR the wallet state is unknown; keep the first client render
  // identical to the server output to avoid hydration issues.
  if (!mounted) return null;

  if (!isConnected) {
    return (
      <div className="border-b border-border/80 bg-surface/80">
        <div className="mx-auto w-full max-w-[900px] px-4 md:px-6">
          <div className="flex items-center justify-between gap-3 py-2">
            <div className="flex items-center gap-2 text-sm text-text2">
              <PlugZap size={16} />
              <span>
                Wallet disconnected - browsing in <span className="font-medium text-text">read-only</span> mode.
              </span>
            </div>
            <span className="hidden sm:inline text-[12px] text-text2">
              Network: {chainName}. Connect to deposit/redeem/claim.
            </span>
          </div>
        </div>
      </div>
    );
  }

  if (supported) {
    return (
      <div className="border-b border-border/80 bg-good/10">
        <div className="mx-auto w-full max-w-[900px] px-4 md:px-6">
          <div className="flex flex-col gap-2 py-2 md:flex-row md:items-center md:justify-between">
            <div className="text-sm text-text">
              Connected network: <span className="font-medium">{chainName}</span>
            </div>
            <div className="flex items-center gap-2">
              <Button
                size="sm"
                variant="secondary"
                disabled={!switchChain || isPending}
                onClick={() => switchChain?.({ chainId: alternateChainId })}
              >
                Switch to {alternateChainName}
              </Button>
            </div>
          </div>
        </div>
      </div>
    );
  }

  return (
    <div className="border-b border-border/80 bg-warn/10">
      <div className="mx-auto w-full max-w-[900px] px-4 md:px-6">
        <div className="flex flex-col gap-2 py-2 md:flex-row md:items-center md:justify-between">
          <div className="flex items-center gap-2 text-sm">
            <AlertTriangle size={16} className="text-warn" />
            <span className="text-text">
              Wrong network - switch to <span className="font-medium">Base</span> or <span className="font-medium">Base Sepolia</span>.
            </span>
          </div>
          <div className="flex items-center gap-2">
            <Button
              size="sm"
              variant="secondary"
              disabled={!switchChain || isPending}
              onClick={() => switchChain?.({ chainId: base.id })}
            >
              Switch to Base
            </Button>
            <Button
              size="sm"
              variant="secondary"
              disabled={!switchChain || isPending}
              onClick={() => switchChain?.({ chainId: baseSepolia.id })}
            >
              Switch to Base Sepolia
            </Button>
          </div>
        </div>
      </div>
    </div>
  );
}
