import { Inbox } from "lucide-react";
import { Button } from "./Button";
import { Card, CardContent } from "./Card";

export function EmptyState({
  title,
  description,
  ctaLabel,
  onCta
}: {
  title: string;
  description?: string;
  ctaLabel?: string;
  onCta?: () => void;
}) {
  return (
    <Card>
      <CardContent className="flex flex-col items-start gap-3 text-left md:items-center md:text-center">
        <span className="inline-flex h-10 w-10 items-center justify-center rounded-xl border border-border bg-muted text-text2">
          <Inbox size={18} aria-hidden="true" />
        </span>
        <div className="text-sm font-semibold">{title}</div>
        {description ? <div className="max-w-[56ch] text-sm text-text2">{description}</div> : null}
        {ctaLabel && onCta ? (
          <Button className="mt-1" variant="secondary" onClick={onCta}>
            {ctaLabel}
          </Button>
        ) : null}
      </CardContent>
    </Card>
  );
}
