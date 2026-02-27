import * as React from "react";
import { cn } from "@/lib/cn";

export function Badge({
  className,
  tone = "default",
  ...props
}: React.HTMLAttributes<HTMLSpanElement> & { tone?: "default" | "good" | "warn" | "bad" | "accent" }) {
  const toneClass =
    tone === "good"
      ? "border-good/30 bg-good/10 text-good"
      : tone === "warn"
      ? "border-warn/30 bg-warn/10 text-warn"
      : tone === "bad"
      ? "border-bad/30 bg-bad/10 text-bad"
      : tone === "accent"
      ? "border-accent/35 bg-accent/15 text-accent2"
      : "border-border/90 bg-muted text-text2";

  return (
    <span
      className={cn("inline-flex items-center gap-1 rounded-full border px-2.5 py-1 text-[11px] font-medium", toneClass, className)}
      {...props}
    />
  );
}
