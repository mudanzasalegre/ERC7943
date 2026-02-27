"use client";

import { useMemo } from "react";
import { useChainId } from "wagmi";
import { hasAnyConfiguredAddressBook, resolveAddressesForChain } from "@/lib/addresses";

export function useAppMode() {
  const chainId = useChainId();

  return useMemo(() => {
    const addresses = resolveAddressesForChain(chainId);
    const onchain = Boolean(addresses.campaignFactory || addresses.campaignRegistry);
    return {
      mode: onchain ? ("onchain" as const) : ("demo" as const),
      chainId: addresses.chainId,
      chainName: addresses.chainName,
      addresses,
      hasAnyAddressBook: hasAnyConfiguredAddressBook()
    };
  }, [chainId]);
}
