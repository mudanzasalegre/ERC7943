import * as React from "react";

export function PageHeader({
  title,
  subtitle,
  right
}: {
  title: string;
  subtitle?: string;
  right?: React.ReactNode;
}) {
  return (
    <div className="mb-4 mt-5 flex flex-col gap-2 md:mb-6 md:mt-7 md:flex-row md:items-end md:justify-between">
      <div className="min-w-0">
        <h1 className="font-display text-2xl font-semibold tracking-wide md:text-3xl">{title}</h1>
        {subtitle ? <p className="mt-1 text-sm text-text2 md:text-[15px]">{subtitle}</p> : null}
      </div>
      {right ? <div className="shrink-0">{right}</div> : null}
    </div>
  );
}
