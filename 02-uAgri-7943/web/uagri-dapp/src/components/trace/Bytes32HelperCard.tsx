"use client";

import * as React from "react";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { Button } from "@/components/ui/Button";
import { Badge } from "@/components/ui/Badge";
import { bytes32FromText, keccakBytes32 } from "@/lib/bytes32";

export function Bytes32HelperCard({
  title = "bytes32 helper",
  description = "Convert plain text into bytes32 or keccak hash.",
  onUseBytes32,
  onUseKeccak
}: {
  title?: string;
  description?: string;
  onUseBytes32?: (value: `0x${string}`) => void;
  onUseKeccak?: (value: `0x${string}`) => void;
}) {
  const [text, setText] = React.useState("");

  const bytes32 = React.useMemo(() => bytes32FromText(text), [text]);
  const keccak = React.useMemo(() => keccakBytes32(text), [text]);
  const tooLong = !bytes32 && text.length > 0;

  return (
    <Card>
      <CardHeader>
        <CardTitle>{title}</CardTitle>
        <CardDescription>{description}</CardDescription>
      </CardHeader>
      <CardContent className="space-y-3">
        <Input
          value={text}
          onChange={(e) => setText(e.target.value)}
          placeholder="Human text label"
          aria-label="Human text label"
        />

        <div className="rounded-xl border border-border bg-muted p-3">
          <div className="text-xs text-text2">bytes32 padded</div>
          <div className="mt-1 break-all font-mono text-xs">{bytes32 ?? "Input must fit in 32 bytes (UTF-8)."}</div>
          <div className="mt-2 flex flex-wrap gap-2">
            <Button size="sm" variant="secondary" disabled={!bytes32} onClick={() => bytes32 && navigator.clipboard.writeText(bytes32)}>
              Copy bytes32
            </Button>
            {onUseBytes32 ? (
              <Button size="sm" variant="secondary" disabled={!bytes32} onClick={() => bytes32 && onUseBytes32(bytes32)}>
                Use bytes32
              </Button>
            ) : null}
          </div>
        </div>

        <div className="rounded-xl border border-border bg-muted p-3">
          <div className="text-xs text-text2">keccak256(text)</div>
          <div className="mt-1 break-all font-mono text-xs">{keccak}</div>
          <div className="mt-2 flex flex-wrap gap-2">
            <Button size="sm" variant="secondary" onClick={() => navigator.clipboard.writeText(keccak)}>
              Copy keccak
            </Button>
            {onUseKeccak ? (
              <Button size="sm" variant="secondary" onClick={() => onUseKeccak(keccak)}>
                Use keccak
              </Button>
            ) : null}
          </div>
        </div>

        {tooLong ? <Badge tone="warn">Input is too long for bytes32 padded conversion.</Badge> : null}
      </CardContent>
    </Card>
  );
}

