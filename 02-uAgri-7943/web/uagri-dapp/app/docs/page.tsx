import { PageHeader } from "@/components/ui/PageHeader";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/Card";

export default function DocsPage() {
  return (
    <div>
      <PageHeader title="Docs" subtitle="How this frontend maps to the uAgri contracts and how to run it." />

      <div className="grid gap-4">
        <Card>
          <CardHeader>
            <CardTitle>Run</CardTitle>
            <CardDescription>Demo mode works with zero address configuration.</CardDescription>
          </CardHeader>
          <CardContent className="space-y-2 text-sm text-text2">
            <ol className="list-decimal pl-5 space-y-1">
              <li>Install: <span className="font-mono">npm install</span></li>
              <li>Dev: <span className="font-mono">npm run dev</span></li>
              <li>Open: <span className="font-mono">http://localhost:3000</span></li>
            </ol>
            <div className="rounded-xl border border-border bg-muted p-3 text-xs">
              Demo mode is active for the current chain whenever CampaignFactory/CampaignRegistry is missing.
            </div>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>On-chain configuration</CardTitle>
            <CardDescription>Set these in <span className="font-mono">.env.local</span>.</CardDescription>
          </CardHeader>
          <CardContent className="space-y-2 text-sm text-text2">
            <ul className="list-disc pl-5 space-y-1">
              <li><span className="font-mono">NEXT_PUBLIC_BASE_MAINNET_CAMPAIGN_FACTORY</span> - Base factory</li>
              <li><span className="font-mono">NEXT_PUBLIC_BASE_MAINNET_CAMPAIGN_REGISTRY</span> - Base registry fallback</li>
              <li><span className="font-mono">NEXT_PUBLIC_BASE_MAINNET_ROLE_MANAGER</span> - Base RoleManager</li>
              <li><span className="font-mono">NEXT_PUBLIC_BASE_SEPOLIA_CAMPAIGN_FACTORY</span> - Base Sepolia factory</li>
              <li><span className="font-mono">NEXT_PUBLIC_BASE_SEPOLIA_CAMPAIGN_REGISTRY</span> - Base Sepolia registry fallback</li>
              <li><span className="font-mono">NEXT_PUBLIC_BASE_SEPOLIA_ROLE_MANAGER</span> - Base Sepolia RoleManager</li>
              <li><span className="font-mono">NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID</span> - optional (WalletConnect)</li>
              <li><span className="font-mono">NEXT_PUBLIC_DISCOVERY_FROM_BLOCK</span> - optional log scan start block</li>
            </ul>
            <div className="rounded-xl border border-border bg-muted p-3 text-xs">
              Discovery is factory-first per chain: <span className="font-medium text-text">CampaignDeployed + stacks(campaignId)</span>.
              If factory is missing, registry fallback is used: <span className="font-medium text-text">CampaignCreated + registry.getCampaign(campaignId)</span>.
            </div>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Contract mapping</CardTitle>
            <CardDescription>UI sections to contracts/modules.</CardDescription>
          </CardHeader>
          <CardContent className="space-y-2 text-sm text-text2">
            <ul className="list-disc pl-5 space-y-1">
              <li><span className="font-medium text-text">Campaigns</span>: CampaignFactory/Registry (events + reads)</li>
              <li><span className="font-medium text-text">Campaign detail</span>: ShareToken module wiring via IAgriModulesV1</li>
              <li><span className="font-medium text-text">Funding/Redeem</span>: SettlementQueue</li>
              <li><span className="font-medium text-text">Rewards</span>: Distribution</li>
              <li><span className="font-medium text-text">Admin</span>: RoleManager + Treasury + Disaster + Trace + DocumentRegistry</li>
            </ul>
          </CardContent>
        </Card>
      </div>
    </div>
  );
}
