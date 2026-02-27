"use client";

import * as React from "react";
import * as Dialog from "@radix-ui/react-dialog";
import { AlertTriangle, ShieldAlert } from "lucide-react";
import { Button } from "@/components/ui/Button";
import { Card } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";

type CriticalActionDialogProps = {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  title: string;
  description: string;
  warnings: string[];
  requiredPhrase: string;
  confirmLabel: string;
  isSubmitting?: boolean;
  onConfirm: () => Promise<void> | void;
};

export function CriticalActionDialog(props: CriticalActionDialogProps) {
  const {
    open,
    onOpenChange,
    title,
    description,
    warnings,
    requiredPhrase,
    confirmLabel,
    isSubmitting,
    onConfirm
  } = props;

  const [step, setStep] = React.useState<1 | 2>(1);
  const [ack, setAck] = React.useState(false);
  const [phrase, setPhrase] = React.useState("");

  React.useEffect(() => {
    if (!open) {
      setStep(1);
      setAck(false);
      setPhrase("");
    }
  }, [open]);

  const canExecute = phrase.trim() === requiredPhrase.trim();

  return (
    <Dialog.Root open={open} onOpenChange={onOpenChange}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-[70] bg-black/45" />
        <Dialog.Content className="fixed left-1/2 top-1/2 z-[71] w-[92vw] max-w-[620px] -translate-x-1/2 -translate-y-1/2 outline-none">
          <Card className="p-5">
            <div className="flex items-start justify-between gap-4">
              <div className="flex items-start gap-3">
                <ShieldAlert className="mt-0.5 text-bad" />
                <div>
                  <Dialog.Title className="text-base font-semibold">{title}</Dialog.Title>
                  <Dialog.Description className="mt-1 text-sm text-text2">{description}</Dialog.Description>
                </div>
              </div>

              <Dialog.Close asChild>
                <button
                  aria-label="Close critical action dialog"
                  className="rounded-lg px-2 py-1 text-text2 hover:bg-muted focus-visible:ring-2 focus-visible:ring-primary/30"
                >
                  X
                </button>
              </Dialog.Close>
            </div>

            {step === 1 ? (
              <div className="mt-4 space-y-3">
                <div className="rounded-xl border border-bad/30 bg-bad/10 p-3">
                  <div className="text-sm font-semibold text-bad">Step 1/2 - Risk acknowledgment</div>
                  <ul className="mt-2 space-y-1 text-sm text-text">
                    {warnings.map((warning) => (
                      <li key={warning} className="flex items-start gap-2">
                        <AlertTriangle size={14} className="mt-0.5 text-bad" />
                        <span>{warning}</span>
                      </li>
                    ))}
                  </ul>
                </div>
                <label className="flex items-center gap-2 text-sm text-text">
                  <input
                    type="checkbox"
                    className="h-4 w-4 rounded border-border"
                    checked={ack}
                    onChange={(e) => setAck(e.target.checked)}
                  />
                  I reviewed the warnings and want to continue.
                </label>
              </div>
            ) : (
              <div className="mt-4 space-y-3">
                <div className="rounded-xl border border-warn/30 bg-warn/10 p-3 text-sm">
                  <div className="font-semibold text-text">Step 2/2 - Explicit confirmation</div>
                  <div className="mt-1 text-text2">
                    Type the exact phrase below to unlock this action.
                  </div>
                  <div className="mt-2 font-mono text-xs text-text">{requiredPhrase}</div>
                </div>
                <Input
                  value={phrase}
                  onChange={(e) => setPhrase(e.target.value)}
                  placeholder="Type confirmation phrase"
                />
              </div>
            )}

            <div className="mt-5 flex flex-wrap justify-end gap-2">
              {step === 2 ? (
                <Button variant="secondary" onClick={() => setStep(1)} disabled={Boolean(isSubmitting)}>
                  Back
                </Button>
              ) : null}
              {step === 1 ? (
                <Button variant="danger" onClick={() => setStep(2)} disabled={!ack}>
                  Continue
                </Button>
              ) : (
                <Button
                  variant="danger"
                  disabled={!canExecute || Boolean(isSubmitting)}
                  onClick={async () => {
                    await onConfirm();
                  }}
                >
                  {isSubmitting ? "Submitting..." : confirmLabel}
                </Button>
              )}
            </div>
          </Card>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}

