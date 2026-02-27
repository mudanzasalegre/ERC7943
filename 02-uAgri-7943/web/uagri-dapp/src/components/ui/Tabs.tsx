import * as React from "react";
import { cn } from "@/lib/cn";

export type TabItem = {
  value: string;
  label: string;
  count?: number;
};

export function Tabs({
  items,
  value,
  onChange,
  ariaLabel,
  className
}: {
  items: TabItem[];
  value: string;
  onChange: (value: string) => void;
  ariaLabel: string;
  className?: string;
}) {
  return (
    <div
      role="tablist"
      aria-label={ariaLabel}
      className={cn(
        "inline-flex w-full max-w-full items-center gap-1 overflow-x-auto rounded-xl border border-border/80 bg-card p-1",
        className
      )}
    >
      {items.map((item) => {
        const active = item.value === value;
        return (
          <button
            key={item.value}
            role="tab"
            type="button"
            aria-selected={active}
            tabIndex={active ? 0 : -1}
            className={cn(
              "inline-flex min-w-fit items-center gap-2 rounded-lg px-3 py-2 text-sm font-medium transition",
              active ? "bg-primary text-white" : "text-text2 hover:bg-muted hover:text-text"
            )}
            onClick={() => onChange(item.value)}
          >
            <span>{item.label}</span>
            {typeof item.count === "number" ? (
              <span
                className={cn(
                  "rounded-full px-1.5 py-0.5 text-[11px]",
                  active ? "bg-white/20 text-white" : "bg-muted text-text2"
                )}
              >
                {item.count}
              </span>
            ) : null}
          </button>
        );
      })}
    </div>
  );
}
