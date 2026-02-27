"use client";

import Link from "next/link";
import { PageHeader } from "@/components/ui/PageHeader";
import { useAccount } from "wagmi";
import { EmptyState } from "@/components/ui/EmptyState";
import { ErrorState } from "@/components/ui/ErrorState";
import { Skeleton } from "@/components/ui/Skeleton";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/Card";
import { Badge } from "@/components/ui/Badge";
import { usePortfolio } from "@/hooks/usePortfolio";
import { shortHex32 } from "@/lib/format";

export default function PortfolioPage() {
  const { isConnected } = useAccount();
  const portfolio = usePortfolio();

  return (
    <div>
      <PageHeader title="Portfolio" subtitle="Your ShareToken balances across discovered campaigns." />

      {!isConnected ? (
        <EmptyState title="Connect your wallet" description="Portfolio requires a connected wallet." />
      ) : portfolio.isLoading ? (
        <div className="grid gap-3 md:grid-cols-2">
          <Skeleton className="h-28" />
          <Skeleton className="h-28" />
        </div>
      ) : portfolio.error ? (
        <ErrorState title="Failed to load portfolio" description={(portfolio.error as any)?.message} onRetry={() => portfolio.refetch()} />
      ) : (portfolio.data?.length ?? 0) === 0 ? (
        <EmptyState title="No holdings yet" description="Once you request deposits and they are processed, you will see balances here." />
      ) : (
        <div className="grid gap-3 md:grid-cols-2">
          {portfolio.data!.map((h) => (
            <Link key={h.campaignId} href={`/campaigns/${h.campaignId}`}>
              <Card className="hover:shadow-soft transition">
                <CardHeader className="flex flex-row items-start justify-between gap-3">
                  <div>
                    <CardTitle>{h.symbol ?? "ShareToken"}</CardTitle>
                    <CardDescription>Campaign {shortHex32(h.campaignId)}</CardDescription>
                  </div>
                  <Badge tone={h.balance > 0n ? "good" : "default"}>{h.balance.toString()}</Badge>
                </CardHeader>
                <CardContent className="text-xs text-text2 font-mono break-all">{h.token}</CardContent>
              </Card>
            </Link>
          ))}
        </div>
      )}
    </div>
  );
}
