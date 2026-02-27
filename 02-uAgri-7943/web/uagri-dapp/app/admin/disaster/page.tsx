"use client";

import * as React from "react";
import { useQuery } from "@tanstack/react-query";
import { isAddress } from "viem";
import { useAccount, useChainId, usePublicClient } from "wagmi";
import { AlertTriangle } from "lucide-react";
import { PageHeader } from "@/components/ui/PageHeader";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { Button } from "@/components/ui/Button";
import { Badge } from "@/components/ui/Badge";
import { CriticalActionDialog } from "@/components/ui/CriticalActionDialog";
import { disasterAdminAbi } from "@/lib/abi";
import { explorerTxUrl } from "@/lib/explorer";
import { shortAddr, shortHex32 } from "@/lib/format";
import { useTx } from "@/hooks/useTx";
import { useCampaignDetails } from "@/hooks/useCampaignDetails";
import { useCriticalActivityTimeline } from "@/hooks/useCriticalActivityTimeline";

const EMPTY_B32 = `0x${"00".repeat(32)}`;
const BYTES32_HEX_RE = /^0x[0-9a-fA-F]{64}$/u;

type CriticalAction = "declare" | "confirm" | "clear" | null;

function isBytes32(value: string): value is `0x${string}` {
  return BYTES32_HEX_RE.test(value);
}

function parseUint8(value: string): number {
  const next = Number(value);
  if (!Number.isFinite(next) || next < 0 || next > 255) throw new Error("severity must be between 0 and 255");
  return Math.floor(next);
}

function parseUint64(value: string): bigint {
  const v = BigInt(value);
  if (v < 0n) throw new Error("ttl must be >= 0");
  return v;
}

function parseUint256(value: string): bigint {
  const v = BigInt(value);
  if (v < 0n) throw new Error("flags must be >= 0");
  return v;
}

function fmtTs(ts?: number): string {
  if (!ts || ts <= 0) return "Timestamp unavailable";
  return new Date(ts * 1000).toLocaleString();
}

export default function AdminDisasterPage() {
  const chainId = useChainId();
  const { isConnected } = useAccount();
  const client = usePublicClient();
  const { sendTx } = useTx();

  const [moduleAddr, setModuleAddr] = React.useState<string>("");
  const [shareTokenAddr, setShareTokenAddr] = React.useState<string>("");
  const [campaignId, setCampaignId] = React.useState<string>(EMPTY_B32);
  const [hazardCode, setHazardCode] = React.useState<string>(EMPTY_B32);
  const [severity, setSeverity] = React.useState<string>("1");
  const [reasonHash, setReasonHash] = React.useState<string>(EMPTY_B32);
  const [ttl, setTtl] = React.useState<string>("86400");

  const [flags, setFlags] = React.useState<string>("0");
  const [confirmSeverity, setConfirmSeverity] = React.useState<string>("1");

  const [activeAction, setActiveAction] = React.useState<CriticalAction>(null);
  const [isSubmitting, setIsSubmitting] = React.useState(false);
  const [actionError, setActionError] = React.useState<string>("");

  const validModule = isAddress(moduleAddr);
  const validToken = isAddress(shareTokenAddr);
  const validCampaign = isBytes32(campaignId);

  React.useEffect(() => {
    if (typeof window === "undefined") return;
    const q = new URLSearchParams(window.location.search);
    const addr = q.get("addr");
    const token = q.get("token");
    const cid = q.get("campaignId");
    if (addr && isAddress(addr) && !moduleAddr) setModuleAddr(addr);
    if (token && isAddress(token) && !shareTokenAddr) setShareTokenAddr(token);
    if (cid && isBytes32(cid) && campaignId === EMPTY_B32) setCampaignId(cid);
  }, [campaignId, moduleAddr, shareTokenAddr]);

  const campaign = useCampaignDetails(validCampaign ? campaignId : undefined);

  const discoveredDisaster = campaign.data?.stack?.disaster;
  const discoveredToken = campaign.data?.stack?.shareToken;

  const loadDiscoveredAddresses = React.useCallback(() => {
    if (discoveredDisaster && isAddress(discoveredDisaster)) setModuleAddr(discoveredDisaster);
    if (discoveredToken && isAddress(discoveredToken)) setShareTokenAddr(discoveredToken);
  }, [discoveredDisaster, discoveredToken]);

  const status = useQuery({
    queryKey: ["disasterStatus", moduleAddr, campaignId],
    enabled: Boolean(client && validModule && validCampaign),
    queryFn: async () => {
      if (!client || !validModule || !validCampaign) return null;
      const [disaster, flagsRaw, restrictedRaw, hardFrozenRaw] = await Promise.all([
        client
          .readContract({
            address: moduleAddr as `0x${string}`,
            abi: disasterAdminAbi,
            functionName: "getDisaster",
            args: [campaignId as `0x${string}`]
          })
          .catch(() => null),
        client
          .readContract({
            address: moduleAddr as `0x${string}`,
            abi: disasterAdminAbi,
            functionName: "campaignFlags",
            args: [campaignId as `0x${string}`]
          })
          .catch(() => 0n),
        client
          .readContract({
            address: moduleAddr as `0x${string}`,
            abi: disasterAdminAbi,
            functionName: "isRestricted",
            args: [campaignId as `0x${string}`]
          })
          .catch(() => false),
        client
          .readContract({
            address: moduleAddr as `0x${string}`,
            abi: disasterAdminAbi,
            functionName: "isHardFrozen",
            args: [campaignId as `0x${string}`]
          })
          .catch(() => false)
      ]);

      return {
        disaster: disaster as any,
        flags: BigInt(flagsRaw as bigint),
        restricted: Boolean(restrictedRaw),
        hardFrozen: Boolean(hardFrozenRaw)
      };
    }
  });

  const criticalTimeline = useCriticalActivityTimeline({
    disasterModule: validModule ? moduleAddr : undefined,
    shareToken: validToken ? shareTokenAddr : undefined,
    campaignId: validCampaign ? campaignId : undefined,
    enabled: true
  });

  const phraseSuffix = validCampaign ? campaignId.slice(2, 10).toUpperCase() : "CAMPAIGN";
  const requiredPhrase =
    activeAction === "declare"
      ? `DECLARE ${phraseSuffix}`
      : activeAction === "confirm"
      ? `CONFIRM ${phraseSuffix}`
      : activeAction === "clear"
      ? `CLEAR ${phraseSuffix}`
      : "";

  React.useEffect(() => {
    if (!activeAction) return;
    setActionError("");
  }, [activeAction]);

  const actionMeta = React.useMemo(() => {
    if (activeAction === "declare") {
      return {
        title: "Declare disaster (critical)",
        confirmLabel: "Declare disaster",
        warnings: [
          "This may block user operations depending on module flags.",
          "Incorrect hazard/severity can trigger governance escalations.",
          "Make sure reasonHash and TTL are approved by policy."
        ]
      };
    }
    if (activeAction === "confirm") {
      return {
        title: "Confirm disaster (critical)",
        confirmLabel: "Confirm disaster",
        warnings: [
          "Confirmation applies campaign flags immediately.",
          "Flags can pause claims, transfers, and funding paths.",
          "Verify severity and flags against approved incident ticket."
        ]
      };
    }
    return {
      title: "Clear disaster (critical)",
      confirmLabel: "Clear disaster",
      warnings: [
        "Clearing may re-enable user operations across the campaign.",
        "Do not clear until incident response is complete.",
        "Record reason and evidence before clearing."
      ]
    };
  }, [activeAction]);

  const executeAction = React.useCallback(async () => {
    if (!activeAction || !validModule || !validCampaign) return;

    setIsSubmitting(true);
    setActionError("");
    try {
      if (activeAction === "declare") {
        if (!isBytes32(hazardCode)) throw new Error("hazardCode must be bytes32");
        if (!isBytes32(reasonHash)) throw new Error("reasonHash must be bytes32");

        await sendTx({
          title: "Critical: declare disaster",
          address: moduleAddr as `0x${string}`,
          abi: disasterAdminAbi,
          functionName: "declareDisaster",
          args: [
            campaignId as `0x${string}`,
            hazardCode as `0x${string}`,
            parseUint8(severity),
            reasonHash as `0x${string}`,
            parseUint64(ttl)
          ]
        } as any);
      }

      if (activeAction === "confirm") {
        await sendTx({
          title: "Critical: confirm disaster",
          address: moduleAddr as `0x${string}`,
          abi: disasterAdminAbi,
          functionName: "confirmDisaster",
          args: [campaignId as `0x${string}`, parseUint256(flags), parseUint8(confirmSeverity)]
        } as any);
      }

      if (activeAction === "clear") {
        await sendTx({
          title: "Critical: clear disaster",
          address: moduleAddr as `0x${string}`,
          abi: disasterAdminAbi,
          functionName: "clearDisaster",
          args: [campaignId as `0x${string}`]
        } as any);
      }

      await Promise.all([status.refetch(), criticalTimeline.refetch()]);
      setActiveAction(null);
    } catch (error: any) {
      setActionError(error?.shortMessage || error?.message || "Critical action failed.");
    } finally {
      setIsSubmitting(false);
    }
  }, [
    activeAction,
    campaignId,
    confirmSeverity,
    criticalTimeline,
    flags,
    hazardCode,
    moduleAddr,
    reasonHash,
    sendTx,
    severity,
    status,
    ttl,
    validCampaign,
    validModule
  ]);

  const disasterState = status.data?.disaster as any;

  return (
    <div>
      <PageHeader
        title="Admin - Disaster"
        subtitle="Guardian-grade controls for disaster/freeze operations with mandatory double confirmation."
      />

      <div className="grid gap-4">
        <Card className="border-bad/35">
          <CardContent className="p-4">
            <div className="flex items-start gap-2 text-sm">
              <AlertTriangle size={16} className="mt-0.5 text-bad" />
              <div>
                <div className="font-semibold text-bad">Critical operations zone</div>
                <div className="text-text2">
                  Every write action requires two-step confirmation. Execute only with approved incident ticket.
                </div>
              </div>
            </div>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Target</CardTitle>
            <CardDescription>Select module addresses and campaign context for disaster operations.</CardDescription>
          </CardHeader>
          <CardContent className="grid gap-3">
            <div className="grid gap-2 md:grid-cols-2">
              <Input
                value={moduleAddr}
                onChange={(e) => setModuleAddr(e.target.value)}
                placeholder="Disaster module address (0x...)"
              />
              <Input
                value={shareTokenAddr}
                onChange={(e) => setShareTokenAddr(e.target.value)}
                placeholder="Share token address (optional for frozen/forced timeline)"
              />
            </div>
            <Input
              value={campaignId}
              onChange={(e) => setCampaignId(e.target.value)}
              placeholder="CampaignId (bytes32)"
            />

            <div className="flex flex-wrap items-center gap-2">
              <Badge tone={validModule ? "good" : "warn"}>
                Module {validModule ? "valid" : "invalid"}
              </Badge>
              <Badge tone={validCampaign ? "good" : "warn"}>
                campaignId {validCampaign ? shortHex32(campaignId) : "invalid"}
              </Badge>
              <Badge tone={validToken ? "good" : "default"}>
                Share token {validToken ? shortAddr(shareTokenAddr, 6) : "not set"}
              </Badge>
            </div>

            {campaign.data?.stack ? (
              <div className="rounded-xl border border-border bg-muted p-3">
                <div className="text-xs text-text2">
                  Discovered stack for {shortHex32(campaign.data.campaignId)}:
                </div>
                <div className="mt-2 flex flex-wrap items-center gap-2 text-xs">
                  <Badge tone="default">Disaster {shortAddr(discoveredDisaster, 6)}</Badge>
                  <Badge tone="default">ShareToken {shortAddr(discoveredToken, 6)}</Badge>
                  <Button size="sm" variant="secondary" onClick={loadDiscoveredAddresses}>
                    Use discovered addresses
                  </Button>
                </div>
              </div>
            ) : null}
          </CardContent>
        </Card>

        <div className="grid gap-4 md:grid-cols-2">
          <Card>
            <CardHeader>
              <CardTitle>Declare</CardTitle>
              <CardDescription>Declare incident with hazard, severity, reason hash, and TTL.</CardDescription>
            </CardHeader>
            <CardContent className="space-y-2">
              <Input
                value={hazardCode}
                onChange={(e) => setHazardCode(e.target.value)}
                placeholder="hazardCode bytes32"
              />
              <Input value={severity} onChange={(e) => setSeverity(e.target.value)} placeholder="severity (uint8)" />
              <Input value={ttl} onChange={(e) => setTtl(e.target.value)} placeholder="ttlSeconds (uint64)" />
              <Input
                value={reasonHash}
                onChange={(e) => setReasonHash(e.target.value)}
                placeholder="reasonHash bytes32"
              />
              <Button
                variant="danger"
                onClick={() => setActiveAction("declare")}
                disabled={!isConnected || !validModule || !validCampaign}
              >
                Declare (double confirm)
              </Button>
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle>Confirm / Clear</CardTitle>
              <CardDescription>Confirm applies flags/severity. Clear removes active disaster state.</CardDescription>
            </CardHeader>
            <CardContent className="space-y-2">
              <Input value={flags} onChange={(e) => setFlags(e.target.value)} placeholder="flags (uint256)" />
              <Input
                value={confirmSeverity}
                onChange={(e) => setConfirmSeverity(e.target.value)}
                placeholder="severity (uint8)"
              />
              <div className="flex flex-wrap items-center gap-2">
                <Button
                  variant="danger"
                  onClick={() => setActiveAction("confirm")}
                  disabled={!isConnected || !validModule || !validCampaign}
                >
                  Confirm (double confirm)
                </Button>
                <Button
                  variant="danger"
                  onClick={() => setActiveAction("clear")}
                  disabled={!isConnected || !validModule || !validCampaign}
                >
                  Clear (double confirm)
                </Button>
              </div>
              {!isConnected ? <Badge tone="warn">Connect wallet</Badge> : null}
              {actionError ? <Badge tone="bad">{actionError}</Badge> : null}
            </CardContent>
          </Card>
        </div>

        <Card>
          <CardHeader>
            <CardTitle>Current Safety State</CardTitle>
            <CardDescription>Read-only status for campaign disaster and freeze gating.</CardDescription>
          </CardHeader>
          <CardContent className="grid gap-3">
            {status.isLoading ? (
              <div className="text-sm text-text2">Loading status...</div>
            ) : status.data ? (
              <>
                <div className="flex flex-wrap items-center gap-2">
                  <Badge tone={status.data.restricted ? "bad" : "good"}>
                    {status.data.restricted ? "Restricted" : "Not restricted"}
                  </Badge>
                  <Badge tone={status.data.hardFrozen ? "bad" : "good"}>
                    {status.data.hardFrozen ? "Hard frozen" : "Not hard-frozen"}
                  </Badge>
                  <Badge tone={status.data.flags > 0n ? "warn" : "default"}>
                    flags {status.data.flags.toString()}
                  </Badge>
                </div>
                <div className="grid gap-2 md:grid-cols-2">
                  <div className="rounded-xl border border-border bg-muted p-3 text-sm">
                    severity: {String(disasterState?.severity ?? 0)}
                  </div>
                  <div className="rounded-xl border border-border bg-muted p-3 text-sm">
                    confirmed: {String(Boolean(disasterState?.confirmed))}
                  </div>
                  <div className="rounded-xl border border-border bg-muted p-3 text-sm">
                    expiresAt: {fmtTs(Number(disasterState?.expiresAt ?? 0))}
                  </div>
                  <div className="rounded-xl border border-border bg-muted p-3 text-sm">
                    hazardCode: <span className="font-mono">{shortHex32(String(disasterState?.hazardCode ?? EMPTY_B32))}</span>
                  </div>
                </div>
              </>
            ) : (
              <div className="text-sm text-text2">No data.</div>
            )}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Critical Timeline</CardTitle>
            <CardDescription>
              DisasterDeclared/Confirmed/Cleared plus Frozen/ForcedTransfer events.
            </CardDescription>
          </CardHeader>
          <CardContent className="space-y-3">
            {criticalTimeline.isLoading ? (
              <div className="text-sm text-text2">Loading timeline...</div>
            ) : (criticalTimeline.data?.length ?? 0) === 0 ? (
              <div className="text-sm text-text2">
                No critical events found for this target in the discovery block window.
              </div>
            ) : (
              (criticalTimeline.data ?? []).map((entry) => (
                <div key={entry.id} className="rounded-xl border border-border bg-muted p-3">
                  <div className="flex flex-wrap items-center gap-2">
                    <Badge tone={entry.source === "disaster" ? "bad" : "warn"}>{entry.source}</Badge>
                    <span className="text-sm font-semibold">{entry.event}</span>
                    {entry.blockNumber > 0n ? (
                      <span className="font-mono text-xs text-text2">block {entry.blockNumber.toString()}</span>
                    ) : null}
                  </div>
                  <div className="mt-2 text-sm text-text">{entry.summary}</div>
                  <div className="mt-2 flex flex-wrap items-center gap-3 text-xs text-text2">
                    <span>{fmtTs(entry.timestamp)}</span>
                    {entry.txHash ? (
                      <a
                        href={explorerTxUrl(chainId, entry.txHash)}
                        target="_blank"
                        rel="noreferrer"
                        className="text-primary hover:underline"
                      >
                        View tx
                      </a>
                    ) : null}
                  </div>
                </div>
              ))
            )}
          </CardContent>
        </Card>
      </div>

      {activeAction ? (
        <CriticalActionDialog
          open={Boolean(activeAction)}
          onOpenChange={(open) => (!open ? setActiveAction(null) : null)}
          title={actionMeta.title}
          description="Two-step guardian confirmation is required before this transaction can be submitted."
          warnings={actionMeta.warnings}
          requiredPhrase={requiredPhrase}
          confirmLabel={actionMeta.confirmLabel}
          isSubmitting={isSubmitting}
          onConfirm={executeAction}
        />
      ) : null}
    </div>
  );
}
