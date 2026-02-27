import { AlertTriangle } from "lucide-react";
import { Button } from "./Button";
import { Card, CardContent } from "./Card";

export function ErrorState({
  title,
  description,
  onRetry
}: {
  title: string;
  description?: string;
  onRetry?: () => void;
}) {
  return (
    <Card className="border-bad/30">
      <CardContent className="flex flex-col items-start gap-3" role="alert">
        <span className="inline-flex h-10 w-10 items-center justify-center rounded-xl border border-bad/35 bg-bad/10 text-bad">
          <AlertTriangle size={18} aria-hidden="true" />
        </span>
        <div className="text-sm font-semibold text-bad">{title}</div>
        {description ? <div className="max-w-[56ch] text-sm text-text2">{description}</div> : null}
        {onRetry ? (
          <Button className="mt-1" variant="secondary" onClick={onRetry}>
            Retry
          </Button>
        ) : null}
      </CardContent>
    </Card>
  );
}
