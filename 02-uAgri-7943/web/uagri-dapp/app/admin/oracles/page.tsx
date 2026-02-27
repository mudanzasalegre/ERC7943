"use client";

import * as React from "react";
import { useQuery } from "@tanstack/react-query";
import { isAddress, keccak256, toHex } from "viem";
import { useAccount, useChainId, usePublicClient, useSignTypedData } from "wagmi";
import { useTx } from "@/hooks/useTx";
import { useCampaigns } from "@/hooks/useCampaigns";
import { useOracleReportsTimeline, type OracleKind } from "@/hooks/useOracleReportsTimeline";
import { PageHeader } from "@/components/ui/PageHeader";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { Textarea } from "@/components/ui/Textarea";
import { Button } from "@/components/ui/Button";
import { Badge } from "@/components/ui/Badge";
import { EmptyState } from "@/components/ui/EmptyState";
import { Tabs } from "@/components/ui/Tabs";
import {
  custodyOracleAbi,
  disasterEvidenceOracleAbi,
  harvestOracleAbi,
  roleManagerAbi,
  salesProceedsOracleAbi
} from "@/lib/abi";
import { explorerAddressUrl, explorerTxUrl } from "@/lib/explorer";
import { shortAddr, shortHex32 } from "@/lib/format";
import { ZERO_BYTES32, isBytes32 } from "@/lib/bytes32";
import { roles } from "@/lib/roles";

const UINT64_MAX = 2n ** 64n - 1n;
const HEX_BYTES_RE = /^0x(?:[0-9a-fA-F]{2})+$/u;
const DEFAULT_ADMIN_ROLE = (`0x${"00".repeat(32)}`) as `0x${string}`;
const GOVERNANCE_ROLE =
  roles.find((item) => item.key === "GOVERNANCE_ROLE")?.role ?? DEFAULT_ADMIN_ROLE;

type OracleDraft = {
  address: string;
  epoch: string;
  asOf: string;
  validUntil: string;
  reportHash: string;
  payloadHash: string;
  signature: string;
  reportText: string;
  payloadText: string;
};

type Attestation = {
  campaignId: `0x${string}`;
  epoch: bigint;
  asOf: bigint;
  validUntil: bigint;
  reportHash: `0x${string}`;
  payloadHash: `0x${string}`;
};

type OracleMeta = {
  label: string;
  subtitle: string;
  domainName: string;
  queryParam: string;
  abi: unknown;
};

const ORACLE_ORDER: OracleKind[] = ["harvest", "sales", "custody", "disaster"];

const ORACLE_META: Record<OracleKind, OracleMeta> = {
  harvest: {
    label: "Harvest",
    subtitle: "Harvest attestations (quantity/quality evidence).",
    domainName: "uAgri Harvest Oracle",
    queryParam: "harvest",
    abi: harvestOracleAbi
  },
  sales: {
    label: "Sales/Proceeds",
    subtitle: "Sales and proceeds attestations.",
    domainName: "uAgri Sales/Proceeds Oracle",
    queryParam: "sales",
    abi: salesProceedsOracleAbi
  },
  custody: {
    label: "Custody",
    subtitle: "Custody and inventory freshness attestations.",
    domainName: "uAgri Custody Oracle",
    queryParam: "custody",
    abi: custodyOracleAbi
  },
  disaster: {
    label: "Disaster Evidence",
    subtitle: "Disaster evidence attestations.",
    domainName: "uAgri Disaster Evidence Oracle",
    queryParam: "disaster",
    abi: disasterEvidenceOracleAbi
  }
};

function nowSec(): number {
  return Math.floor(Date.now() / 1000);
}

function defaultDraft(): OracleDraft {
  const now = nowSec();
  return {
    address: "",
    epoch: "1",
    asOf: String(now),
    validUntil: String(now + 86_400),
    reportHash: ZERO_BYTES32,
    payloadHash: ZERO_BYTES32,
    signature: "",
    reportText: "",
    payloadText: ""
  };
}

function canAddr(value: string): value is `0x${string}` {
  return isAddress(String(value ?? "").trim());
}

function isHexBytes(value: string): value is `0x${string}` {
  return HEX_BYTES_RE.test(String(value ?? "").trim());
}

function parseUint64(value: string): bigint | undefined {
  const raw = String(value ?? "").trim();
  if (!/^\d+$/u.test(raw)) return undefined;
  try {
    const parsed = BigInt(raw);
    if (parsed < 0n || parsed > UINT64_MAX) return undefined;
    return parsed;
  } catch {
    return undefined;
  }
}

function fmtTs(value?: number | bigint): string {
  if (value === undefined) return "-";
  const ts = typeof value === "bigint" ? Number(value) : value;
  if (!Number.isFinite(ts) || ts <= 0) return "-";
  return new Date(ts * 1000).toLocaleString();
}

function windowTone(args: {
  asOf: bigint;
  validUntil: bigint;
  validNow?: boolean;
}): "default" | "good" | "warn" | "bad" {
  if (args.validNow === true) return "good";
  if (args.validNow === false) return "bad";
  const now = BigInt(nowSec());
  if (args.asOf > now) return "warn";
  if (args.validUntil !== 0n && now > args.validUntil) return "bad";
  return "good";
}

function windowLabel(args: {
  asOf: bigint;
  validUntil: bigint;
  validNow?: boolean;
}): string {
  if (args.validNow === true) return "valid";
  if (args.validNow === false) return "invalid";
  const now = BigInt(nowSec());
  if (args.asOf > now) return "future";
  if (args.validUntil !== 0n && now > args.validUntil) return "expired";
  return "open";
}

export default function AdminOraclesPage() {
  const chainId = useChainId();
  const client = usePublicClient();
  const { address, isConnected } = useAccount();
  const { signTypedDataAsync, isPending: isSigning } = useSignTypedData();
  const { sendTx } = useTx();
  const campaigns = useCampaigns();

  const [campaignId, setCampaignId] = React.useState<string>(ZERO_BYTES32);
  const [activeOracle, setActiveOracle] = React.useState<OracleKind>("harvest");
  const [forms, setForms] = React.useState<Record<OracleKind, OracleDraft>>({
    harvest: defaultDraft(),
    sales: defaultDraft(),
    custody: defaultDraft(),
    disaster: defaultDraft()
  });
  const [actionError, setActionError] = React.useState<string>("");

  const patchDraft = React.useCallback(
    (oracle: OracleKind, patch: Partial<OracleDraft>) => {
      setForms((prev) => ({
        ...prev,
        [oracle]: {
          ...prev[oracle],
          ...patch
        }
      }));
    },
    []
  );

  React.useEffect(() => {
    if (typeof window === "undefined") return;
    const query = new URLSearchParams(window.location.search);
    const qCampaignId = query.get("campaignId");
    const qOracle = query.get("oracle");
    if (qCampaignId && isBytes32(qCampaignId)) {
      setCampaignId(qCampaignId);
    }
    for (const oracle of ORACLE_ORDER) {
      const key = ORACLE_META[oracle].queryParam;
      const value = query.get(key);
      if (value && canAddr(value)) {
        patchDraft(oracle, { address: value });
      }
    }
    if (qOracle && ORACLE_ORDER.includes(qOracle as OracleKind)) {
      setActiveOracle(qOracle as OracleKind);
    }
  }, [patchDraft]);

  const activeMeta = ORACLE_META[activeOracle];
  const active = forms[activeOracle];

  const validCampaignId = isBytes32(campaignId);
  const oracleAddress = canAddr(active.address) ? (active.address.trim() as `0x${string}`) : undefined;
  const parsedEpoch = parseUint64(active.epoch);
  const parsedAsOf = parseUint64(active.asOf);
  const parsedValidUntil = parseUint64(active.validUntil);
  const parsedReportHash = isBytes32(active.reportHash) ? (active.reportHash.trim() as `0x${string}`) : undefined;
  const parsedPayloadHash = isBytes32(active.payloadHash) ? (active.payloadHash.trim() as `0x${string}`) : undefined;
  const signatureHex = isHexBytes(active.signature) ? (active.signature.trim() as `0x${string}`) : undefined;

  const builtReportHash = React.useMemo(() => {
    const text = active.reportText.trim();
    if (!text) return "";
    return keccak256(toHex(text));
  }, [active.reportText]);

  const builtPayloadHash = React.useMemo(() => {
    const text = active.payloadText.trim();
    if (!text) return "";
    return keccak256(toHex(text));
  }, [active.payloadText]);

  const attestation: Attestation | undefined =
    validCampaignId &&
    parsedEpoch !== undefined &&
    parsedAsOf !== undefined &&
    parsedValidUntil !== undefined &&
    parsedReportHash !== undefined &&
    parsedPayloadHash !== undefined
      ? {
          campaignId: campaignId as `0x${string}`,
          epoch: parsedEpoch,
          asOf: parsedAsOf,
          validUntil: parsedValidUntil,
          reportHash: parsedReportHash,
          payloadHash: parsedPayloadHash
        }
      : undefined;

  const attestationKey = attestation
    ? [
        attestation.campaignId,
        attestation.epoch.toString(),
        attestation.asOf.toString(),
        attestation.validUntil.toString(),
        attestation.reportHash,
        attestation.payloadHash
      ].join(":")
    : "none";

  const digestPreview = useQuery({
    queryKey: ["adminOracleDigestPreview", activeOracle, oracleAddress ?? "none", attestationKey],
    enabled: Boolean(client && oracleAddress && attestation),
    queryFn: async () => {
      if (!client || !oracleAddress || !attestation) return undefined;
      const out = (await client.readContract({
        address: oracleAddress,
        abi: activeMeta.abi as any,
        functionName: "hashAttestationWithNonce",
        args: [attestation]
      })) as [`0x${string}`, bigint];
      return {
        digest: out[0],
        nonce: out[1]
      };
    }
  });

  const submitterRoleCheck = useQuery({
    queryKey: ["adminOracleRoleCheck", activeOracle, oracleAddress ?? "none", address ?? "none"],
    enabled: Boolean(client && oracleAddress && address),
    queryFn: async () => {
      if (!client || !oracleAddress || !address) {
        return {
          roleManager: undefined as `0x${string}` | undefined,
          submitterRole: undefined as `0x${string}` | undefined,
          canSubmit: false,
          byRole: [] as { role: `0x${string}`; label: string; ok: boolean }[]
        };
      }

      const [roleManagerRaw, submitterRoleRaw] = await Promise.all([
        client
          .readContract({
            address: oracleAddress,
            abi: activeMeta.abi as any,
            functionName: "roleManager"
          })
          .catch(() => undefined),
        client
          .readContract({
            address: oracleAddress,
            abi: activeMeta.abi as any,
            functionName: "submitterRole"
          })
          .catch(() => undefined)
      ]);

      const roleManager =
        roleManagerRaw && isAddress(roleManagerRaw as string)
          ? (roleManagerRaw as `0x${string}`)
          : undefined;
      const submitterRole =
        submitterRoleRaw && isBytes32(String(submitterRoleRaw))
          ? (submitterRoleRaw as `0x${string}`)
          : undefined;

      if (!roleManager || !submitterRole) {
        return {
          roleManager,
          submitterRole,
          canSubmit: false,
          byRole: [] as { role: `0x${string}`; label: string; ok: boolean }[]
        };
      }

      const roleDefs = [
        { role: submitterRole, label: "Submitter role" },
        { role: GOVERNANCE_ROLE, label: "Governance role" },
        { role: DEFAULT_ADMIN_ROLE, label: "Default admin" }
      ];

      const byRole = await Promise.all(
        roleDefs.map(async (item) => {
          const ok = Boolean(
            await client
              .readContract({
                address: roleManager,
                abi: roleManagerAbi,
                functionName: "hasRole",
                args: [item.role, address]
              })
              .catch(() => false)
          );
          return {
            role: item.role,
            label: item.label,
            ok
          };
        })
      );

      return {
        roleManager,
        submitterRole,
        canSubmit: byRole.some((item) => item.ok),
        byRole
      };
    }
  });

  const verifyRead = useQuery({
    queryKey: [
      "adminOracleVerifyRead",
      activeOracle,
      oracleAddress ?? "none",
      validCampaignId ? campaignId : "none",
      parsedEpoch?.toString() ?? "none"
    ],
    enabled: Boolean(client && oracleAddress && validCampaignId && parsedEpoch !== undefined),
    refetchInterval: 30_000,
    queryFn: async () => {
      if (!client || !oracleAddress || !validCampaignId || parsedEpoch === undefined) return undefined;

      const [latestEpochRaw, reportHashRaw, payloadHashRaw, reportWindowRaw, isValidRaw] =
        await Promise.all([
          client
            .readContract({
              address: oracleAddress,
              abi: activeMeta.abi as any,
              functionName: "latestEpoch",
              args: [campaignId as `0x${string}`]
            })
            .catch(() => 0n),
          client
            .readContract({
              address: oracleAddress,
              abi: activeMeta.abi as any,
              functionName: "reportHash",
              args: [campaignId as `0x${string}`, parsedEpoch]
            })
            .catch(() => ZERO_BYTES32),
          client
            .readContract({
              address: oracleAddress,
              abi: activeMeta.abi as any,
              functionName: "payloadHash",
              args: [campaignId as `0x${string}`, parsedEpoch]
            })
            .catch(() => ZERO_BYTES32),
          client
            .readContract({
              address: oracleAddress,
              abi: activeMeta.abi as any,
              functionName: "reportWindow",
              args: [campaignId as `0x${string}`, parsedEpoch]
            })
            .catch(() => [0n, 0n]),
          client
            .readContract({
              address: oracleAddress,
              abi: activeMeta.abi as any,
              functionName: "isReportValid",
              args: [campaignId as `0x${string}`, parsedEpoch]
            })
            .catch(() => false)
        ]);

      const asOfRaw = (reportWindowRaw as any)?.asOf_ ?? (reportWindowRaw as any)?.[0] ?? 0n;
      const validUntilRaw = (reportWindowRaw as any)?.validUntil_ ?? (reportWindowRaw as any)?.[1] ?? 0n;

      return {
        latestEpoch: BigInt(latestEpochRaw as bigint),
        reportHash: reportHashRaw as `0x${string}`,
        payloadHash: payloadHashRaw as `0x${string}`,
        asOf: BigInt(asOfRaw),
        validUntil: BigInt(validUntilRaw),
        valid: Boolean(isValidRaw)
      };
    }
  });

  const simulation = useQuery({
    queryKey: [
      "adminOracleSimulation",
      activeOracle,
      oracleAddress ?? "none",
      address ?? "none",
      attestationKey,
      signatureHex ?? "none"
    ],
    enabled: Boolean(client && oracleAddress && address && attestation && signatureHex),
    queryFn: async () => {
      if (!client || !oracleAddress || !address || !attestation || !signatureHex) {
        return { ok: false, error: "missing params" };
      }
      try {
        await client.simulateContract({
          account: address,
          address: oracleAddress,
          abi: activeMeta.abi as any,
          functionName: "submitAttestation",
          args: [attestation, signatureHex]
        });
        return {
          ok: true,
          error: ""
        };
      } catch (error: any) {
        return {
          ok: false,
          error: error?.shortMessage || error?.message || "simulation failed"
        };
      }
    }
  });

  const reportTimeline = useOracleReportsTimeline({
    campaignId,
    oracleAddresses: {
      harvest: forms.harvest.address,
      sales: forms.sales.address,
      custody: forms.custody.address,
      disaster: forms.disaster.address
    },
    enabled: true,
    limit: 100
  });

  const signErrors: string[] = [];
  if (!isConnected || !address) signErrors.push("Connect wallet");
  if (!oracleAddress) signErrors.push("Oracle address required");
  if (!validCampaignId) signErrors.push("campaignId must be bytes32");
  if (parsedEpoch === undefined || parsedEpoch <= 0n) signErrors.push("epoch must be uint64 > 0");
  if (parsedAsOf === undefined || parsedAsOf <= 0n) signErrors.push("asOf must be uint64 > 0");
  if (parsedAsOf !== undefined && parsedAsOf > BigInt(nowSec())) signErrors.push("asOf cannot be in the future");
  if (parsedValidUntil === undefined) signErrors.push("validUntil must be uint64");
  if (
    parsedAsOf !== undefined &&
    parsedValidUntil !== undefined &&
    parsedValidUntil !== 0n &&
    parsedValidUntil < parsedAsOf
  ) {
    signErrors.push("validUntil must be 0 or >= asOf");
  }
  if (!parsedReportHash) signErrors.push("reportHash must be bytes32");
  if (parsedReportHash && parsedReportHash.toLowerCase() === ZERO_BYTES32) {
    signErrors.push("reportHash cannot be zero");
  }
  if (!parsedPayloadHash) signErrors.push("payloadHash must be bytes32");
  if (parsedPayloadHash && parsedPayloadHash.toLowerCase() === ZERO_BYTES32) {
    signErrors.push("payloadHash cannot be zero");
  }

  const publishErrors = [...signErrors];
  if (!signatureHex) publishErrors.push("Signature required");
  if (submitterRoleCheck.data && !submitterRoleCheck.data.canSubmit) {
    publishErrors.push("Wallet lacks submitter/governance/admin role");
  }
  if (simulation.data && !simulation.data.ok) {
    publishErrors.push("Simulation failed");
  }

  const onSign = async () => {
    if (!client || !oracleAddress || !attestation || !address) return;
    setActionError("");
    try {
      const [, nonce] = (await client.readContract({
        address: oracleAddress,
        abi: activeMeta.abi as any,
        functionName: "hashAttestationWithNonce",
        args: [attestation]
      })) as [`0x${string}`, bigint];

      const signature = await signTypedDataAsync({
        domain: {
          name: activeMeta.domainName,
          version: "1",
          chainId,
          verifyingContract: oracleAddress
        },
        types: {
          Attestation: [
            { name: "campaignId", type: "bytes32" },
            { name: "epoch", type: "uint64" },
            { name: "asOf", type: "uint64" },
            { name: "validUntil", type: "uint64" },
            { name: "reportHash", type: "bytes32" },
            { name: "payloadHash", type: "bytes32" },
            { name: "nonce", type: "uint256" }
          ]
        },
        primaryType: "Attestation",
        message: {
          campaignId: attestation.campaignId,
          epoch: attestation.epoch,
          asOf: attestation.asOf,
          validUntil: attestation.validUntil,
          reportHash: attestation.reportHash,
          payloadHash: attestation.payloadHash,
          nonce
        }
      } as any);

      patchDraft(activeOracle, { signature });
      void digestPreview.refetch();
    } catch (error: any) {
      setActionError(error?.shortMessage || error?.message || "Signature failed");
    }
  };

  const onPublish = async () => {
    if (!oracleAddress || !attestation || !signatureHex) return;
    setActionError("");
    try {
      await sendTx({
        title: `${activeMeta.label}: submit attestation`,
        address: oracleAddress,
        abi: activeMeta.abi as any,
        functionName: "submitAttestation",
        args: [attestation, signatureHex]
      } as any);
      await Promise.all([
        verifyRead.refetch(),
        reportTimeline.refetch(),
        digestPreview.refetch(),
        submitterRoleCheck.refetch()
      ]);
    } catch (error: any) {
      setActionError(error?.shortMessage || error?.message || "submitAttestation failed");
    }
  };

  const tabItems = ORACLE_ORDER.map((oracle) => ({
    value: oracle,
    label: ORACLE_META[oracle].label
  }));

  return (
    <div>
      <PageHeader
        title="Admin - Oracles"
        subtitle="Hash reports, sign EIP-712 attestations, publish on-chain, and verify reports by campaign."
      />

      <div className="grid gap-4">
        <Card>
          <CardHeader>
            <CardTitle>Target Campaign and Oracle Addresses</CardTitle>
            <CardDescription>Set campaignId and each oracle module address for this campaign.</CardDescription>
          </CardHeader>
          <CardContent className="space-y-3">
            <Input
              value={campaignId}
              onChange={(e) => setCampaignId(e.target.value)}
              placeholder="campaignId (bytes32)"
              aria-label="campaignId"
            />

            <div className="grid gap-2 md:grid-cols-2">
              {ORACLE_ORDER.map((oracle) => (
                <Input
                  key={oracle}
                  value={forms[oracle].address}
                  onChange={(e) => patchDraft(oracle, { address: e.target.value })}
                  placeholder={`${ORACLE_META[oracle].label} oracle address (0x...)`}
                  aria-label={`${ORACLE_META[oracle].label} oracle address`}
                />
              ))}
            </div>

            <div className="flex flex-wrap items-center gap-2">
              <Badge tone={validCampaignId ? "good" : "warn"}>
                campaignId {validCampaignId ? shortHex32(campaignId) : "invalid"}
              </Badge>
              {ORACLE_ORDER.map((oracle) => {
                const addr = forms[oracle].address;
                const ok = canAddr(addr);
                return (
                  <Badge key={oracle} tone={ok ? "good" : "warn"}>
                    {ORACLE_META[oracle].label} {ok ? shortAddr(addr, 6) : "missing"}
                  </Badge>
                );
              })}
            </div>

            {(campaigns.data?.length ?? 0) > 0 ? (
              <div className="rounded-xl border border-border bg-muted p-3">
                <div className="text-xs text-text2">Quick pick campaign</div>
                <div className="mt-2 flex flex-wrap gap-2">
                  {(campaigns.data ?? []).slice(0, 12).map((campaign) => (
                    <button
                      key={campaign.campaignId}
                      type="button"
                      className="rounded-lg border border-border bg-card px-2 py-1 text-xs hover:shadow-soft"
                      onClick={() => setCampaignId(campaign.campaignId)}
                    >
                      {campaign.tokenMeta?.symbol ?? "campaign"} {shortHex32(campaign.campaignId)}
                    </button>
                  ))}
                </div>
              </div>
            ) : null}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Oracle Forms</CardTitle>
            <CardDescription>{activeMeta.subtitle}</CardDescription>
          </CardHeader>
          <CardContent className="space-y-3">
            <Tabs
              ariaLabel="Select oracle form"
              items={tabItems}
              value={activeOracle}
              onChange={(value) => setActiveOracle(value as OracleKind)}
            />

            <div className="grid gap-2 md:grid-cols-2">
              <Input
                value={active.epoch}
                onChange={(e) => patchDraft(activeOracle, { epoch: e.target.value, signature: "" })}
                placeholder="epoch (uint64)"
                aria-label="epoch"
              />
              <Input
                value={active.asOf}
                onChange={(e) => patchDraft(activeOracle, { asOf: e.target.value, signature: "" })}
                placeholder="asOf (unix uint64)"
                aria-label="asOf"
              />
              <Input
                value={active.validUntil}
                onChange={(e) => patchDraft(activeOracle, { validUntil: e.target.value, signature: "" })}
                placeholder="validUntil (0 or unix uint64)"
                aria-label="validUntil"
              />
              <div className="flex items-center gap-2">
                <Button
                  variant="secondary"
                  onClick={() => {
                    const now = nowSec();
                    patchDraft(activeOracle, {
                      asOf: String(now),
                      validUntil: String(now + 86_400),
                      signature: ""
                    });
                  }}
                >
                  Set now + 24h
                </Button>
              </div>
              <Input
                value={active.reportHash}
                onChange={(e) => patchDraft(activeOracle, { reportHash: e.target.value, signature: "" })}
                placeholder="reportHash (bytes32, non-zero)"
                aria-label="reportHash"
              />
              <Input
                value={active.payloadHash}
                onChange={(e) => patchDraft(activeOracle, { payloadHash: e.target.value, signature: "" })}
                placeholder="payloadHash (bytes32, non-zero)"
                aria-label="payloadHash"
              />
            </div>

            <div className="grid gap-2 md:grid-cols-2">
              <Textarea
                value={active.reportText}
                onChange={(e) => patchDraft(activeOracle, { reportText: e.target.value })}
                placeholder="Report text for keccak256 helper"
                className="min-h-[84px]"
                aria-label="Report text helper"
              />
              <Textarea
                value={active.payloadText}
                onChange={(e) => patchDraft(activeOracle, { payloadText: e.target.value })}
                placeholder="Payload text for keccak256 helper"
                className="min-h-[84px]"
                aria-label="Payload text helper"
              />
              <Input
                value={builtReportHash}
                readOnly
                placeholder="keccak256(report text)"
                aria-label="Built report hash"
              />
              <Input
                value={builtPayloadHash}
                readOnly
                placeholder="keccak256(payload text)"
                aria-label="Built payload hash"
              />
            </div>

            <div className="flex flex-wrap items-center gap-2">
              <Button
                variant="secondary"
                onClick={() => builtReportHash && patchDraft(activeOracle, { reportHash: builtReportHash, signature: "" })}
                disabled={!builtReportHash}
              >
                Use report hash
              </Button>
              <Button
                variant="secondary"
                onClick={() => builtPayloadHash && patchDraft(activeOracle, { payloadHash: builtPayloadHash, signature: "" })}
                disabled={!builtPayloadHash}
              >
                Use payload hash
              </Button>
            </div>

            <Textarea
              value={active.signature}
              onChange={(e) => patchDraft(activeOracle, { signature: e.target.value })}
              placeholder="Signature (0x...)"
              className="min-h-[92px]"
              aria-label="Signature"
            />

            <div className="grid gap-2 text-xs text-text2 md:grid-cols-2">
              <div>Digest: {digestPreview.data?.digest ? shortHex32(digestPreview.data.digest) : "-"}</div>
              <div>Nonce: {digestPreview.data?.nonce?.toString() ?? "-"}</div>
              <div>asOf time: {parsedAsOf !== undefined ? fmtTs(parsedAsOf) : "-"}</div>
              <div>
                validUntil time:{" "}
                {parsedValidUntil !== undefined ? (parsedValidUntil === 0n ? "no expiry (0)" : fmtTs(parsedValidUntil)) : "-"}
              </div>
            </div>

            <div className="flex flex-wrap items-center gap-2">
              <Badge tone={oracleAddress ? "good" : "warn"}>{oracleAddress ? "Oracle address OK" : "Oracle address missing"}</Badge>
              <Badge tone={validCampaignId ? "good" : "warn"}>{validCampaignId ? "campaignId OK" : "campaignId invalid"}</Badge>
              <Badge tone={signatureHex ? "good" : "default"}>{signatureHex ? "Signature set" : "No signature"}</Badge>
              <Badge tone={submitterRoleCheck.data?.canSubmit ? "good" : "warn"}>
                {submitterRoleCheck.data?.canSubmit ? "Role check OK" : "Role missing/unknown"}
              </Badge>
              <Badge tone={simulation.data?.ok ? "good" : simulation.data ? "bad" : "default"}>
                {simulation.data?.ok ? "Simulation OK" : simulation.data ? "Simulation failed" : "Simulation pending"}
              </Badge>
            </div>

            {submitterRoleCheck.data?.byRole?.length ? (
              <div className="flex flex-wrap gap-2">
                {submitterRoleCheck.data.byRole.map((item) => (
                  <Badge key={item.role} tone={item.ok ? "good" : "default"}>
                    {item.label}
                  </Badge>
                ))}
              </div>
            ) : null}

            <div className="flex flex-wrap items-center gap-2">
              <Button onClick={onSign} disabled={isSigning || signErrors.length > 0}>
                {isSigning ? "Signing..." : "Sign EIP-712 attestation"}
              </Button>
              <Button onClick={onPublish} disabled={publishErrors.length > 0}>
                submitAttestation
              </Button>
              <Button
                variant="secondary"
                onClick={() => {
                  void verifyRead.refetch();
                  void reportTimeline.refetch();
                }}
                disabled={!oracleAddress || !validCampaignId || parsedEpoch === undefined}
              >
                Verify and refresh
              </Button>
              <Button
                variant="secondary"
                onClick={() => navigator.clipboard.writeText(active.signature)}
                disabled={!signatureHex}
              >
                Copy signature
              </Button>
            </div>

            {signErrors.length > 0 ? (
              <div className="flex flex-wrap gap-2">
                {signErrors.map((error) => (
                  <Badge key={`sign-${error}`} tone="warn">
                    {error}
                  </Badge>
                ))}
              </div>
            ) : null}

            {simulation.data && !simulation.data.ok ? (
              <div className="rounded-xl border border-bad/30 bg-bad/10 p-3 text-sm text-bad">
                {simulation.data.error}
              </div>
            ) : null}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>On-chain Verify (Active Oracle)</CardTitle>
            <CardDescription>Reads latest epoch, stored hashes, report window, and validity for selected epoch.</CardDescription>
          </CardHeader>
          <CardContent className="space-y-3">
            {verifyRead.isLoading ? (
              <div className="text-sm text-text2">Loading verify data...</div>
            ) : !verifyRead.data ? (
              <EmptyState title="No verify data" description="Set valid campaignId, epoch, and oracle address." />
            ) : (
              <>
                <div className="flex flex-wrap items-center gap-2">
                  <Badge tone={verifyRead.data.valid ? "good" : "warn"}>
                    {verifyRead.data.valid ? "Report valid now" : "Report not valid now"}
                  </Badge>
                  <Badge tone="default">latestEpoch {verifyRead.data.latestEpoch.toString()}</Badge>
                  <Badge
                    tone={
                      parsedReportHash &&
                      verifyRead.data.reportHash.toLowerCase() === parsedReportHash.toLowerCase()
                        ? "good"
                        : "warn"
                    }
                  >
                    reportHash match {parsedReportHash && verifyRead.data.reportHash.toLowerCase() === parsedReportHash.toLowerCase() ? "yes" : "no"}
                  </Badge>
                </div>

                <div className="grid gap-2 text-xs text-text2 md:grid-cols-2">
                  <div>Stored reportHash: {shortHex32(verifyRead.data.reportHash)}</div>
                  <div>Stored payloadHash: {shortHex32(verifyRead.data.payloadHash)}</div>
                  <div>Window asOf: {fmtTs(verifyRead.data.asOf)}</div>
                  <div>
                    Window validUntil:{" "}
                    {verifyRead.data.validUntil === 0n ? "no expiry (0)" : fmtTs(verifyRead.data.validUntil)}
                  </div>
                </div>
              </>
            )}
          </CardContent>
        </Card>

        {actionError ? (
          <Card>
            <CardContent className="p-4">
              <div className="rounded-xl border border-bad/35 bg-bad/10 p-3 text-sm text-bad">{actionError}</div>
            </CardContent>
          </Card>
        ) : null}

        <Card>
          <CardHeader>
            <CardTitle>Reports by Campaign</CardTitle>
            <CardDescription>Recent oracle reports across configured oracle modules for this campaign.</CardDescription>
          </CardHeader>
          <CardContent>
            {reportTimeline.isLoading ? (
              <div className="text-sm text-text2">Loading oracle reports...</div>
            ) : (reportTimeline.data?.length ?? 0) === 0 ? (
              <EmptyState
                title="No oracle reports found"
                description="Set campaignId and oracle addresses, then publish or refresh."
              />
            ) : (
              <>
                <div className="hidden md:block">
                  <div className="overflow-x-auto rounded-xl border border-border/80">
                    <table className="w-full min-w-[980px] text-left text-sm">
                      <thead className="bg-muted text-text2">
                        <tr>
                          <th className="px-3 py-2 font-medium">Oracle</th>
                          <th className="px-3 py-2 font-medium">Epoch</th>
                          <th className="px-3 py-2 font-medium">Report hash</th>
                          <th className="px-3 py-2 font-medium">Payload hash</th>
                          <th className="px-3 py-2 font-medium">Window</th>
                          <th className="px-3 py-2 font-medium">Status</th>
                          <th className="px-3 py-2 font-medium">Signer</th>
                          <th className="px-3 py-2 font-medium">When</th>
                          <th className="px-3 py-2 font-medium">Tx</th>
                        </tr>
                      </thead>
                      <tbody>
                        {(reportTimeline.data ?? []).map((row) => (
                          <tr key={row.id} className="border-t border-border/70">
                            <td className="px-3 py-2">
                              <div className="flex flex-col gap-1">
                                <span className="font-medium">{row.oracleLabel}</span>
                                <a
                                  className="text-xs text-primary hover:underline"
                                  href={explorerAddressUrl(chainId, row.oracleAddress)}
                                  target="_blank"
                                  rel="noreferrer"
                                >
                                  {shortAddr(row.oracleAddress, 6)}
                                </a>
                              </div>
                            </td>
                            <td className="px-3 py-2 font-mono">{row.epoch.toString()}</td>
                            <td className="px-3 py-2 font-mono text-xs">{shortHex32(row.reportHash)}</td>
                            <td className="px-3 py-2 font-mono text-xs">{row.payloadHash ? shortHex32(row.payloadHash) : "-"}</td>
                            <td className="px-3 py-2 text-xs">
                              <div>{fmtTs(row.asOf)}</div>
                              <div>{row.validUntil === 0n ? "no expiry" : fmtTs(row.validUntil)}</div>
                            </td>
                            <td className="px-3 py-2">
                              <Badge tone={windowTone({ asOf: row.asOf, validUntil: row.validUntil, validNow: row.validNow })}>
                                {windowLabel({ asOf: row.asOf, validUntil: row.validUntil, validNow: row.validNow })}
                              </Badge>
                            </td>
                            <td className="px-3 py-2 font-mono text-xs">{row.signer ? shortAddr(row.signer, 6) : "-"}</td>
                            <td className="px-3 py-2 text-xs">{fmtTs(row.timestamp)}</td>
                            <td className="px-3 py-2">
                              {row.txHash ? (
                                <div className="flex items-center gap-2">
                                  <button
                                    type="button"
                                    className="rounded-md border border-border px-2 py-1 text-xs hover:bg-card"
                                    onClick={() => navigator.clipboard.writeText(row.txHash!)}
                                  >
                                    Copy
                                  </button>
                                  <a
                                    className="rounded-md border border-border px-2 py-1 text-xs hover:bg-card"
                                    href={explorerTxUrl(chainId, row.txHash)}
                                    target="_blank"
                                    rel="noreferrer"
                                  >
                                    Explorer
                                  </a>
                                </div>
                              ) : (
                                "-"
                              )}
                            </td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                </div>

                <div className="grid gap-3 md:hidden">
                  {(reportTimeline.data ?? []).map((row) => (
                    <div key={row.id} className="rounded-xl border border-border/80 bg-card p-3">
                      <div className="flex items-start justify-between gap-2">
                        <div>
                          <div className="font-medium">{row.oracleLabel}</div>
                          <div className="text-xs text-text2">Epoch {row.epoch.toString()}</div>
                        </div>
                        <Badge tone={windowTone({ asOf: row.asOf, validUntil: row.validUntil, validNow: row.validNow })}>
                          {windowLabel({ asOf: row.asOf, validUntil: row.validUntil, validNow: row.validNow })}
                        </Badge>
                      </div>
                      <div className="mt-2 text-xs text-text2">Report: {shortHex32(row.reportHash)}</div>
                      <div className="mt-1 text-xs text-text2">Payload: {row.payloadHash ? shortHex32(row.payloadHash) : "-"}</div>
                      <div className="mt-1 text-xs text-text2">Signer: {row.signer ? shortAddr(row.signer, 6) : "-"}</div>
                      <div className="mt-1 text-xs text-text2">AsOf: {fmtTs(row.asOf)}</div>
                      <div className="mt-1 text-xs text-text2">
                        validUntil: {row.validUntil === 0n ? "no expiry" : fmtTs(row.validUntil)}
                      </div>
                      <div className="mt-1 text-xs text-text2">Recorded: {fmtTs(row.timestamp)}</div>
                      {row.txHash ? (
                        <div className="mt-3 flex flex-wrap items-center gap-2">
                          <button
                            type="button"
                            className="rounded-md border border-border px-2 py-1 text-xs hover:bg-muted"
                            onClick={() => navigator.clipboard.writeText(row.txHash!)}
                          >
                            Copy tx
                          </button>
                          <a
                            className="rounded-md border border-border px-2 py-1 text-xs hover:bg-muted"
                            href={explorerTxUrl(chainId, row.txHash)}
                            target="_blank"
                            rel="noreferrer"
                          >
                            Explorer
                          </a>
                        </div>
                      ) : null}
                    </div>
                  ))}
                </div>
              </>
            )}
          </CardContent>
        </Card>
      </div>
    </div>
  );
}
