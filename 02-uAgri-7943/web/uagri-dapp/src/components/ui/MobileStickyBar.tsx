"use client";

import * as React from "react";
import { cn } from "@/lib/cn";

export function MobileStickyBar({
  children,
  className,
  testId,
  ariaLabel
}: {
  children: React.ReactNode;
  className?: string;
  testId?: string;
  ariaLabel?: string;
}) {
  return (
    <div
      data-testid={testId}
      role="region"
      aria-label={ariaLabel ?? "Sticky actions"}
      className="fixed inset-x-0 z-40 px-3 md:hidden"
      style={{ bottom: "calc(env(safe-area-inset-bottom) + 4.75rem)" }}
    >
      <div
        className={cn(
          "mx-auto max-w-[900px] rounded-2xl border border-border/90 bg-bg/95 p-2 shadow-soft backdrop-blur",
          className
        )}
      >
        {children}
      </div>
    </div>
  );
}
