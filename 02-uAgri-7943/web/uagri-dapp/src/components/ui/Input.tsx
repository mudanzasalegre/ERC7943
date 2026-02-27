import * as React from "react";
import { cn } from "@/lib/cn";

export function Input({ className, ...props }: React.InputHTMLAttributes<HTMLInputElement>) {
  return (
    <input
      className={cn(
        "h-11 w-full rounded-xl border border-border/90 bg-card px-3 text-sm text-text outline-none",
        "placeholder:text-text2 focus-visible:ring-2 focus-visible:ring-primary/30",
        className
      )}
      {...props}
    />
  );
}
