import * as React from "react";
import { cn } from "@/lib/cn";

export function Textarea({ className, ...props }: React.TextareaHTMLAttributes<HTMLTextAreaElement>) {
  return (
    <textarea
      className={cn(
        "min-h-[110px] w-full rounded-xl border border-border/90 bg-card px-3 py-2 text-sm text-text outline-none",
        "placeholder:text-text2 focus-visible:ring-2 focus-visible:ring-primary/30",
        className
      )}
      {...props}
    />
  );
}
