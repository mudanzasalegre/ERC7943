"use client";

import * as React from "react";
import { useQuery } from "@tanstack/react-query";
import { isAddress, zeroAddress } from "viem";
import { useAccount, useChainId, usePublicClient } from "wagmi";
import { PageHeader } from "@/components/ui/PageHeader";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { Textarea } from "@/components/ui/Textarea";
import { Button } from "@/components/ui/Button";
import { Badge } from "@/components/ui/Badge";
import { Bytes32HelperCard } from "@/components/trace/Bytes32HelperCard";
import { batchMerkleAnchorAbi, documentRegistryAbi, traceAbi } from "@/lib/abi";
import { explorerAddressUrl, explorerTxUrl } from "@/lib/explorer";
import { getLogsChunked } from "@/lib/discovery";
import { getPublicEnv } from "@/lib/env";
import { resolveDiscoveryFromBlock } from "@/lib/campaignDiscovery";
import { isBytes32, ZERO_BYTES32 } from "@/lib/bytes32";
import { shortAddr, shortHex32 } from "@/lib/format";
import { useTx } from "@/hooks/useTx";
import { useTraceabilityTimeline } from "@/hooks/useTraceabilityTimeline";

type VerifyStatus = "idle" | "loading" | "found" | "not-found" | "error";

function toUint32(value: string): number | undefined {
  if (!/^\d+$/u.test(value)) return undefined;
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 0 || parsed > 4_294_967_295) return undefined;
  return parsed;
}

function toUint64(value: string): bigint | undefined {
  if (!/^\d+$/u.test(value)) return undefined;
  try {
    const parsed = BigInt(value);
    if (parsed < 0n) return undefined;
    return parsed;
  } catch {
    return undefined;
  }
}

function isLiveAddress(value?: string): value is `0x${string}` {
  return Boolean(value && isAddress(value) && value.toLowerCase() !== zeroAddress);
}

function fmtTs(ts?: number): string {
  if (!ts || ts <= 0) return "-";
  return new Date(ts * 1000).toLocaleString();
}

function timelineTone(source: "trace" | "docs" | "anchor"): "default" | "good" | "warn" | "bad" | "accent" {
  if (source === "trace") return "accent";
  if (source === "anchor") return "warn";
  return "default";
}

export default function AdminTracePage() {
  const chainId = useChainId();
  const env = getPublicEnv();
  const client = usePublicClient();
  const { isConnected } = useAccount();
  const { sendTx } = useTx();

  const [traceAddr, setTraceAddr] = React.useState<string>("");
  const [docAddr, setDocAddr] = React.useState<string>("");
  const [batchAnchorAddr, setBatchAnchorAddr] = React.useState<string>("");

  const [campaignId, setCampaignId] = React.useState<string>(ZERO_BYTES32);
  const [plotRef, setPlotRef] = React.useState<string>(ZERO_BYTES32);
  const [lotId, setLotId] = React.useState<string>(ZERO_BYTES32);

  const [eventType, setEventType] = React.useState<string>("1");
  const [dataHash, setDataHash] = React.useState<string>(ZERO_BYTES32);
  const [traceFromTs, setTraceFromTs] = React.useState<string>("");
  const [traceToTs, setTraceToTs] = React.useState<string>("");
  const [tracePointer, setTracePointer] = React.useState<string>("ipfs://");

  const [batchType, setBatchType] = React.useState<string>("1");
  const [root, setRoot] = React.useState<string>(ZERO_BYTES32);
  const [rootFrom, setRootFrom] = React.useState<string>("");
  const [rootTo, setRootTo] = React.useState<string>("");
  const [anchorCheck, setAnchorCheck] = React.useState<boolean | undefined>(undefined);

  const [docType, setDocType] = React.useState<string>("1");
  const [docHash, setDocHash] = React.useState<string>(ZERO_BYTES32);
  const [docIssuedAt, setDocIssuedAt] = React.useState<string>("");
  const [docPointer, setDocPointer] = React.useState<string>("ipfs://");

  const [verifyHash, setVerifyHash] = React.useState<string>("");
  const [verifyStatus, setVerifyStatus] = React.useState<VerifyStatus>("idle");
  const [verifyMessage, setVerifyMessage] = React.useState<string>("");
  const [verifyTxHash, setVerifyTxHash] = React.useState<`0x${string}` | undefined>(undefined);

  const [actionError, setActionError] = React.useState("");

  React.useEffect(() => {
    if (typeof window === "undefined") return;
    const q = new URLSearchParams(window.location.search);
    const t = q.get("trace");
    const d = q.get("docs");
    const a = q.get("anchor");
    const cid = q.get("campaignId");
    if (t && isAddress(t) && !traceAddr) setTraceAddr(t);
    if (d && isAddress(d) && !docAddr) setDocAddr(d);
    if (a && isAddress(a) && !batchAnchorAddr) setBatchAnchorAddr(a);
    if (cid && isBytes32(cid) && campaignId === ZERO_BYTES32) setCampaignId(cid);
  }, [batchAnchorAddr, campaignId, docAddr, traceAddr]);

  React.useEffect(() => {
    const now = Math.floor(Date.now() / 1000);
    if (!traceFromTs) setTraceFromTs(String(now - 3_600));
    if (!traceToTs) setTraceToTs(String(now));
    if (!rootFrom) setRootFrom(String(now - 86_400));
    if (!rootTo) setRootTo(String(now));
    if (!docIssuedAt) setDocIssuedAt(String(now));
  }, [docIssuedAt, rootFrom, rootTo, traceFromTs, traceToTs]);

  const traceAddress = isLiveAddress(traceAddr) ? (traceAddr as `0x${string}`) : undefined;
  const docsAddress = isLiveAddress(docAddr) ? (docAddr as `0x${string}`) : undefined;
  const batchAnchorAddress = isLiveAddress(batchAnchorAddr) ? (batchAnchorAddr as `0x${string}`) : undefined;
  const anchorAddress = batchAnchorAddress ?? traceAddress;
  const anchorAbi = batchAnchorAddress ? batchMerkleAnchorAbi : traceAbi;

  const validCampaignId = isBytes32(campaignId);
  const validPlotRef = isBytes32(plotRef);
  const validLotId = isBytes32(lotId);
  const validDataHash = isBytes32(dataHash);

  const parsedEventType = toUint32(eventType);
  const parsedTraceFromTs = toUint64(traceFromTs);
  const parsedTraceToTs = toUint64(traceToTs);

  const parsedBatchType = toUint32(batchType);
  const validRoot = isBytes32(root);
  const parsedRootFrom = toUint64(rootFrom);
  const parsedRootTo = toUint64(rootTo);

  const parsedDocType = toUint32(docType);
  const validDocHash = isBytes32(docHash);
  const parsedDocIssuedAt = toUint64(docIssuedAt);
  const validVerifyHash = isBytes32(verifyHash);

  const canEmitTrace =
    isConnected &&
    Boolean(traceAddress) &&
    validCampaignId &&
    validPlotRef &&
    validLotId &&
    validDataHash &&
    typeof parsedEventType === "number" &&
    typeof parsedTraceFromTs === "bigint" &&
    typeof parsedTraceToTs === "bigint";

  const canAnchor =
    isConnected &&
    Boolean(anchorAddress) &&
    validCampaignId &&
    typeof parsedBatchType === "number" &&
    validRoot &&
    typeof parsedRootFrom === "bigint" &&
    typeof parsedRootTo === "bigint";

  const canRegisterDoc =
    isConnected &&
    Boolean(docsAddress) &&
    validCampaignId &&
    validPlotRef &&
    validLotId &&
    typeof parsedDocType === "number" &&
    validDocHash &&
    typeof parsedDocIssuedAt === "bigint";

  const timeline = useTraceabilityTimeline({
    campaignId: validCampaignId ? (campaignId as `0x${string}`) : undefined,
    traceAddress,
    documentRegistryAddress: docsAddress,
    batchAnchorAddress,
    enabled: Boolean(validCampaignId && (traceAddress || docsAddress || batchAnchorAddress)),
    limit: 80
  });

  const anchorStats = useQuery({
    queryKey: ["adminTraceAnchorStats", anchorAddress ?? "none", campaignId, parsedBatchType ?? "none"],
    enabled: Boolean(client && anchorAddress && validCampaignId && typeof parsedBatchType === "number"),
    queryFn: async () => {
      if (!client || !anchorAddress || !validCampaignId || parsedBatchType === undefined) return { count: 0n, latest: undefined as any };
      const count = (await client
        .readContract({
          address: anchorAddress,
          abi: anchorAbi,
          functionName: "anchored",
          args: [campaignId as `0x${string}`, parsedBatchType]
        })
        .catch(() => 0n)) as bigint;
      const latest =
        count > 0n
          ? await client
              .readContract({
                address: anchorAddress,
                abi: anchorAbi,
                functionName: "getAnchor",
                args: [campaignId as `0x${string}`, parsedBatchType, count - 1n]
              })
              .catch(() => undefined)
          : undefined;
      return { count, latest };
    }
  });

  const emitTrace = async () => {
    if (!canEmitTrace || !traceAddress) return;
    setActionError("");
    try {
      await sendTx({
        title: "Emit trace event",
        address: traceAddress,
        abi: traceAbi,
        functionName: "emitTrace",
        args: [
          campaignId as `0x${string}`,
          plotRef as `0x${string}`,
          lotId as `0x${string}`,
          parsedEventType,
          dataHash as `0x${string}`,
          parsedTraceFromTs,
          parsedTraceToTs,
          tracePointer
        ]
      } as any);
      void timeline.refetch();
    } catch (error: any) {
      setActionError(error?.shortMessage || error?.message || "Failed to emit trace event.");
    }
  };

  const anchorRootTx = async () => {
    if (!canAnchor || !anchorAddress || parsedBatchType === undefined || parsedRootFrom === undefined || parsedRootTo === undefined) return;
    setActionError("");
    setAnchorCheck(undefined);
    try {
      await sendTx({
        title: "Anchor batch root",
        address: anchorAddress,
        abi: anchorAbi,
        functionName: "anchorRoot",
        args: [campaignId as `0x${string}`, parsedBatchType, root as `0x${string}`, parsedRootFrom, parsedRootTo]
      } as any);
      await Promise.all([anchorStats.refetch(), timeline.refetch()]);
    } catch (error: any) {
      setActionError(error?.shortMessage || error?.message || "Failed to anchor root.");
    }
  };

  const verifyAnchor = async () => {
    if (!client || !canAnchor || !anchorAddress || parsedBatchType === undefined || parsedRootFrom === undefined || parsedRootTo === undefined) return;
    setActionError("");
    try {
      const found = (await client.readContract({
        address: anchorAddress,
        abi: anchorAbi,
        functionName: "isAnchored",
        args: [campaignId as `0x${string}`, parsedBatchType, root as `0x${string}`, parsedRootFrom, parsedRootTo]
      })) as boolean;
      setAnchorCheck(Boolean(found));
    } catch (error: any) {
      setActionError(error?.shortMessage || error?.message || "Anchor verification failed.");
      setAnchorCheck(undefined);
    }
  };

  const registerDoc = async () => {
    if (!canRegisterDoc || !docsAddress || parsedDocType === undefined || parsedDocIssuedAt === undefined) return;
    setActionError("");
    try {
      await sendTx({
        title: "Register document",
        address: docsAddress,
        abi: documentRegistryAbi,
        functionName: "registerDoc",
        args: [
          parsedDocType,
          docHash as `0x${string}`,
          parsedDocIssuedAt,
          campaignId as `0x${string}`,
          plotRef as `0x${string}`,
          lotId as `0x${string}`,
          docPointer
        ]
      } as any);
      void timeline.refetch();
    } catch (error: any) {
      setActionError(error?.shortMessage || error?.message || "Failed to register document.");
    }
  };

  const verifyDoc = async () => {
    if (!client) {
      setVerifyStatus("error");
      setVerifyMessage("RPC client unavailable.");
      return;
    }
    if (!docsAddress) {
      setVerifyStatus("error");
      setVerifyMessage("DocumentRegistry module missing.");
      return;
    }
    if (!validVerifyHash) {
      setVerifyStatus("error");
      setVerifyMessage("Verify hash must be bytes32.");
      return;
    }
    if (!validCampaignId) {
      setVerifyStatus("error");
      setVerifyMessage("CampaignId must be bytes32.");
      return;
    }

    setVerifyStatus("loading");
    setVerifyMessage("");
    setVerifyTxHash(undefined);
    try {
      const head = await client.getBlockNumber();
      const fromBlock = resolveDiscoveryFromBlock(head, env.NEXT_PUBLIC_DISCOVERY_FROM_BLOCK);
      const logs = await getLogsChunked({
        client,
        fromBlock,
        toBlock: head,
        maxChunk: 5_000n,
        params: {
          address: docsAddress,
          abi: documentRegistryAbi,
          eventName: "DocRegistered",
          args: { docHash: verifyHash }
        }
      });

      const match = [...logs]
        .reverse()
        .find((log: any) => String(log?.args?.campaignId ?? "").toLowerCase() === campaignId.toLowerCase());

      if (!match) {
        setVerifyStatus("not-found");
        setVerifyMessage("No DocRegistered found for this campaign and hash.");
        return;
      }

      setVerifyStatus("found");
      setVerifyMessage("Document hash verified on-chain.");
      setVerifyTxHash((match as any).transactionHash as `0x${string}` | undefined);
    } catch (error: any) {
      setVerifyStatus("error");
      setVerifyMessage(error?.shortMessage || error?.message || "Verification failed.");
    }
  };

  return (
    <div>
      <PageHeader
        title="Admin - Trace and Docs"
        subtitle="End-to-end traceability console: trace events, doc register/verify, and merkle anchors."
      />

      <div className="grid gap-4">
        <Card>
          <CardHeader>
            <CardTitle>Target Modules</CardTitle>
            <CardDescription>Paste campaign module addresses and context fields.</CardDescription>
          </CardHeader>
          <CardContent className="space-y-3">
            <div className="grid gap-2 md:grid-cols-3">
              <Input value={traceAddr} onChange={(e) => setTraceAddr(e.target.value)} placeholder="Trace module address" />
              <Input value={docAddr} onChange={(e) => setDocAddr(e.target.value)} placeholder="DocumentRegistry address" />
              <Input value={batchAnchorAddr} onChange={(e) => setBatchAnchorAddr(e.target.value)} placeholder="BatchAnchor address (optional)" />
            </div>
            <div className="grid gap-2 md:grid-cols-3">
              <Input value={campaignId} onChange={(e) => setCampaignId(e.target.value)} placeholder="campaignId bytes32" />
              <Input value={plotRef} onChange={(e) => setPlotRef(e.target.value)} placeholder="plotRef bytes32" />
              <Input value={lotId} onChange={(e) => setLotId(e.target.value)} placeholder="lotId bytes32" />
            </div>

            <div className="flex flex-wrap items-center gap-2">
              <Badge tone={traceAddress ? "good" : "warn"}>trace {traceAddress ? shortAddr(traceAddress, 6) : "missing"}</Badge>
              <Badge tone={docsAddress ? "good" : "warn"}>docs {docsAddress ? shortAddr(docsAddress, 6) : "missing"}</Badge>
              <Badge tone={anchorAddress ? "good" : "warn"}>
                anchor {anchorAddress ? shortAddr(anchorAddress, 6) : "missing"}
              </Badge>
              <Badge tone={validCampaignId ? "good" : "warn"}>
                campaign {validCampaignId ? shortHex32(campaignId) : "invalid"}
              </Badge>
            </div>

            <div className="flex flex-wrap gap-3 text-sm">
              {traceAddress ? <a className="text-primary hover:underline" href={explorerAddressUrl(chainId, traceAddress)} target="_blank" rel="noreferrer">Trace explorer</a> : null}
              {docsAddress ? <a className="text-primary hover:underline" href={explorerAddressUrl(chainId, docsAddress)} target="_blank" rel="noreferrer">Docs explorer</a> : null}
              {batchAnchorAddress ? <a className="text-primary hover:underline" href={explorerAddressUrl(chainId, batchAnchorAddress)} target="_blank" rel="noreferrer">Batch anchor explorer</a> : null}
            </div>
          </CardContent>
        </Card>

        <div className="grid gap-4 lg:grid-cols-2">
          <Bytes32HelperCard
            onUseBytes32={(value) => {
              setDataHash(value);
              setDocHash(value);
              setRoot(value);
              setVerifyHash(value);
            }}
            onUseKeccak={(value) => {
              setDataHash(value);
              setDocHash(value);
              setRoot(value);
            }}
          />

          <Card>
            <CardHeader>
              <CardTitle>Trace Event</CardTitle>
              <CardDescription>Emit auditable trace events for campaign lots.</CardDescription>
            </CardHeader>
            <CardContent className="space-y-2">
              <div className="grid gap-2 md:grid-cols-2">
                <Input value={eventType} onChange={(e) => setEventType(e.target.value)} placeholder="eventType (uint32)" />
                <Input value={dataHash} onChange={(e) => setDataHash(e.target.value)} placeholder="dataHash (bytes32)" />
                <Input value={traceFromTs} onChange={(e) => setTraceFromTs(e.target.value)} placeholder="fromTs (uint64)" />
                <Input value={traceToTs} onChange={(e) => setTraceToTs(e.target.value)} placeholder="toTs (uint64)" />
              </div>
              <Textarea value={tracePointer} onChange={(e) => setTracePointer(e.target.value)} placeholder="pointer (ipfs://..., https://...)" />
              <div className="flex flex-wrap items-center gap-2">
                <Button onClick={emitTrace} disabled={!canEmitTrace}>
                  Emit trace
                </Button>
                {!isConnected ? <Badge tone="warn">Connect wallet</Badge> : null}
                {!validDataHash && dataHash.length > 0 ? <Badge tone="warn">Invalid dataHash</Badge> : null}
              </div>
            </CardContent>
          </Card>
        </div>

        <div className="grid gap-4 lg:grid-cols-2">
          <Card>
            <CardHeader>
              <CardTitle>Merkle Anchor</CardTitle>
              <CardDescription>Anchor and verify batch roots (BatchAnchor if present, otherwise Trace module).</CardDescription>
            </CardHeader>
            <CardContent className="space-y-3">
              <div className="grid gap-2 md:grid-cols-2">
                <Input value={batchType} onChange={(e) => setBatchType(e.target.value)} placeholder="batchType (uint32)" />
                <Input value={root} onChange={(e) => setRoot(e.target.value)} placeholder="root (bytes32)" />
                <Input value={rootFrom} onChange={(e) => setRootFrom(e.target.value)} placeholder="fromTs (uint64)" />
                <Input value={rootTo} onChange={(e) => setRootTo(e.target.value)} placeholder="toTs (uint64)" />
              </div>
              <div className="flex flex-wrap items-center gap-2">
                <Button onClick={anchorRootTx} disabled={!canAnchor}>
                  Anchor root
                </Button>
                <Button variant="secondary" onClick={verifyAnchor} disabled={!canAnchor}>
                  Verify anchor
                </Button>
                {anchorCheck === true ? <Badge tone="good">Anchored</Badge> : null}
                {anchorCheck === false ? <Badge tone="warn">Not anchored</Badge> : null}
                {root.length > 0 && !validRoot ? <Badge tone="warn">Invalid root</Badge> : null}
              </div>
              <div className="rounded-xl border border-border bg-muted p-3 text-sm">
                <div className="text-xs text-text2">Batch stats</div>
                <div className="mt-1">Anchors for batch {parsedBatchType ?? "-"}: {anchorStats.data?.count?.toString() ?? "0"}</div>
                {anchorStats.data?.latest ? (
                  <div className="mt-2 text-xs text-text2">
                    Latest root {shortHex32(String((anchorStats.data.latest as any)?.root ?? ZERO_BYTES32))} from{" "}
                    {fmtTs(Number((anchorStats.data.latest as any)?.fromTs ?? 0))} to {fmtTs(Number((anchorStats.data.latest as any)?.toTs ?? 0))}
                  </div>
                ) : null}
              </div>
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle>Document Registry</CardTitle>
              <CardDescription>Register docs and verify by hash for audit/certificates.</CardDescription>
            </CardHeader>
            <CardContent className="space-y-3">
              <div className="grid gap-2 md:grid-cols-2">
                <Input value={docType} onChange={(e) => setDocType(e.target.value)} placeholder="docType (uint32)" />
                <Input value={docIssuedAt} onChange={(e) => setDocIssuedAt(e.target.value)} placeholder="issuedAt (uint64)" />
              </div>
              <Input value={docHash} onChange={(e) => setDocHash(e.target.value)} placeholder="docHash (bytes32)" />
              <Textarea value={docPointer} onChange={(e) => setDocPointer(e.target.value)} placeholder="pointer (ipfs://..., https://...)" />
              <div className="flex flex-wrap items-center gap-2">
                <Button onClick={registerDoc} disabled={!canRegisterDoc}>
                  Register doc
                </Button>
                {!validDocHash && docHash.length > 0 ? <Badge tone="warn">Invalid docHash</Badge> : null}
              </div>

              <div className="mt-2 border-t border-border/70 pt-3">
                <Input value={verifyHash} onChange={(e) => setVerifyHash(e.target.value)} placeholder="verify docHash (bytes32)" />
                <div className="mt-2 flex flex-wrap items-center gap-2">
                  <Button variant="secondary" onClick={verifyDoc} disabled={!validVerifyHash || verifyStatus === "loading"}>
                    {verifyStatus === "loading" ? "Verifying..." : "Verify doc"}
                  </Button>
                  {!validVerifyHash && verifyHash.length > 0 ? <Badge tone="warn">Invalid verify hash</Badge> : null}
                </div>
                {verifyStatus === "found" ? (
                  <div className="mt-2 rounded-xl border border-good/35 bg-good/10 p-3 text-sm">
                    {verifyMessage}
                    {verifyTxHash ? (
                      <a className="ml-2 text-primary hover:underline" href={explorerTxUrl(chainId, verifyTxHash)} target="_blank" rel="noreferrer">
                        Open tx
                      </a>
                    ) : null}
                  </div>
                ) : null}
                {verifyStatus === "error" || verifyStatus === "not-found" ? (
                  <div className="mt-2 rounded-xl border border-warn/35 bg-warn/10 p-3 text-sm text-warn">{verifyMessage}</div>
                ) : null}
              </div>
            </CardContent>
          </Card>
        </div>

        {actionError ? (
          <Card>
            <CardContent className="p-4">
              <div className="rounded-xl border border-bad/35 bg-bad/10 p-3 text-sm text-bad">{actionError}</div>
            </CardContent>
          </Card>
        ) : null}

        <Card>
          <CardHeader>
            <CardTitle>Traceability Timeline</CardTitle>
            <CardDescription>Unified stream of trace events, doc registrations, and batch anchors.</CardDescription>
          </CardHeader>
          <CardContent className="space-y-3">
            {timeline.isLoading ? (
              <div className="text-sm text-text2">Loading timeline...</div>
            ) : (timeline.data?.length ?? 0) === 0 ? (
              <div className="text-sm text-text2">No traceability events found in current discovery window.</div>
            ) : (
              (timeline.data ?? []).map((entry) => (
                <div key={entry.id} className="rounded-xl border border-border bg-muted p-3">
                  <div className="flex flex-wrap items-center gap-2">
                    <Badge tone={timelineTone(entry.source)}>{entry.source}</Badge>
                    <span className="text-sm font-semibold">{entry.event}</span>
                    {entry.blockNumber > 0n ? <span className="font-mono text-xs text-text2">block {entry.blockNumber.toString()}</span> : null}
                  </div>
                  <div className="mt-2 text-sm text-text">{entry.summary}</div>
                  <div className="mt-2 flex flex-wrap items-center gap-3 text-xs text-text2">
                    <span>{fmtTs(entry.timestamp)}</span>
                    {entry.txHash ? (
                      <a href={explorerTxUrl(chainId, entry.txHash)} className="text-primary hover:underline" target="_blank" rel="noreferrer">
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
    </div>
  );
}

