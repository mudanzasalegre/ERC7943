"use client";

import * as React from "react";
import Link from "next/link";
import type { Route } from "next";
import { usePathname } from "next/navigation";
import { LayoutGrid, Sprout, Wallet, Activity, FileText, Shield } from "lucide-react";
import { cn } from "@/lib/cn";
import { useAppMode } from "@/hooks/useAppMode";
import { useRoles } from "@/hooks/useRoles";

const baseTabs: Array<{ href: Route; label: string; icon: any }> = [
  { href: "/", label: "Home", icon: LayoutGrid },
  { href: "/campaigns", label: "Campaigns", icon: Sprout },
  { href: "/portfolio", label: "Portfolio", icon: Wallet },
  { href: "/activity", label: "Activity", icon: Activity },
  { href: "/docs", label: "Docs", icon: FileText },
  { href: "/admin", label: "Admin", icon: Shield }
];

export default function BottomNav() {
  const pathname = usePathname();
  const mode = useAppMode();
  const roleState = useRoles();
  const tabs = React.useMemo(
    () => baseTabs.filter((t) => t.href !== "/admin" || mode.mode === "demo" || roleState.canAccessAdmin),
    [mode.mode, roleState.canAccessAdmin]
  );

  return (
    <nav
      aria-label="Mobile"
      className="fixed inset-x-0 bottom-0 z-50 border-t border-border/90 bg-bg/95 backdrop-blur md:hidden"
    >
      <div className="mx-auto flex max-w-[900px] items-center justify-between px-2 pb-[max(env(safe-area-inset-bottom),0.5rem)] pt-2">
        {tabs.map((t) => {
          const active = pathname === t.href || (t.href !== "/" && pathname?.startsWith(t.href));
          const Icon = t.icon;
          return (
            <Link
              key={t.href}
              href={t.href}
              aria-current={active ? "page" : undefined}
              className={cn(
                "flex flex-1 flex-col items-center justify-center gap-1 rounded-xl px-1 py-2 text-[11px] font-medium transition",
                active ? "bg-card text-primary shadow-soft" : "text-text2"
              )}
            >
              <Icon size={18} aria-hidden="true" />
              <span className="truncate">{t.label}</span>
            </Link>
          );
        })}
      </div>
    </nav>
  );
}
