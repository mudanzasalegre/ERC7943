"use client";

import * as React from "react";
import { useQuery } from "@tanstack/react-query";
import { isAddress, zeroAddress } from "viem";
import { useAccount, useChainId, usePublicClient } from "wagmi";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { Textarea } from "@/components/ui/Textarea";
import { Button } from "@/components/ui/Button";
import { Badge } from "@/components/ui/Badge";
import { EmptyState } from "@/components/ui/EmptyState";
import { Bytes32HelperCard } from "@/components/trace/Bytes32HelperCard";
import { batchMerkleAnchorAbi, documentRegistryAbi, traceAbi } from "@/lib/abi";
import { explorerAddressUrl, explorerTxUrl } from "@/lib/explorer";
import { getLogsChunked } from "@/lib/discovery";
import { getPublicEnv } from "@/lib/env";
import { resolveDiscoveryFromBlock, type CampaignView } from "@/lib/campaignDiscovery";
import { isBytes32, ZERO_BYTES32 } from "@/lib/bytes32";
import { shortAddr, shortHex32 } from "@/lib/format";
import { useTx } from "@/hooks/useTx";
import { useTraceabilityTimeline } from "@/hooks/useTraceabilityTimeline";

type VerifyStatus = "idle" | "loading" | "found" | "not-found" | "error";

type VerifyRecord = {
  docType: number;
  issuedAt: number;
  issuer?: `0x${string}`;
  campaignId?: `0x${string}`;
  plotRef?: `0x${string}`;
  lotId?: `0x${string}`;
  pointer?: string;
  txHash?: `0x${string}`;
  blockNumber?: bigint;
};

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

export function CampaignDocsPanel({
  campaign,
  documentRegistryAddress,
  traceAddress,
  batchAnchorAddress,
  loadingAddress
}: {
  campaign: CampaignView;
  documentRegistryAddress?: `0x${string}`;
  traceAddress?: `0x${string}`;
  batchAnchorAddress?: `0x${string}`;
  loadingAddress?: boolean;
}) {
  const chainId = useChainId();
  const env = getPublicEnv();
  const client = usePublicClient();
  const { isConnected } = useAccount();
  const { sendTx } = useTx();

  const docsAddress = isLiveAddress(documentRegistryAddress) ? documentRegistryAddress : undefined;
  const traceModuleAddress = isLiveAddress(traceAddress) ? traceAddress : undefined;
  const batchAnchorModuleAddress = isLiveAddress(batchAnchorAddress) ? batchAnchorAddress : undefined;
  const anchorModuleAddress = batchAnchorModuleAddress ?? traceModuleAddress;
  const anchorAbi = batchAnchorModuleAddress ? batchMerkleAnchorAbi : traceAbi;
  const docsRootAnchored = campaign.docsRootHash !== ZERO_BYTES32;

  const [docType, setDocType] = React.useState("1");
  const [docHash, setDocHash] = React.useState("");
  const [issuedAt, setIssuedAt] = React.useState("");
  const [lotId, setLotId] = React.useState<string>(ZERO_BYTES32);
  const [pointer, setPointer] = React.useState("ipfs://");

  const [verifyHash, setVerifyHash] = React.useState("");
  const [verifyStatus, setVerifyStatus] = React.useState<VerifyStatus>("idle");
  const [verifyMessage, setVerifyMessage] = React.useState<string>("");
  const [verifyRecord, setVerifyRecord] = React.useState<VerifyRecord | undefined>(undefined);

  const [batchType, setBatchType] = React.useState("1");
  const [root, setRoot] = React.useState("");
  const [rootFrom, setRootFrom] = React.useState("");
  const [rootTo, setRootTo] = React.useState("");
  const [anchorCheck, setAnchorCheck] = React.useState<boolean | undefined>(undefined);
  const [anchorError, setAnchorError] = React.useState("");

  React.useEffect(() => {
    const now = Math.floor(Date.now() / 1000);
    if (!issuedAt) setIssuedAt(String(now));
    if (!rootFrom) setRootFrom(String(now - 86_400));
    if (!rootTo) setRootTo(String(now));
  }, [issuedAt, rootFrom, rootTo]);

  const parsedDocType = toUint32(docType);
  const parsedIssuedAt = toUint64(issuedAt);
  const validDocHash = isBytes32(docHash);
  const validLotId = isBytes32(lotId);
  const validVerifyHash = isBytes32(verifyHash);

  const parsedBatchType = toUint32(batchType);
  const parsedRootFrom = toUint64(rootFrom);
  const parsedRootTo = toUint64(rootTo);
  const validRoot = isBytes32(root);

  const canRegister =
    isConnected &&
    Boolean(docsAddress) &&
    typeof parsedDocType === "number" &&
    typeof parsedIssuedAt === "bigint" &&
    validDocHash &&
    validLotId;

  const canAnchor =
    isConnected &&
    Boolean(anchorModuleAddress) &&
    typeof parsedBatchType === "number" &&
    typeof parsedRootFrom === "bigint" &&
    typeof parsedRootTo === "bigint" &&
    validRoot;

  const timeline = useTraceabilityTimeline({
    campaignId: campaign.campaignId,
    traceAddress: traceModuleAddress,
    documentRegistryAddress: docsAddress,
    batchAnchorAddress: batchAnchorModuleAddress,
    enabled: Boolean(traceModuleAddress || docsAddress || batchAnchorModuleAddress),
    limit: 60
  });

  const anchorStats = useQuery({
    queryKey: ["campaignAnchorStats", anchorModuleAddress ?? "none", campaign.campaignId, parsedBatchType ?? "none"],
    enabled: Boolean(client && anchorModuleAddress && typeof parsedBatchType === "number"),
    queryFn: async () => {
      if (!client || !anchorModuleAddress || parsedBatchType === undefined) return { count: 0n, latest: undefined as any };
      const count = (await client
        .readContract({
          address: anchorModuleAddress,
          abi: anchorAbi,
          functionName: "anchored",
          args: [campaign.campaignId, parsedBatchType]
        })
        .catch(() => 0n)) as bigint;
      const latest =
        count > 0n
          ? await client
              .readContract({
                address: anchorModuleAddress,
                abi: anchorAbi,
                functionName: "getAnchor",
                args: [campaign.campaignId, parsedBatchType, count - 1n]
              })
              .catch(() => undefined)
          : undefined;
      return { count, latest };
    }
  });

  const onRegister = async () => {
    if (!docsAddress || parsedDocType === undefined || parsedIssuedAt === undefined || !validDocHash || !validLotId) return;
    await sendTx({
      title: "Register document",
      address: docsAddress,
      abi: documentRegistryAbi,
      functionName: "registerDoc",
      args: [parsedDocType, docHash, parsedIssuedAt, campaign.campaignId, campaign.plotRef, lotId, pointer]
    } as any);
    void timeline.refetch();
  };

  const onVerify = async () => {
    if (!client) {
      setVerifyStatus("error");
      setVerifyMessage("RPC client unavailable.");
      setVerifyRecord(undefined);
      return;
    }
    if (!docsAddress) {
      setVerifyStatus("error");
      setVerifyMessage("DocumentRegistry module is not connected.");
      setVerifyRecord(undefined);
      return;
    }
    if (!validVerifyHash) {
      setVerifyStatus("error");
      setVerifyMessage("Enter a valid bytes32 document hash.");
      setVerifyRecord(undefined);
      return;
    }

    setVerifyStatus("loading");
    setVerifyMessage("");
    setVerifyRecord(undefined);
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

      const campaignMatch = [...logs]
        .reverse()
        .find((log: any) => String(log?.args?.campaignId ?? "").toLowerCase() === campaign.campaignId.toLowerCase());

      if (!campaignMatch) {
        setVerifyStatus("not-found");
        setVerifyMessage("No DocRegistered event found for this campaign and hash.");
        return;
      }

      const args = (campaignMatch as any).args ?? {};
      setVerifyRecord({
        docType: Number(args.docType ?? 0),
        issuedAt: Number(args.issuedAt ?? 0),
        issuer: args.issuer as `0x${string}` | undefined,
        campaignId: args.campaignId as `0x${string}` | undefined,
        plotRef: args.plotRef as `0x${string}` | undefined,
        lotId: args.lotId as `0x${string}` | undefined,
        pointer: String(args.pointer ?? ""),
        txHash: (campaignMatch as any).transactionHash as `0x${string}` | undefined,
        blockNumber: (campaignMatch as any).blockNumber ? BigInt((campaignMatch as any).blockNumber) : undefined
      });
      setVerifyStatus("found");
    } catch (error: any) {
      setVerifyStatus("error");
      setVerifyMessage(error?.shortMessage || error?.message || "Verification failed.");
    }
  };

  const onAnchor = async () => {
    if (!anchorModuleAddress || parsedBatchType === undefined || parsedRootFrom === undefined || parsedRootTo === undefined || !validRoot) return;
    setAnchorError("");
    setAnchorCheck(undefined);
    try {
      await sendTx({
        title: "Anchor batch root",
        address: anchorModuleAddress,
        abi: anchorAbi,
        functionName: "anchorRoot",
        args: [campaign.campaignId, parsedBatchType, root, parsedRootFrom, parsedRootTo]
      } as any);
      await Promise.all([anchorStats.refetch(), timeline.refetch()]);
    } catch (error: any) {
      setAnchorError(error?.shortMessage || error?.message || "Failed to anchor root.");
    }
  };

  const onCheckAnchor = async () => {
    if (!client || !anchorModuleAddress || parsedBatchType === undefined || parsedRootFrom === undefined || parsedRootTo === undefined || !validRoot) return;
    setAnchorError("");
    try {
      const found = (await client.readContract({
        address: anchorModuleAddress,
        abi: anchorAbi,
        functionName: "isAnchored",
        args: [campaign.campaignId, parsedBatchType, root, parsedRootFrom, parsedRootTo]
      })) as boolean;
      setAnchorCheck(Boolean(found));
    } catch (error: any) {
      setAnchorError(error?.shortMessage || error?.message || "Anchor verification failed.");
      setAnchorCheck(undefined);
    }
  };

  return (
    <div className="grid gap-4">
      <Card>
        <CardHeader>
          <CardTitle>Docs and Traceability</CardTitle>
          <CardDescription>Campaign docs root, trace modules, and merkle anchors for audit workflows.</CardDescription>
        </CardHeader>
        <CardContent className="grid gap-3 md:grid-cols-2">
          <div className="rounded-xl border border-border bg-muted p-3">
            <div className="text-xs text-text2">docsRootHash</div>
            <div className="mt-1 break-all font-mono text-sm">{campaign.docsRootHash}</div>
            <div className="mt-2">
              <Badge tone={docsRootAnchored ? "good" : "warn"}>{docsRootAnchored ? "Anchored" : "Not anchored yet"}</Badge>
            </div>
          </div>

          <div className="space-y-2 rounded-xl border border-border bg-muted p-3 text-sm">
            <div className="text-xs text-text2">Connected modules</div>
            <div className="flex flex-wrap items-center gap-2">
              <Badge tone={docsAddress ? "good" : "warn"}>Docs {docsAddress ? shortAddr(docsAddress, 6) : "missing"}</Badge>
              <Badge tone={traceModuleAddress ? "good" : "warn"}>Trace {traceModuleAddress ? shortAddr(traceModuleAddress, 6) : "missing"}</Badge>
              <Badge tone={batchAnchorModuleAddress ? "good" : "default"}>
                BatchAnchor {batchAnchorModuleAddress ? shortAddr(batchAnchorModuleAddress, 6) : "fallback trace"}
              </Badge>
              {loadingAddress ? <Badge tone="warn">Resolving addresses</Badge> : null}
            </div>
            <div className="flex flex-wrap gap-3">
              {docsAddress ? (
                <a className="text-primary hover:underline" href={explorerAddressUrl(chainId, docsAddress)} target="_blank" rel="noreferrer">
                  Docs module explorer
                </a>
              ) : null}
              {traceModuleAddress ? (
                <a className="text-primary hover:underline" href={explorerAddressUrl(chainId, traceModuleAddress)} target="_blank" rel="noreferrer">
                  Trace module explorer
                </a>
              ) : null}
            </div>
          </div>
        </CardContent>
      </Card>

      <div className="grid gap-4 lg:grid-cols-2">
        <Bytes32HelperCard
          onUseBytes32={(value) => {
            setDocHash(value);
            setVerifyHash(value);
          }}
          onUseKeccak={(value) => {
            setDocHash(value);
            setRoot(value);
          }}
        />

        {!docsAddress ? (
          <EmptyState
            title="DocumentRegistry unavailable"
            description="This campaign does not expose a DocumentRegistry module yet. Register and verify actions unlock once module wiring exists."
          />
        ) : (
          <Card>
            <CardHeader>
              <CardTitle>Document Verification</CardTitle>
              <CardDescription>Verify a document hash using on-chain DocRegistered events.</CardDescription>
            </CardHeader>
            <CardContent className="space-y-3">
              <Input value={verifyHash} onChange={(e) => setVerifyHash(e.target.value)} placeholder="docHash (bytes32)" aria-label="Verify document hash" />
              <div className="flex flex-wrap items-center gap-2">
                <Button variant="secondary" onClick={onVerify} disabled={!validVerifyHash || verifyStatus === "loading"}>
                  {verifyStatus === "loading" ? "Verifying..." : "Verify"}
                </Button>
                {!validVerifyHash && verifyHash.length > 0 ? <Badge tone="warn">Invalid hash format</Badge> : null}
              </div>

              {verifyStatus === "not-found" ? <div className="rounded-xl border border-warn/35 bg-warn/10 p-3 text-sm text-warn">{verifyMessage}</div> : null}
              {verifyStatus === "error" ? <div className="rounded-xl border border-bad/35 bg-bad/10 p-3 text-sm text-bad">{verifyMessage}</div> : null}

              {verifyStatus === "found" && verifyRecord ? (
                <div className="space-y-2 rounded-xl border border-good/30 bg-good/10 p-3 text-sm">
                  <div className="flex flex-wrap items-center gap-2">
                    <Badge tone="good">Verified</Badge>
                    <span className="font-mono text-xs text-text2">docType {verifyRecord.docType}</span>
                  </div>
                  <div className="text-text2">Issued at: {fmtTs(verifyRecord.issuedAt)}</div>
                  <div className="text-text2">Issuer: {verifyRecord.issuer ? shortAddr(verifyRecord.issuer, 6) : "-"}</div>
                  <div className="break-all text-text2">Lot: {verifyRecord.lotId ?? "-"}</div>
                  <div className="break-all text-text2">Pointer: {verifyRecord.pointer || "-"}</div>
                  {verifyRecord.txHash ? (
                    <a className="inline-flex text-primary hover:underline" href={explorerTxUrl(chainId, verifyRecord.txHash)} target="_blank" rel="noreferrer">
                      Open registration tx
                    </a>
                  ) : null}
                </div>
              ) : null}
            </CardContent>
          </Card>
        )}
      </div>

      <div className="grid gap-4 lg:grid-cols-2">
        {docsAddress ? (
          <Card>
            <CardHeader>
              <CardTitle>Register Document</CardTitle>
              <CardDescription>Write registerDoc using campaign and plot context.</CardDescription>
            </CardHeader>
            <CardContent className="space-y-3">
              <div className="grid gap-2 md:grid-cols-2">
                <Input value={docType} onChange={(e) => setDocType(e.target.value)} placeholder="docType (uint32)" />
                <Input value={issuedAt} onChange={(e) => setIssuedAt(e.target.value)} placeholder="issuedAt (unix seconds)" />
              </div>
              <Input value={docHash} onChange={(e) => setDocHash(e.target.value)} placeholder="docHash (bytes32)" />
              <Input value={lotId} onChange={(e) => setLotId(e.target.value)} placeholder="lotId (bytes32)" />
              <Textarea value={pointer} onChange={(e) => setPointer(e.target.value)} placeholder="pointer (ipfs://..., https://...)" />

              <div className="rounded-xl border border-border bg-muted p-3 text-xs text-text2">
                campaignId {shortHex32(campaign.campaignId)} and plotRef {shortHex32(campaign.plotRef)} are prefilled.
              </div>

              <div className="flex flex-wrap items-center gap-2">
                <Button onClick={onRegister} disabled={!canRegister}>
                  Register doc
                </Button>
                {!isConnected ? <Badge tone="warn">Connect wallet</Badge> : null}
                {docHash.length > 0 && !validDocHash ? <Badge tone="warn">Invalid docHash</Badge> : null}
                {lotId.length > 0 && !validLotId ? <Badge tone="warn">Invalid lotId</Badge> : null}
              </div>
            </CardContent>
          </Card>
        ) : (
          <EmptyState title="Document write disabled" description="No DocumentRegistry module configured for this campaign." />
        )}

        {anchorModuleAddress ? (
          <Card>
            <CardHeader>
              <CardTitle>Merkle Anchor</CardTitle>
              <CardDescription>Anchor and verify batch roots on-chain for audit certificates.</CardDescription>
            </CardHeader>
            <CardContent className="space-y-3">
              <div className="grid gap-2 md:grid-cols-2">
                <Input value={batchType} onChange={(e) => setBatchType(e.target.value)} placeholder="batchType (uint32)" />
                <Input value={root} onChange={(e) => setRoot(e.target.value)} placeholder="root (bytes32)" />
                <Input value={rootFrom} onChange={(e) => setRootFrom(e.target.value)} placeholder="fromTs (uint64)" />
                <Input value={rootTo} onChange={(e) => setRootTo(e.target.value)} placeholder="toTs (uint64)" />
              </div>

              <div className="flex flex-wrap items-center gap-2">
                <Button onClick={onAnchor} disabled={!canAnchor}>
                  Anchor root
                </Button>
                <Button variant="secondary" onClick={onCheckAnchor} disabled={!canAnchor}>
                  Verify anchor
                </Button>
                {!isConnected ? <Badge tone="warn">Connect wallet</Badge> : null}
                {root.length > 0 && !validRoot ? <Badge tone="warn">Invalid root</Badge> : null}
                {anchorCheck === true ? <Badge tone="good">Anchored</Badge> : null}
                {anchorCheck === false ? <Badge tone="warn">Not anchored</Badge> : null}
              </div>

              {anchorError ? <div className="rounded-xl border border-bad/35 bg-bad/10 p-3 text-sm text-bad">{anchorError}</div> : null}

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
        ) : (
          <EmptyState
            title="Anchor module unavailable"
            description="Batch/Merkle anchor is not wired for this campaign yet."
          />
        )}
      </div>

      <Card>
        <CardHeader>
          <CardTitle>Traceability Timeline</CardTitle>
          <CardDescription>Latest trace events, document registrations, and batch anchors for this campaign.</CardDescription>
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
  );
}

