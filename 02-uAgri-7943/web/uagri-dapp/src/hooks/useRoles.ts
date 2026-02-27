"use client";

import * as React from "react";
import { useQuery } from "@tanstack/react-query";
import { useAccount, useChainId, usePublicClient } from "wagmi";
import { roleManagerAbi } from "@/lib/abi";
import { resolveAddressesForChain } from "@/lib/addresses";
import { rolePresets, roles } from "@/lib/roles";

export type AppPersona = "user" | "org" | "ops" | "admin";

type UseRolesOptions = {
  roleManager?: `0x${string}`;
  enabled?: boolean;
  staleTimeMs?: number;
  refetchIntervalMs?: number;
};

type RolesQueryResult = {
  byKey: Record<string, boolean>;
};

const DEFAULT_STALE_MS = 30_000;
const DEFAULT_REFETCH_MS = 45_000;

export function useRoles(options: UseRolesOptions = {}) {
  const chainId = useChainId();
  const client = usePublicClient();
  const { address, isConnected } = useAccount();
  const book = React.useMemo(() => resolveAddressesForChain(chainId), [chainId]);
  const roleManager = options.roleManager ?? book.roleManager;
  const enabled = options.enabled ?? true;
  const staleTime = options.staleTimeMs ?? DEFAULT_STALE_MS;
  const refetchInterval = options.refetchIntervalMs ?? DEFAULT_REFETCH_MS;

  const query = useQuery({
    queryKey: ["useRoles", chainId, roleManager ?? "none", address ?? "none"],
    enabled: enabled && Boolean(client) && Boolean(roleManager) && Boolean(address),
    staleTime,
    refetchInterval,
    queryFn: async (): Promise<RolesQueryResult> => {
      if (!client || !roleManager || !address) return { byKey: {} };

      const checks = await Promise.all(
        roles.map(async (r) => {
          const has = Boolean(
            await client
              .readContract({
                address: roleManager,
                abi: roleManagerAbi,
                functionName: "hasRole",
                args: [r.role, address]
              })
              .catch(() => false)
          );
          return [r.key, has] as const;
        })
      );

      return {
        byKey: Object.fromEntries(checks)
      };
    }
  });

  const byKey = query.data?.byKey ?? {};

  const hasRole = React.useCallback((key: string) => Boolean(byKey[key]), [byKey]);

  const orgKeys = rolePresets.org_manager.keys;
  const opsKeys = rolePresets.ops.keys;
  const adminKeys = rolePresets.admin_governance.keys;

  const isOrg = orgKeys.some((k) => hasRole(k));
  const isOps = opsKeys.some((k) => hasRole(k));
  const isAdmin = adminKeys.some((k) => hasRole(k));

  const persona: AppPersona = isAdmin ? "admin" : isOps ? "ops" : isOrg ? "org" : "user";
  const canAccessAdmin = isAdmin || isOps || isOrg;
  const canAccessGovernance = isAdmin;

  return {
    roleManager,
    chainId,
    address,
    isConnected,
    byKey,
    hasRole,
    persona,
    isOrg,
    isOps,
    isAdmin,
    canAccessAdmin,
    canAccessGovernance,
    isLoading: query.isLoading,
    isFetching: query.isFetching,
    isError: query.isError,
    error: query.error,
    refetch: query.refetch
  };
}
