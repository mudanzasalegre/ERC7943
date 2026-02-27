"use client";

import * as React from "react";
import Link from "next/link";
import type { Route } from "next";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { Leaf } from "lucide-react";
import { usePathname } from "next/navigation";
import { cn } from "@/lib/cn";
import { useAppMode } from "@/hooks/useAppMode";
import { useMounted } from "@/hooks/useMounted";
import { useRoles } from "@/hooks/useRoles";

const baseNav: Array<{ href: Route; label: string }> = [
  { href: "/", label: "Dashboard" },
  { href: "/campaigns", label: "Campaigns" },
  { href: "/portfolio", label: "Portfolio" },
  { href: "/activity", label: "Activity" },
  { href: "/docs", label: "Docs" },
  { href: "/admin", label: "Admin" }
];

export default function Header() {
  const pathname = usePathname();
  const mode = useAppMode();
  const roleState = useRoles();
  const mounted = useMounted();
  const nav = React.useMemo(
    () => baseNav.filter((item) => item.href !== "/admin" || mode.mode === "demo" || roleState.canAccessAdmin),
    [mode.mode, roleState.canAccessAdmin]
  );

  return (
    <header className="sticky top-0 z-50 border-b border-border/80 bg-bg/88 backdrop-blur-md">
      <div className="mx-auto w-full max-w-[900px] px-4 md:px-6">
        <div className="flex h-16 items-center justify-between gap-3">
          <Link href="/" className="flex min-w-0 items-center gap-2" aria-label="Go to dashboard">
            <span className="inline-flex h-10 w-10 shrink-0 items-center justify-center rounded-xl border border-primary/25 bg-primary/10 text-primary shadow-soft">
              <Leaf size={18} />
            </span>
            <div className="min-w-0 leading-tight">
              <div className="truncate font-display text-sm font-semibold tracking-wide">uAgri</div>
              <div className="truncate text-[11px] text-text2">campaign tokens | settlement | trace</div>
            </div>
          </Link>

          <nav aria-label="Primary" className="hidden md:flex items-center gap-1">
            {nav.map((item) => {
              const active = pathname === item.href || (item.href !== "/" && pathname?.startsWith(item.href));
              return (
                <Link
                  key={item.href}
                  href={item.href}
                  aria-current={active ? "page" : undefined}
                  className={cn(
                    "rounded-xl px-3 py-2 text-sm font-medium transition",
                    active
                      ? "bg-card text-primary shadow-soft"
                      : "text-text2 hover:bg-card/70 hover:text-text"
                  )}
                >
                  {item.label}
                </Link>
              );
            })}
          </nav>

          <div className="flex items-center gap-2">
            <span
              className={cn(
                "hidden sm:inline-flex items-center rounded-full border px-2.5 py-1 text-[11px] font-semibold",
                mode.mode === "demo" ? "border-warn/30 bg-warn/10 text-warn" : "border-good/30 bg-good/10 text-good"
              )}
            >
              {mode.mode === "demo" ? "Demo mode" : "On-chain"}
            </span>
            {mode.mode !== "demo" ? (
              <span className="hidden sm:inline-flex items-center rounded-full border border-border/80 bg-muted px-2.5 py-1 text-[11px] font-semibold text-text2">
                {roleState.persona}
              </span>
            ) : null}

            {mounted ? (
              <ConnectButton showBalance={false} chainStatus="icon" accountStatus="avatar" />
            ) : (
              <div className="h-10 w-[132px] rounded-xl border border-border bg-card" aria-hidden="true" />
            )}
          </div>
        </div>
      </div>
    </header>
  );
}
