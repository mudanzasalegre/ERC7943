"use client";

import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/Card";
import { useTokenModules } from "@/hooks/useTokenModules";
import { explorerAddressUrl } from "@/lib/explorer";
import { useChainId } from "wagmi";
import { shortAddr } from "@/lib/format";
import { Skeleton } from "@/components/ui/Skeleton";

function Row({ label, addr, chainId }: { label: string; addr?: `0x${string}`; chainId: number }) {
  return (
    <div className="flex items-center justify-between gap-3 rounded-xl border border-border bg-card px-3 py-2">
      <div className="text-sm">{label}</div>
      {addr ? (
        <a className="font-mono text-sm text-primary hover:underline" href={explorerAddressUrl(chainId, addr)} target="_blank" rel="noreferrer">
          {shortAddr(addr, 5)}
        </a>
      ) : (
        <span className="text-sm text-text2">—</span>
      )}
    </div>
  );
}

export function CampaignModules({ token, batchAnchorAddress }: { token: `0x${string}`; batchAnchorAddress?: `0x${string}` }) {
  const chainId = useChainId();
  const m = useTokenModules(token);

  return (
    <Card className="mt-4">
      <CardHeader>
        <CardTitle>Modules</CardTitle>
        <CardDescription>Wiring is read from the ShareToken contract (IAgriModulesV1 views).</CardDescription>
      </CardHeader>
      <CardContent className="grid gap-2 md:grid-cols-2">
        {m.isLoading ? (
          <>
            <Skeleton className="h-11" />
            <Skeleton className="h-11" />
            <Skeleton className="h-11" />
            <Skeleton className="h-11" />
          </>
        ) : (
          <>
            <Row label="SettlementQueue" addr={m.data?.settlementQueue} chainId={chainId} />
            <Row label="Treasury" addr={m.data?.treasury} chainId={chainId} />
            <Row label="Distribution" addr={m.data?.distribution} chainId={chainId} />
            <Row label="Compliance" addr={m.data?.compliance} chainId={chainId} />
            <Row label="Freeze" addr={m.data?.freeze} chainId={chainId} />
            <Row label="Disaster" addr={m.data?.disaster} chainId={chainId} />
            <Row label="Trace" addr={m.data?.trace} chainId={chainId} />
            <Row label="DocumentRegistry" addr={m.data?.documentRegistry} chainId={chainId} />
            <Row label="BatchAnchor" addr={batchAnchorAddress} chainId={chainId} />
            <Row label="Bridge" addr={m.data?.bridge} chainId={chainId} />
            <Row label="Marketplace" addr={m.data?.marketplace} chainId={chainId} />
            <Row label="Delivery" addr={m.data?.delivery} chainId={chainId} />
            <Row label="Insurance" addr={m.data?.insurance} chainId={chainId} />
          </>
        )}
      </CardContent>
    </Card>
  );
}
