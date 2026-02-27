import Link from "next/link";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/Card";
import { Badge } from "@/components/ui/Badge";
import { shortHex32 } from "@/lib/format";
import type { CampaignView } from "@/hooks/useCampaigns";

const stateLabel = ["FUNDING", "ACTIVE", "HARVESTED", "SETTLED", "CLOSED"] as const;

export function CampaignCard({ c }: { c: CampaignView }) {
  const label = stateLabel[c.state] ?? "UNKNOWN";
  const tone = c.state === 0 ? "good" : c.state === 4 ? "bad" : "default";

  return (
    <Link href={`/campaigns/${c.campaignId}`}>
      <Card className="hover:shadow-soft transition">
        <CardHeader className="flex flex-row items-start justify-between gap-3">
          <div>
            <CardTitle>Campaign {shortHex32(c.campaignId)}</CardTitle>
            <CardDescription>Plot {shortHex32(c.plotRef)} · Settlement {c.settlementAsset.slice(0, 6)}…</CardDescription>
          </div>
          <Badge tone={tone as any}>{label}</Badge>
        </CardHeader>
        <CardContent className="flex items-center justify-between gap-3">
          <div className="text-sm text-text2">
            {c.tokenMeta?.symbol ? (
              <span className="font-medium text-text">{c.tokenMeta.symbol}</span>
            ) : c.stack?.shareToken ? (
              <span className="font-mono">{c.stack.shareToken.slice(0, 6)}…</span>
            ) : (
              <span>ShareToken: unknown</span>
            )}
          </div>
          <div className="text-xs text-text2">Open</div>
        </CardContent>
      </Card>
    </Link>
  );
}
