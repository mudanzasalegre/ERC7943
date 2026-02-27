"use client";

import { useMemo } from "react";
import { useCampaignDetails } from "./useCampaignDetails";
import { useShareTokenMap } from "./useShareTokenMap";

export function useCampaignDetail(campaignId?: string) {
  const details = useCampaignDetails(campaignId);
  const tokens = useShareTokenMap();

  const tokenFromMap = useMemo(() => {
    if (!campaignId || !tokens.data) return undefined;
    const exact = tokens.data[campaignId]?.token;
    if (exact) return exact;
    const foundKey = Object.keys(tokens.data).find(
      (key) => key.toLowerCase() === campaignId.toLowerCase()
    );
    return foundKey ? tokens.data[foundKey]?.token : undefined;
  }, [campaignId, tokens.data]);

  const token = useMemo(() => {
    return details.data?.stack?.shareToken ?? tokenFromMap;
  }, [details.data?.stack?.shareToken, tokenFromMap]);

  return {
    campaign: details.data,
    token,
    loading: details.isLoading || tokens.isLoading,
    error: details.error || tokens.error
  };
}
