import * as React from "react";
import { cn } from "@/lib/cn";

type Variant = "primary" | "secondary" | "ghost" | "danger" | "accent";
type Size = "sm" | "md" | "lg";

export function Button({
  className,
  variant = "primary",
  size = "md",
  type = "button",
  ...props
}: React.ButtonHTMLAttributes<HTMLButtonElement> & { variant?: Variant; size?: Size }) {
  return (
    <button
      type={type}
      className={cn(
        "inline-flex items-center justify-center gap-2 rounded-xl font-semibold transition focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/35 disabled:pointer-events-none disabled:opacity-50",
        size === "sm" && "h-9 px-3 text-sm",
        size === "md" && "h-11 px-4 text-sm",
        size === "lg" && "h-12 px-5 text-base",
        variant === "primary" && "bg-primary text-white shadow-soft hover:bg-primary2",
        variant === "accent" && "bg-accent text-[#33250c] shadow-soft hover:bg-accent2 hover:text-white",
        variant === "secondary" && "border border-border bg-card text-text hover:bg-muted",
        variant === "ghost" && "bg-transparent text-text2 hover:bg-card hover:text-text",
        variant === "danger" && "bg-bad text-white shadow-soft hover:opacity-90",
        className
      )}
      {...props}
    />
  );
}
