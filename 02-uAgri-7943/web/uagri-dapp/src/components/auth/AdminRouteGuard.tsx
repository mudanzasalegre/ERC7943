"use client";

import * as React from "react";
import { usePathname } from "next/navigation";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/Card";
import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { useAppMode } from "@/hooks/useAppMode";
import { useRoles } from "@/hooks/useRoles";

function governanceOnly(pathname: string): boolean {
  return pathname.startsWith("/admin/roles") || pathname.startsWith("/admin/factory");
}

export default function AdminRouteGuard({ children }: { children: React.ReactNode }) {
  const pathname = usePathname() ?? "/admin";
  const mode = useAppMode();
  const roles = useRoles();
  const needsGovernance = governanceOnly(pathname);

  if (mode.mode === "demo") {
    return <>{children}</>;
  }

  if (!roles.isConnected) {
    return (
      <Card>
        <CardHeader>
          <CardTitle>Admin Access Required</CardTitle>
          <CardDescription>Connect a wallet with an org/ops/admin role to access admin routes.</CardDescription>
        </CardHeader>
        <CardContent className="space-y-2">
          <Badge tone="warn">Disconnected</Badge>
        </CardContent>
      </Card>
    );
  }

  if (!roles.roleManager) {
    return (
      <Card>
        <CardHeader>
          <CardTitle>RoleManager Missing</CardTitle>
          <CardDescription>Cannot verify RBAC because no RoleManager is configured for this chain.</CardDescription>
        </CardHeader>
        <CardContent className="space-y-3">
          <Badge tone="warn">RBAC verification unavailable</Badge>
          <div className="text-sm text-text2">
            Configure `NEXT_PUBLIC_*_ROLE_MANAGER` and reload to enforce route-level permissions.
          </div>
          <div>
            <Button variant="secondary" onClick={() => window.location.reload()}>
              Reload
            </Button>
          </div>
        </CardContent>
      </Card>
    );
  }

  if (roles.isLoading || roles.isFetching) {
    return (
      <Card>
        <CardHeader>
          <CardTitle>Checking Roles</CardTitle>
          <CardDescription>Loading RBAC permissions from RoleManager...</CardDescription>
        </CardHeader>
        <CardContent>
          <Badge tone="default">Loading</Badge>
        </CardContent>
      </Card>
    );
  }

  if (needsGovernance && !roles.canAccessGovernance) {
    return (
      <Card>
        <CardHeader>
          <CardTitle>Governance Role Required</CardTitle>
          <CardDescription>This route is restricted to governance/admin wallets.</CardDescription>
        </CardHeader>
        <CardContent className="space-y-2">
          <Badge tone="bad">Access denied</Badge>
          <div className="text-sm text-text2">Current persona: {roles.persona}</div>
        </CardContent>
      </Card>
    );
  }

  if (!needsGovernance && !roles.canAccessAdmin) {
    return (
      <Card>
        <CardHeader>
          <CardTitle>Ops/Admin Role Required</CardTitle>
          <CardDescription>Admin routes are only available for org/ops/admin personas.</CardDescription>
        </CardHeader>
        <CardContent className="space-y-2">
          <Badge tone="bad">Access denied</Badge>
          <div className="text-sm text-text2">Current persona: {roles.persona}</div>
        </CardContent>
      </Card>
    );
  }

  return <>{children}</>;
}
