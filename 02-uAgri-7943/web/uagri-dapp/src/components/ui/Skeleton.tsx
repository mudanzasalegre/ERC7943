import { cn } from "@/lib/cn";

export function Skeleton({ className }: { className?: string }) {
  return (
    <div
      aria-hidden="true"
      className={cn(
        "relative overflow-hidden rounded-xl bg-muted",
        "before:absolute before:inset-y-0 before:-left-1/2 before:w-1/2 before:animate-pulse before:bg-gradient-to-r before:from-transparent before:via-white/35 before:to-transparent",
        className
      )}
    />
  );
}
