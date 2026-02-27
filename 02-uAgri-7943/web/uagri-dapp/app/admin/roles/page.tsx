"use client";

import * as React from "react";
import { useQuery } from "@tanstack/react-query";
import { isAddress } from "viem";
import { useAccount, useChainId, usePublicClient } from "wagmi";
import { PageHeader } from "@/components/ui/PageHeader";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { Button } from "@/components/ui/Button";
import { Badge } from "@/components/ui/Badge";
import { roleManagerAbi } from "@/lib/abi";
import { resolveAddressesForChain } from "@/lib/addresses";
import { roleByKey, rolePresets, roles, type RolePresetKey } from "@/lib/roles";
import { useTx } from "@/hooks/useTx";
import { useAppMode } from "@/hooks/useAppMode";
import { useRoles } from "@/hooks/useRoles";
import { shortAddr } from "@/lib/format";

function canAddr(v: string): v is `0x${string}` {
  return isAddress(v);
}

export default function AdminRolesPage() {
  const chainId = useChainId();
  const chainAddresses = React.useMemo(() => resolveAddressesForChain(chainId), [chainId]);
  const mode = useAppMode();
  const client = usePublicClient();
  const { address, isConnected } = useAccount();
  const { sendTx } = useTx();

  const [roleManagerFromQuery, setRoleManagerFromQuery] = React.useState<string>("");
  React.useEffect(() => {
    if (typeof window === "undefined") return;
    const value = new URLSearchParams(window.location.search).get("addr") ?? "";
    setRoleManagerFromQuery(value);
  }, []);

  const roleManager = canAddr(roleManagerFromQuery) ? roleManagerFromQuery : chainAddresses.roleManager;
  const roleState = useRoles({ roleManager });

  const [targetAccount, setTargetAccount] = React.useState<string>("");
  const [roleKey, setRoleKey] = React.useState(roles[1]?.key ?? "GUARDIAN_ROLE");
  const [presetKey, setPresetKey] = React.useState<RolePresetKey>("ops");

  const selected = roles.find((r) => r.key === roleKey) ?? roles[0];
  const validTarget = canAddr(targetAccount);
  const activePreset = rolePresets[presetKey];
  const presetRoles = activePreset.keys.map((k) => roleByKey[k]).filter(Boolean);

  const hasTargetRole = useQuery({
    queryKey: ["hasTargetRole", roleManager, selected.role, targetAccount],
    enabled: !!client && !!roleManager && validTarget,
    queryFn: async () => {
      if (!client || !roleManager || !validTarget) return false;
      return Boolean(
        await client.readContract({
          address: roleManager,
          abi: roleManagerAbi,
          functionName: "hasRole",
          args: [selected.role, targetAccount]
        }).catch(() => false)
      );
    }
  });

  const members = useQuery({
    queryKey: ["roleMembers", roleManager, selected.role],
    enabled: !!client && !!roleManager,
    queryFn: async () => {
      if (!client || !roleManager) return { count: 0n, addrs: [] as string[] };
      const count = (await client.readContract({
        address: roleManager,
        abi: roleManagerAbi,
        functionName: "roleMemberCount",
        args: [selected.role]
      }).catch(() => 0n)) as bigint;

      const max = Number(count > 50n ? 50n : count);
      const addrs: string[] = [];
      for (let i = 0; i < max; i++) {
        const a = (await client.readContract({
          address: roleManager,
          abi: roleManagerAbi,
          functionName: "roleMember",
          args: [selected.role, BigInt(i)]
        }).catch(() => "")) as string;
        if (canAddr(a)) addrs.push(a);
      }
      return { count, addrs };
    }
  });

  const grantRole = async () => {
    if (!roleManager || !validTarget) return;
    await sendTx({
      title: `Grant ${selected.key}`,
      address: roleManager,
      abi: roleManagerAbi,
      functionName: "grantRole",
      args: [selected.role, targetAccount]
    } as any);
    await Promise.all([hasTargetRole.refetch(), members.refetch()]);
  };

  const revokeRole = async () => {
    if (!roleManager || !validTarget) return;
    await sendTx({
      title: `Revoke ${selected.key}`,
      address: roleManager,
      abi: roleManagerAbi,
      functionName: "revokeRole",
      args: [selected.role, targetAccount]
    } as any);
    await Promise.all([hasTargetRole.refetch(), members.refetch()]);
  };

  const grantPreset = async () => {
    if (!roleManager || !validTarget) return;
    for (const r of presetRoles) {
      await sendTx({
        title: `Grant preset - ${r.key}`,
        address: roleManager,
        abi: roleManagerAbi,
        functionName: "grantRole",
        args: [r.role, targetAccount]
      } as any);
    }
    await Promise.all([hasTargetRole.refetch(), members.refetch(), roleState.refetch()]);
  };

  const revokePreset = async () => {
    if (!roleManager || !validTarget) return;
    for (const r of presetRoles) {
      await sendTx({
        title: `Revoke preset - ${r.key}`,
        address: roleManager,
        abi: roleManagerAbi,
        functionName: "revokeRole",
        args: [r.role, targetAccount]
      } as any);
    }
    await Promise.all([hasTargetRole.refetch(), members.refetch(), roleState.refetch()]);
  };

  return (
    <div>
      <PageHeader title="Admin - Roles" subtitle="RBAC console: presets, grant/revoke, and member discovery." />

      {!roleManager ? (
        <Card>
          <CardContent className="p-5 text-sm text-text2">
            Missing RoleManager for {chainAddresses.chainName}. Configure address book env values or open with{" "}
            <span className="font-mono">?addr=0x...</span>.
          </CardContent>
        </Card>
      ) : (
        <div className="grid gap-4">
          <Card>
            <CardHeader>
              <CardTitle>Current Wallet RBAC</CardTitle>
              <CardDescription>
                Connected: {isConnected && address ? <span className="font-mono">{shortAddr(address, 6)}</span> : "-"} -
                Mode:
                <Badge tone={mode.mode === "demo" ? "warn" : "good"} className="ml-2">
                  {mode.mode}
                </Badge>
              </CardDescription>
            </CardHeader>
            <CardContent className="space-y-3">
              <div className="flex flex-wrap gap-2">
                <Badge tone={roleState.persona === "admin" ? "good" : roleState.persona === "ops" ? "accent" : "default"}>
                  persona: {roleState.persona}
                </Badge>
                <Badge tone={roleState.canAccessGovernance ? "good" : "warn"}>
                  {roleState.canAccessGovernance ? "governance access" : "governance denied"}
                </Badge>
                <Badge tone={roleState.canAccessAdmin ? "good" : "warn"}>
                  {roleState.canAccessAdmin ? "admin access" : "admin denied"}
                </Badge>
              </div>
              <div className="flex flex-wrap gap-2">
                {roles
                  .filter((r) => roleState.hasRole(r.key))
                  .map((r) => (
                    <Badge key={r.key} tone="good">
                      {r.label}
                    </Badge>
                  ))}
                {!roleState.isLoading && roles.filter((r) => roleState.hasRole(r.key)).length === 0 ? (
                  <Badge tone="default">No roles detected</Badge>
                ) : null}
              </div>
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle>Role Presets</CardTitle>
              <CardDescription>Apply role bundles for org manager, ops, or admin governance.</CardDescription>
            </CardHeader>
            <CardContent className="space-y-3">
              <div className="grid gap-2 md:grid-cols-2">
                <div>
                  <div className="mb-1 text-xs text-text2">Target account</div>
                  <Input value={targetAccount} onChange={(e) => setTargetAccount(e.target.value)} placeholder="0x..." />
                </div>
                <div>
                  <div className="mb-1 text-xs text-text2">Preset</div>
                  <select
                    className="h-11 w-full rounded-xl border border-border bg-card px-3 text-sm outline-none focus:ring-2 focus:ring-primary/25"
                    value={presetKey}
                    onChange={(e) => setPresetKey(e.target.value as RolePresetKey)}
                  >
                    {Object.entries(rolePresets).map(([key, preset]) => (
                      <option key={key} value={key}>
                        {preset.label}
                      </option>
                    ))}
                  </select>
                </div>
              </div>

              <div className="rounded-xl border border-border bg-muted p-3 text-xs text-text2">
                <div className="font-medium text-text">{activePreset.label}</div>
                <div className="mt-1">{activePreset.description}</div>
                <div className="mt-2 flex flex-wrap gap-2">
                  {presetRoles.map((r) => (
                    <Badge key={r.key} tone="default">
                      {r.label}
                    </Badge>
                  ))}
                </div>
              </div>

              <div className="flex flex-wrap items-center gap-2">
                <Button onClick={grantPreset} disabled={!isConnected || !validTarget || !roleState.canAccessGovernance}>
                  Grant preset
                </Button>
                <Button variant="secondary" onClick={revokePreset} disabled={!isConnected || !validTarget || !roleState.canAccessGovernance}>
                  Revoke preset
                </Button>
                {!roleState.canAccessGovernance ? (
                  <Badge tone="warn" className="ml-auto">
                    Governance role required
                  </Badge>
                ) : null}
              </div>
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle>Single Role</CardTitle>
              <CardDescription>Grant/revoke one role and inspect target membership.</CardDescription>
            </CardHeader>
            <CardContent className="space-y-3">
              <div className="grid gap-2 md:grid-cols-2">
                <div>
                  <div className="mb-1 text-xs text-text2">Target account</div>
                  <Input value={targetAccount} onChange={(e) => setTargetAccount(e.target.value)} placeholder="0x..." />
                </div>
                <div>
                  <div className="mb-1 text-xs text-text2">Role</div>
                  <select
                    className="h-11 w-full rounded-xl border border-border bg-card px-3 text-sm outline-none focus:ring-2 focus:ring-primary/25"
                    value={roleKey}
                    onChange={(e) => setRoleKey(e.target.value)}
                  >
                    {roles.map((r) => (
                      <option key={r.key} value={r.key}>
                        {r.label}
                      </option>
                    ))}
                  </select>
                </div>
              </div>

              <div className="rounded-xl border border-border bg-muted p-3 text-xs text-text2">
                <div>
                  <span className="font-medium text-text">{selected.label}</span> - {selected.description}
                </div>
                <div className="mt-1 font-mono">{selected.role}</div>
              </div>

              <div className="flex flex-wrap items-center gap-2">
                <Button onClick={grantRole} disabled={!isConnected || !validTarget || !roleState.canAccessGovernance}>
                  Grant
                </Button>
                <Button variant="secondary" onClick={revokeRole} disabled={!isConnected || !validTarget || !roleState.canAccessGovernance}>
                  Revoke
                </Button>
                {validTarget ? (
                  <Badge tone={hasTargetRole.data ? "good" : "default"} className="ml-auto">
                    {hasTargetRole.isLoading ? "Checking..." : hasTargetRole.data ? "HAS ROLE" : "NO ROLE"}
                  </Badge>
                ) : (
                  <Badge className="ml-auto">Enter valid address</Badge>
                )}
              </div>
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle>Role Members</CardTitle>
              <CardDescription>List up to 50 members for selected role.</CardDescription>
            </CardHeader>
            <CardContent className="space-y-2">
              <div className="flex items-center justify-between text-sm">
                <span className="text-text2">Total members</span>
                <span className="font-mono">{members.isLoading ? "..." : members.data?.count.toString() ?? "0"}</span>
              </div>
              <div className="grid gap-2 md:grid-cols-2">
                {(members.data?.addrs ?? []).map((a) => (
                  <div key={a} className="rounded-xl border border-border bg-card px-3 py-2 font-mono text-sm">
                    {shortAddr(a, 8)}
                  </div>
                ))}
                {members.isLoading ? <div className="text-sm text-text2">Loading...</div> : null}
                {!members.isLoading && (members.data?.addrs?.length ?? 0) === 0 ? (
                  <div className="text-sm text-text2">No members.</div>
                ) : null}
              </div>
            </CardContent>
          </Card>
        </div>
      )}
    </div>
  );
}
