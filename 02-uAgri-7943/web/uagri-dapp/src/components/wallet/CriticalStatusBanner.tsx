"use client";

import * as React from "react";
import { AlertTriangle } from "lucide-react";
import { Badge } from "@/components/ui/Badge";
import { useAppMode } from "@/hooks/useAppMode";
import { useCriticalCampaignGuards } from "@/hooks/useCriticalCampaignGuards";
import { shortHex32 } from "@/lib/format";

export default function CriticalStatusBanner() {
  const mode = useAppMode();
  const guards = useCriticalCampaignGuards({ maxCampaigns: 24 });

  if (mode.mode !== "onchain") return null;
  if (guards.campaignsQuery.isLoading || guards.statusQuery.isLoading) return null;
  if (guards.impacted.length === 0) return null;

  return (
    <div className="border-b border-bad/30 bg-bad/10">
      <div className="mx-auto w-full max-w-[900px] px-4 md:px-6">
        <div className="flex flex-col gap-3 py-2 md:flex-row md:items-center md:justify-between">
          <div className="flex items-start gap-2 text-sm">
            <AlertTriangle size={16} className="mt-0.5 text-bad" />
            <div>
              <div className="font-semibold text-text">Critical safety flag detected</div>
              <div className="text-text2">
                {guards.impacted.length} campaign(s) are restricted or hard-frozen. Claims/transfers can be blocked.
              </div>
            </div>
          </div>

          <div className="flex flex-wrap items-center gap-2">
            {guards.impacted.slice(0, 3).map((item) => (
              <a
                key={item.campaignId}
                href={`/campaigns/${item.campaignId}`}
                className="inline-flex items-center gap-2 rounded-lg border border-bad/30 bg-card px-2.5 py-1 text-xs hover:bg-muted"
              >
                <span>{item.symbol ?? "Campaign"}</span>
                <span className="font-mono text-text2">{shortHex32(item.campaignId)}</span>
                {item.hardFrozen ? <Badge tone="bad">Hard frozen</Badge> : null}
                {!item.hardFrozen && item.restricted ? <Badge tone="warn">Restricted</Badge> : null}
              </a>
            ))}

            {guards.impacted.length > 3 ? (
              <span className="text-xs text-text2">+{guards.impacted.length - 3} more</span>
            ) : null}

            <a
              href="/admin/disaster"
              className="inline-flex items-center rounded-lg border border-border bg-card px-2.5 py-1 text-xs hover:bg-muted"
            >
              Open guardian panel
            </a>
          </div>
        </div>
      </div>
    </div>
  );
}

