"use client";

import * as React from "react";
import Link from "next/link";
import type { Route } from "next";
import { PageHeader } from "@/components/ui/PageHeader";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/Card";
import { Badge } from "@/components/ui/Badge";
import { Tabs } from "@/components/ui/Tabs";
import { useAppMode } from "@/hooks/useAppMode";
import { useRoles } from "@/hooks/useRoles";

type AdminItem = {
  href: Route;
  title: string;
  desc: string;
  group: "ops" | "governance" | "critical";
  access: "org" | "ops" | "admin";
};

const items: AdminItem[] = [
  { href: "/admin/explorer", title: "Admin Explorer", desc: "Pick a campaign and jump to module addresses.", group: "ops", access: "org" },
  { href: "/admin/factory", title: "Factory", desc: "Create campaigns via CampaignFactory (createCampaign).", group: "governance", access: "admin" },
  { href: "/admin/contract-tool", title: "Contract Tool", desc: "Generic read/write for any contract and ABI.", group: "ops", access: "ops" },
  { href: "/admin/roles", title: "Roles", desc: "Grant/revoke with role presets and member lists.", group: "governance", access: "admin" },
  { href: "/admin/settlement", title: "Settlement", desc: "Process SettlementQueue requests (batchProcess).", group: "ops", access: "ops" },
  { href: "/admin/onramp", title: "OnRamp FIAT", desc: "Sponsored deposits with idempotent ref.", group: "ops", access: "ops" },
  { href: "/admin/payouts", title: "Payouts", desc: "Execute claimToWithSig and confirmPayout with reconciliation by ref.", group: "ops", access: "ops" },
  { href: "/admin/liquidations", title: "Liquidations", desc: "Sequential notifyReward with report hash guardrails.", group: "ops", access: "ops" },
  { href: "/admin/oracles", title: "Oracles", desc: "Hash/sign/publish/verify harvest, sales, custody and disaster reports.", group: "ops", access: "ops" },
  { href: "/admin/treasury", title: "Treasury", desc: "Note inflows and pay out with purpose tags.", group: "ops", access: "ops" },
  { href: "/admin/disaster", title: "Disaster", desc: "Declare/confirm/clear with double-confirm and critical timeline.", group: "critical", access: "admin" },
  { href: "/admin/trace", title: "Trace and Docs", desc: "Trace timeline, docs register/verify, and merkle anchors.", group: "critical", access: "org" }
];

export default function AdminPage() {
  const mode = useAppMode();
  const roleState = useRoles();
  const [group, setGroup] = React.useState<"all" | "ops" | "governance" | "critical">("all");

  const canAccess = React.useCallback(
    (access: AdminItem["access"]) => {
      if (mode.mode === "demo") return true;
      if (roleState.isAdmin) return true;
      if (roleState.isOps) return access === "ops" || access === "org";
      if (roleState.isOrg) return access === "org";
      return false;
    },
    [mode.mode, roleState.isAdmin, roleState.isOps, roleState.isOrg]
  );

  const visible = React.useMemo(() => items.filter((x) => canAccess(x.access)), [canAccess]);

  const filtered = React.useMemo(
    () => (group === "all" ? visible : visible.filter((x) => x.group === group)),
    [group, visible]
  );

  const tabs = React.useMemo(
    () => [
      { value: "all", label: "All", count: visible.length },
      { value: "ops", label: "Ops", count: visible.filter((x) => x.group === "ops").length },
      { value: "governance", label: "Governance", count: visible.filter((x) => x.group === "governance").length },
      { value: "critical", label: "Critical", count: visible.filter((x) => x.group === "critical").length }
    ],
    [visible]
  );

  return (
    <div>
      <PageHeader
        title="Admin"
        subtitle="Operational console. Use the right on-chain role before executing actions."
      />

      <div className="mb-4 flex flex-wrap items-center gap-2">
        <Badge tone={mode.mode === "demo" ? "warn" : "good"}>
          {mode.mode === "demo" ? "Demo mode: UI only" : "On-chain mode"}
        </Badge>
        <Badge tone="accent">Grouped by operational risk</Badge>
        <Badge tone={roleState.persona === "admin" ? "good" : roleState.persona === "ops" ? "accent" : "default"}>
          Persona: {mode.mode === "demo" ? "demo" : roleState.persona}
        </Badge>
      </div>

      <Tabs
        ariaLabel="Filter admin tools"
        items={tabs}
        value={group}
        onChange={(v) => setGroup(v as any)}
        className="mb-4"
      />

      {(filtered.length ?? 0) === 0 ? (
        <Card>
          <CardContent className="p-5 text-sm text-text2">
            No admin tools available for this wallet persona on current chain.
          </CardContent>
        </Card>
      ) : (
        <div className="grid gap-3 md:grid-cols-2">
          {filtered.map((x) => (
            <Link key={x.href} href={x.href}>
              <Card className="h-full transition hover:-translate-y-px hover:shadow-soft">
                <CardHeader className="flex flex-row items-start justify-between gap-3">
                  <div>
                    <CardTitle>{x.title}</CardTitle>
                    <CardDescription>{x.desc}</CardDescription>
                  </div>
                  <div className="flex flex-col items-end gap-1">
                    <Badge tone={x.group === "critical" ? "bad" : x.group === "governance" ? "accent" : "default"}>
                      {x.group}
                    </Badge>
                    <Badge tone={x.access === "admin" ? "bad" : x.access === "ops" ? "accent" : "default"}>
                      {x.access}
                    </Badge>
                  </div>
                </CardHeader>
                <CardContent className="text-xs text-text2">
                  Tip: open a campaign first, copy module addresses, then jump into these tools.
                </CardContent>
              </Card>
            </Link>
          ))}
        </div>
      )}
    </div>
  );
}
