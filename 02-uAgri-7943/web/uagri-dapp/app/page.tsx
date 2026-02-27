import { PageHeader } from "@/components/ui/PageHeader";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/Card";
import { Badge } from "@/components/ui/Badge";
import Link from "next/link";

export default function HomePage() {
  return (
    <div>
      <PageHeader
        title="Dashboard"
        subtitle="A production-grade UI skeleton for uAgri-7943: campaigns, tokens, settlement, treasury, distribution, compliance, disaster and traceability."
        right={
          <Link className="rounded-xl border border-border bg-card px-3 py-2 text-sm hover:bg-muted" href="/campaigns">
            Open campaigns
          </Link>
        }
      />

      <div className="grid gap-4 md:grid-cols-3">
        <Card className="md:col-span-2">
          <CardHeader>
            <CardTitle>Quick start</CardTitle>
            <CardDescription>Run in demo mode instantly, or configure on-chain mode with your deployed addresses.</CardDescription>
          </CardHeader>
          <CardContent className="space-y-2 text-sm text-text2">
            <div className="flex items-center gap-2">
              <Badge tone="warn">Demo</Badge>
              <span>No env variables required. Uses mock campaigns and safe UI defaults.</span>
            </div>
            <div className="flex items-center gap-2">
              <Badge tone="good">On-chain</Badge>
              <span>Set chain-specific address book vars in .env.local (Base and/or Base Sepolia).</span>
            </div>
            <div className="mt-3 rounded-xl border border-border bg-muted p-3 text-xs">
              This frontend discovers campaigns with <span className="font-medium text-text">Factory-first logs</span> (CampaignDeployed + stacks(campaignId)), falls back to CampaignRegistry events when needed, and switches to deterministic demo data if no addresses are configured.
            </div>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Global states</CardTitle>
            <CardDescription>Wallet + network + tx UX</CardDescription>
          </CardHeader>
          <CardContent className="space-y-2 text-sm text-text2">
            <ul className="list-disc pl-4 space-y-1">
              <li>Wallet: disconnected / connected / wrong network / read-only</li>
              <li>Tx modal + toast: pending / success / error</li>
              <li>Skeleton loaders, empty states, retry on errors</li>
            </ul>
            <div className="pt-2">
              <Link className="text-primary hover:underline" href="/docs">
                See docs →
              </Link>
            </div>
          </CardContent>
        </Card>
      </div>

      <div className="mt-6 grid gap-4 md:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle>Campaign lifecycle</CardTitle>
            <CardDescription>Discover campaigns, inspect wiring, request settlement, claim rewards.</CardDescription>
          </CardHeader>
          <CardContent className="text-sm text-text2">
            Go to <Link className="text-primary hover:underline" href="/campaigns">Campaigns</Link> to open a campaign detail page and interact with SettlementQueue and Distribution.
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Admin console</CardTitle>
            <CardDescription>Roles, treasury, settlement processing, disaster, trace/docs.</CardDescription>
          </CardHeader>
          <CardContent className="text-sm text-text2">
            Admin pages are ready for wiring. You can run them in demo mode (UI only) or on-chain once your modules are deployed.
          </CardContent>
        </Card>
      </div>
    </div>
  );
}
