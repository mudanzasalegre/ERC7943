import * as React from "react";
import { cn } from "@/lib/cn";

export default function Container({ children, className }: { children: React.ReactNode; className?: string }) {
  return (
    <div className={cn("mx-auto w-full max-w-[900px] px-4 md:px-6", className)}>
      {children}
    </div>
  );
}
