"use client";

import * as React from "react";
import Link from "next/link";
import { isAddress } from "viem";
import { PageHeader } from "@/components/ui/PageHeader";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/Card";
import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { Input } from "@/components/ui/Input";
import { Textarea } from "@/components/ui/Textarea";
import { Skeleton } from "@/components/ui/Skeleton";
import { ErrorState } from "@/components/ui/ErrorState";
import { EmptyState } from "@/components/ui/EmptyState";
import { shortAddr, shortHex32 } from "@/lib/format";
import { isBytes32 } from "@/lib/bytes32";
import { useCampaigns, type CampaignView } from "@/hooks/useCampaigns";

type SavedActionType =
  | "batchProcess"
  | "notifyReward"
  | "onrampDeposit"
  | "payoutExecute"
  | "payoutConfirm";

type ParamField = {
  key: string;
  label: string;
  placeholder: string;
  multiline?: boolean;
};

type ActionDef = {
  label: string;
  description: string;
  route: string;
  stackKey: "settlementQueue" | "distribution" | "fundingManager";
  params: ParamField[];
};

type SavedActionPreset = {
  id: string;
  name: string;
  action: SavedActionType;
  campaignId?: string;
  targetAddr: string;
  params: Record<string, string>;
  createdAt: number;
  updatedAt: number;
  lastUsedAt?: number;
};

const STORAGE_KEY = "uagri.admin.explorer.saved-actions.v1";

const ACTION_ORDER: SavedActionType[] = [
  "batchProcess",
  "notifyReward",
  "onrampDeposit",
  "payoutExecute",
  "payoutConfirm"
];

const ACTION_DEFS: Record<SavedActionType, ActionDef> = {
  batchProcess: {
    label: "BatchProcess",
    description: "SettlementQueue batch processing",
    route: "/admin/settlement",
    stackKey: "settlementQueue",
    params: [
      { key: "epoch", label: "Epoch", placeholder: "uint64 epoch" },
      { key: "reportHash", label: "Report Hash", placeholder: "bytes32 reportHash" }
    ]
  },
  notifyReward: {
    label: "NotifyReward",
    description: "Distribution notifyReward",
    route: "/admin/liquidations",
    stackKey: "distribution",
    params: [
      { key: "amount", label: "Amount", placeholder: "reward amount" },
      { key: "liquidationId", label: "Liquidation Id", placeholder: "uint64 liquidationId" },
      { key: "reportHash", label: "Report Hash", placeholder: "bytes32 reportHash" }
    ]
  },
  onrampDeposit: {
    label: "OnRamp Deposit",
    description: "FundingManager settleDepositExactAssetsFrom",
    route: "/admin/onramp",
    stackKey: "fundingManager",
    params: [
      { key: "payer", label: "Payer", placeholder: "0x payer" },
      { key: "beneficiary", label: "Beneficiary", placeholder: "0x beneficiary" },
      { key: "amountIn", label: "Amount In", placeholder: "settlement amount" },
      { key: "minSharesOut", label: "Min Shares Out", placeholder: "minimum shares out" },
      { key: "deadline", label: "Deadline", placeholder: "uint64 unix deadline" },
      { key: "ref", label: "Ref", placeholder: "bytes32 ref" }
    ]
  },
  payoutExecute: {
    label: "Payout Execute",
    description: "YieldAccumulator claimToWithSig",
    route: "/admin/payouts",
    stackKey: "distribution",
    params: [
      { key: "account", label: "Account", placeholder: "0x account" },
      { key: "to", label: "To", placeholder: "0x to" },
      { key: "maxAmount", label: "Max Amount", placeholder: "token amount" },
      { key: "deadline", label: "Deadline", placeholder: "uint64 unix deadline" },
      { key: "ref", label: "Ref", placeholder: "bytes32 ref" },
      { key: "payoutRailHash", label: "Payout Rail Hash", placeholder: "bytes32 payoutRailHash" },
      { key: "signature", label: "Signature", placeholder: "0x signature", multiline: true }
    ]
  },
  payoutConfirm: {
    label: "Payout Confirm",
    description: "YieldAccumulator confirmPayout",
    route: "/admin/payouts",
    stackKey: "distribution",
    params: [
      { key: "ref", label: "Ref", placeholder: "bytes32 ref" },
      { key: "receiptHash", label: "Receipt Hash", placeholder: "bytes32 receiptHash" }
    ]
  }
};

function makeId(): string {
  return `${Date.now()}-${Math.random().toString(16).slice(2, 10)}`;
}

function canAddr(v?: string): boolean {
  return Boolean(v && isAddress(v));
}

function readString(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const out = value.trim();
  return out.length > 0 ? out : undefined;
}

function actionTargetFromCampaign(action: SavedActionType, campaign?: CampaignView): string {
  const key = ACTION_DEFS[action].stackKey;
  const stack = campaign?.stack as Record<string, string | undefined> | undefined;
  return stack?.[key] ?? "";
}

function sanitizePreset(raw: unknown): SavedActionPreset | undefined {
  if (!raw || typeof raw !== "object") return undefined;
  const obj = raw as Record<string, unknown>;
  const actionRaw = readString(obj.action);
  if (!actionRaw || !ACTION_ORDER.includes(actionRaw as SavedActionType)) return undefined;
  const action = actionRaw as SavedActionType;

  const allowedParamKeys = new Set(ACTION_DEFS[action].params.map((x) => x.key));
  const paramsRaw = obj.params;
  const params: Record<string, string> = {};
  if (paramsRaw && typeof paramsRaw === "object") {
    for (const [key, value] of Object.entries(paramsRaw as Record<string, unknown>)) {
      if (!allowedParamKeys.has(key)) continue;
      const parsed = readString(value);
      if (!parsed) continue;
      params[key] = parsed;
    }
  }

  const id = readString(obj.id) ?? makeId();
  const targetAddr = readString(obj.targetAddr) ?? "";
  const campaignId = readString(obj.campaignId);
  const name = readString(obj.name) ?? ACTION_DEFS[action].label;

  const createdAt =
    typeof obj.createdAt === "number" && Number.isFinite(obj.createdAt)
      ? obj.createdAt
      : Date.now();
  const updatedAt =
    typeof obj.updatedAt === "number" && Number.isFinite(obj.updatedAt)
      ? obj.updatedAt
      : createdAt;
  const lastUsedAt =
    typeof obj.lastUsedAt === "number" && Number.isFinite(obj.lastUsedAt)
      ? obj.lastUsedAt
      : undefined;

  return {
    id,
    name,
    action,
    campaignId,
    targetAddr,
    params,
    createdAt,
    updatedAt,
    lastUsedAt
  };
}
function parseImportPresets(raw: unknown): SavedActionPreset[] {
  let arr: unknown[] = [];
  if (Array.isArray(raw)) {
    arr = raw;
  } else if (raw && typeof raw === "object" && Array.isArray((raw as any).presets)) {
    arr = (raw as any).presets as unknown[];
  }
  return arr.map((item) => sanitizePreset(item)).filter((x): x is SavedActionPreset => Boolean(x));
}

function buildPresetHref(preset: SavedActionPreset): string {
  const route = ACTION_DEFS[preset.action].route;
  const q = new URLSearchParams();
  if (preset.targetAddr) q.set("addr", preset.targetAddr);
  if (preset.campaignId) q.set("campaignId", preset.campaignId);
  for (const [k, v] of Object.entries(preset.params)) {
    const value = String(v ?? "").trim();
    if (!value) continue;
    q.set(k, value);
  }
  if (preset.action === "payoutExecute") q.set("mode", "claim");
  if (preset.action === "payoutConfirm") q.set("mode", "confirm");
  const qs = q.toString();
  return qs ? `${route}?${qs}` : route;
}

function fmtDate(ms?: number): string {
  if (!ms || !Number.isFinite(ms)) return "-";
  return new Date(ms).toLocaleString();
}

function kv(label: string, value?: string) {
  return (
    <div className="rounded-xl border border-border bg-muted p-3">
      <div className="text-xs text-text2">{label}</div>
      <div className="mt-1 break-all font-mono text-xs">{value ?? "-"}</div>
    </div>
  );
}

export default function AdminExplorerPage() {
  const campaigns = useCampaigns();
  const [openId, setOpenId] = React.useState<string | null>(null);

  const [presets, setPresets] = React.useState<SavedActionPreset[]>([]);
  const [draftAction, setDraftAction] = React.useState<SavedActionType>("batchProcess");
  const [draftCampaignId, setDraftCampaignId] = React.useState<string>("");
  const [draftName, setDraftName] = React.useState<string>("");
  const [draftTargetAddr, setDraftTargetAddr] = React.useState<string>("");
  const [draftParams, setDraftParams] = React.useState<Record<string, string>>({});
  const [draftError, setDraftError] = React.useState<string>("");
  const [editingPresetId, setEditingPresetId] = React.useState<string | null>(null);

  const [ioText, setIoText] = React.useState<string>("");
  const [ioError, setIoError] = React.useState<string>("");

  const campaignList = campaigns.data ?? [];
  const selectedCampaign = React.useMemo(
    () => campaignList.find((c) => c.campaignId.toLowerCase() === draftCampaignId.toLowerCase()),
    [campaignList, draftCampaignId]
  );

  React.useEffect(() => {
    if (typeof window === "undefined") return;
    try {
      const raw = window.localStorage.getItem(STORAGE_KEY);
      if (!raw) return;
      const parsed = JSON.parse(raw) as unknown;
      const loaded = parseImportPresets(parsed);
      setPresets(loaded.sort((a, b) => b.updatedAt - a.updatedAt));
    } catch {
      setPresets([]);
    }
  }, []);

  React.useEffect(() => {
    if (typeof window === "undefined") return;
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify(presets.slice(0, 300)));
  }, [presets]);

  React.useEffect(() => {
    if (draftCampaignId || campaignList.length === 0) return;
    setDraftCampaignId(campaignList[0].campaignId);
  }, [draftCampaignId, campaignList]);

  const actionDef = ACTION_DEFS[draftAction];

  const useCampaignStackTarget = React.useCallback(
    (action: SavedActionType, campaign?: CampaignView) => {
      const target = actionTargetFromCampaign(action, campaign);
      if (target) {
        setDraftTargetAddr(target);
      }
      return target;
    },
    []
  );

  const resetDraft = React.useCallback(() => {
    setEditingPresetId(null);
    setDraftError("");
    setDraftName("");
    setDraftParams({});
    const target = actionTargetFromCampaign(draftAction, selectedCampaign);
    setDraftTargetAddr(target ?? "");
  }, [draftAction, selectedCampaign]);

  const loadPresetToDraft = React.useCallback(
    (preset: SavedActionPreset) => {
      setEditingPresetId(preset.id);
      setDraftAction(preset.action);
      setDraftCampaignId(preset.campaignId ?? "");
      setDraftName(preset.name);
      setDraftTargetAddr(preset.targetAddr);
      setDraftParams({ ...preset.params });
      setDraftError("");
    },
    []
  );

  const onDraftActionChange = (action: SavedActionType) => {
    setDraftAction(action);
    setEditingPresetId(null);
    setDraftError("");
    setDraftParams({});
    const target = actionTargetFromCampaign(action, selectedCampaign);
    setDraftTargetAddr(target ?? "");
    if (!draftName.trim()) {
      const suffix = selectedCampaign ? ` ${shortHex32(selectedCampaign.campaignId)}` : "";
      setDraftName(`${ACTION_DEFS[action].label}${suffix}`);
    }
  };

  const onDraftCampaignChange = (campaignId: string) => {
    setDraftCampaignId(campaignId);
    setEditingPresetId(null);
    const campaign = campaignList.find((c) => c.campaignId.toLowerCase() === campaignId.toLowerCase());
    const target = actionTargetFromCampaign(draftAction, campaign);
    if (target) setDraftTargetAddr(target);
    if (!draftName.trim()) {
      const suffix = campaign ? ` ${shortHex32(campaign.campaignId)}` : "";
      setDraftName(`${ACTION_DEFS[draftAction].label}${suffix}`);
    }
  };

  const setDraftParam = (key: string, value: string) => {
    setDraftParams((prev) => ({ ...prev, [key]: value }));
  };

  const saveDraftPreset = () => {
    setDraftError("");
    const name = draftName.trim();
    if (!name) {
      setDraftError("Name is required.");
      return;
    }
    const target = draftTargetAddr.trim();
    if (!target || !canAddr(target)) {
      setDraftError("Target address must be a valid 0x address.");
      return;
    }
    if (draftCampaignId && !isBytes32(draftCampaignId)) {
      setDraftError("CampaignId must be bytes32.");
      return;
    }

    const params: Record<string, string> = {};
    for (const field of ACTION_DEFS[draftAction].params) {
      const value = String(draftParams[field.key] ?? "").trim();
      if (!value) continue;
      params[field.key] = value;
    }

    const now = Date.now();
    if (editingPresetId) {
      setPresets((prev) =>
        prev
          .map((item) =>
            item.id === editingPresetId
              ? {
                  ...item,
                  name,
                  action: draftAction,
                  campaignId: draftCampaignId || undefined,
                  targetAddr: target,
                  params,
                  updatedAt: now
                }
              : item
          )
          .sort((a, b) => b.updatedAt - a.updatedAt)
      );
      setEditingPresetId(null);
      return;
    }

    const preset: SavedActionPreset = {
      id: makeId(),
      name,
      action: draftAction,
      campaignId: draftCampaignId || undefined,
      targetAddr: target,
      params,
      createdAt: now,
      updatedAt: now
    };
    setPresets((prev) => [preset, ...prev].slice(0, 300));
  };

  const quickSave = (campaign: CampaignView, action: SavedActionType) => {
    const target = actionTargetFromCampaign(action, campaign);
    if (!target || !canAddr(target)) return;
    const now = Date.now();
    const preset: SavedActionPreset = {
      id: makeId(),
      name: `${campaign.tokenMeta?.symbol ?? "Campaign"} ${ACTION_DEFS[action].label}`,
      action,
      campaignId: campaign.campaignId,
      targetAddr: target,
      params: {},
      createdAt: now,
      updatedAt: now
    };
    setPresets((prev) => [preset, ...prev].slice(0, 300));
  };

  const removePreset = (id: string) => {
    setPresets((prev) => prev.filter((item) => item.id !== id));
    if (editingPresetId === id) resetDraft();
  };

  const duplicatePreset = (preset: SavedActionPreset) => {
    const now = Date.now();
    const copy: SavedActionPreset = {
      ...preset,
      id: makeId(),
      name: `${preset.name} Copy`,
      createdAt: now,
      updatedAt: now,
      lastUsedAt: undefined
    };
    setPresets((prev) => [copy, ...prev].slice(0, 300));
  };

  const markUsed = (id: string) => {
    const now = Date.now();
    setPresets((prev) =>
      prev.map((item) => (item.id === id ? { ...item, lastUsedAt: now, updatedAt: now } : item))
    );
  };

  const exportToEditor = () => {
    setIoError("");
    setIoText(JSON.stringify(presets, null, 2));
  };

  const copyExport = async () => {
    const json = JSON.stringify(presets, null, 2);
    setIoText(json);
    await navigator.clipboard.writeText(json);
  };

  const importMerge = () => {
    setIoError("");
    try {
      const parsed = JSON.parse(ioText) as unknown;
      const incoming = parseImportPresets(parsed);
      if (incoming.length === 0) {
        setIoError("No valid presets found in JSON.");
        return;
      }
      setPresets((prev) => {
        const map = new Map<string, SavedActionPreset>();
        for (const item of prev) map.set(item.id, item);
        for (const item of incoming) {
          const exists = map.get(item.id);
          if (!exists) {
            map.set(item.id, item);
          } else {
            map.set(item.id, { ...exists, ...item, updatedAt: Date.now() });
          }
        }
        return [...map.values()].sort((a, b) => b.updatedAt - a.updatedAt).slice(0, 300);
      });
    } catch (error: any) {
      setIoError(error?.message || "Invalid JSON.");
    }
  };

  const importReplace = () => {
    setIoError("");
    try {
      const parsed = JSON.parse(ioText) as unknown;
      const incoming = parseImportPresets(parsed);
      if (incoming.length === 0) {
        setIoError("No valid presets found in JSON.");
        return;
      }
      setPresets(incoming.sort((a, b) => b.updatedAt - a.updatedAt).slice(0, 300));
      setEditingPresetId(null);
    } catch (error: any) {
      setIoError(error?.message || "Invalid JSON.");
    }
  };

  return (
    <div>
      <PageHeader
        title="Admin - Explorer"
        subtitle="Inspect campaign stack addresses and run recurring ops through saved action presets."
      />

      <div className="grid gap-4">
        <Card>
          <CardHeader>
            <CardTitle>Saved Actions</CardTitle>
            <CardDescription>
              Presets for ops flows: batchProcess, notifyReward, onramp deposit, payout execute/confirm.
            </CardDescription>
          </CardHeader>
          <CardContent className="space-y-4">
            <div className="rounded-xl border border-border/80 bg-muted p-3">
              <div className="mb-2 text-xs font-semibold uppercase tracking-wide text-text2">Preset Editor</div>
              <div className="grid gap-2 md:grid-cols-2">
                <div>
                  <label className="mb-1 block text-xs text-text2">Action</label>
                  <select
                    className="h-10 w-full rounded-xl border border-border bg-card px-3 text-sm outline-none focus-visible:ring-2 focus-visible:ring-primary/30"
                    value={draftAction}
                    onChange={(e) => onDraftActionChange(e.target.value as SavedActionType)}
                  >
                    {ACTION_ORDER.map((action) => (
                      <option key={action} value={action}>
                        {ACTION_DEFS[action].label}
                      </option>
                    ))}
                  </select>
                </div>

                <div>
                  <label className="mb-1 block text-xs text-text2">Campaign (optional)</label>
                  <select
                    className="h-10 w-full rounded-xl border border-border bg-card px-3 text-sm outline-none focus-visible:ring-2 focus-visible:ring-primary/30"
                    value={draftCampaignId}
                    onChange={(e) => onDraftCampaignChange(e.target.value)}
                  >
                    <option value="">Manual / none</option>
                    {campaignList.map((campaign) => (
                      <option key={campaign.campaignId} value={campaign.campaignId}>
                        {(campaign.tokenMeta?.symbol ?? "Campaign")} {shortHex32(campaign.campaignId)}
                      </option>
                    ))}
                  </select>
                </div>

                <Input
                  value={draftName}
                  onChange={(e) => setDraftName(e.target.value)}
                  placeholder="Preset name"
                  aria-label="Preset name"
                />

                <div className="flex gap-2">
                  <Input
                    value={draftTargetAddr}
                    onChange={(e) => setDraftTargetAddr(e.target.value)}
                    placeholder="Target module address (0x...)"
                    aria-label="Target module address"
                  />
                  <Button
                    variant="secondary"
                    onClick={() => useCampaignStackTarget(draftAction, selectedCampaign)}
                    disabled={!selectedCampaign}
                  >
                    Stack
                  </Button>
                </div>
              </div>

              <div className="mt-3 grid gap-2 md:grid-cols-2">
                {actionDef.params.map((field) =>
                  field.multiline ? (
                    <Textarea
                      key={field.key}
                      value={draftParams[field.key] ?? ""}
                      onChange={(e) => setDraftParam(field.key, e.target.value)}
                      placeholder={field.placeholder}
                      className="min-h-[90px]"
                      aria-label={field.label}
                    />
                  ) : (
                    <Input
                      key={field.key}
                      value={draftParams[field.key] ?? ""}
                      onChange={(e) => setDraftParam(field.key, e.target.value)}
                      placeholder={field.placeholder}
                      aria-label={field.label}
                    />
                  )
                )}
              </div>

              <div className="mt-3 flex flex-wrap items-center gap-2">
                <Badge tone="default">{ACTION_DEFS[draftAction].description}</Badge>
                <Badge tone={canAddr(draftTargetAddr) ? "good" : "warn"}>
                  {canAddr(draftTargetAddr) ? "Target address OK" : "Target address invalid"}
                </Badge>
                <Badge tone={draftCampaignId ? (isBytes32(draftCampaignId) ? "good" : "warn") : "default"}>
                  {draftCampaignId ? shortHex32(draftCampaignId) : "No campaign id"}
                </Badge>
              </div>

              <div className="mt-3 flex flex-wrap items-center gap-2">
                <Button onClick={saveDraftPreset}>{editingPresetId ? "Update preset" : "Save preset"}</Button>
                <Button variant="secondary" onClick={resetDraft}>
                  Clear editor
                </Button>
              </div>

              {draftError ? (
                <div className="mt-3 rounded-xl border border-bad/30 bg-bad/10 p-3 text-sm text-bad">{draftError}</div>
              ) : null}
            </div>

            {presets.length === 0 ? (
              <EmptyState
                title="No saved actions yet"
                description="Create one from the editor or use quick-save buttons on campaign cards."
              />
            ) : (
              <div className="grid gap-3">
                {presets.map((preset) => {
                  const href = buildPresetHref(preset);
                  const paramPairs = Object.entries(preset.params).filter(([, v]) => String(v).trim().length > 0);
                  return (
                    <div key={preset.id} className="rounded-xl border border-border/80 bg-card p-3">
                      <div className="flex flex-wrap items-start justify-between gap-2">
                        <div>
                          <div className="font-medium">{preset.name}</div>
                          <div className="mt-1 text-xs text-text2">{ACTION_DEFS[preset.action].description}</div>
                        </div>
                        <div className="flex flex-wrap gap-2">
                          <Badge tone="accent">{ACTION_DEFS[preset.action].label}</Badge>
                          <Badge tone={canAddr(preset.targetAddr) ? "good" : "warn"}>
                            {canAddr(preset.targetAddr) ? shortAddr(preset.targetAddr, 6) : "target invalid"}
                          </Badge>
                          <Badge tone="default">
                            {preset.campaignId ? shortHex32(preset.campaignId) : "manual"}
                          </Badge>
                        </div>
                      </div>

                      {paramPairs.length > 0 ? (
                        <div className="mt-2 flex flex-wrap gap-2">
                          {paramPairs.slice(0, 8).map(([key, value]) => (
                            <Badge key={`${preset.id}-${key}`} tone="default">
                              {key}: {String(value).slice(0, 22)}
                            </Badge>
                          ))}
                        </div>
                      ) : (
                        <div className="mt-2 text-xs text-text2">No extra params. Preset opens target module only.</div>
                      )}

                      <div className="mt-2 text-xs text-text2 break-all">{href}</div>

                      <div className="mt-3 flex flex-wrap items-center gap-2">
                        <a
                          href={href}
                          className="inline-flex h-9 items-center justify-center rounded-xl border border-border bg-card px-3 text-sm hover:bg-muted"
                          onClick={() => markUsed(preset.id)}
                        >
                          Open preset
                        </a>
                        <Button variant="secondary" onClick={() => navigator.clipboard.writeText(href)}>
                          Copy URL
                        </Button>
                        <Button variant="secondary" onClick={() => loadPresetToDraft(preset)}>
                          Edit
                        </Button>
                        <Button variant="secondary" onClick={() => duplicatePreset(preset)}>
                          Duplicate
                        </Button>
                        <Button variant="secondary" onClick={() => removePreset(preset.id)}>
                          Delete
                        </Button>
                      </div>

                      <div className="mt-2 text-[11px] text-text2">
                        Updated {fmtDate(preset.updatedAt)}
                        {preset.lastUsedAt ? ` · Last used ${fmtDate(preset.lastUsedAt)}` : ""}
                      </div>
                    </div>
                  );
                })}
              </div>
            )}

            <div className="rounded-xl border border-border/80 bg-muted p-3">
              <div className="mb-2 text-xs font-semibold uppercase tracking-wide text-text2">Export / Import JSON</div>
              <Textarea
                value={ioText}
                onChange={(e) => setIoText(e.target.value)}
                className="min-h-[140px]"
                placeholder='Paste presets JSON array or object with {"presets":[...]}'
                aria-label="Presets JSON"
              />
              <div className="mt-3 flex flex-wrap items-center gap-2">
                <Button variant="secondary" onClick={exportToEditor}>
                  Export to editor
                </Button>
                <Button variant="secondary" onClick={() => void copyExport()}>
                  Copy export
                </Button>
                <Button variant="secondary" onClick={importMerge}>
                  Import merge
                </Button>
                <Button variant="secondary" onClick={importReplace}>
                  Import replace
                </Button>
                <Button variant="secondary" onClick={() => { setIoText(""); setIoError(""); }}>
                  Clear JSON
                </Button>
              </div>
              {ioError ? (
                <div className="mt-3 rounded-xl border border-bad/30 bg-bad/10 p-3 text-sm text-bad">{ioError}</div>
              ) : null}
            </div>
          </CardContent>
        </Card>
      </div>

      {campaigns.isLoading ? (
        <div className="mt-4 grid gap-3 md:grid-cols-2">
          <Skeleton className="h-28" />
          <Skeleton className="h-28" />
          <Skeleton className="h-28" />
          <Skeleton className="h-28" />
        </div>
      ) : campaigns.error ? (
        <div className="mt-4">
          <ErrorState
            title="Failed to load campaigns"
            description={(campaigns.error as any)?.message}
            onRetry={() => campaigns.refetch()}
          />
        </div>
      ) : (campaigns.data?.length ?? 0) === 0 ? (
        <div className="mt-4">
          <EmptyState
            title="No campaigns found"
            description="Deploy a campaign first, then refresh."
            ctaLabel="Retry"
            onCta={() => campaigns.refetch()}
          />
        </div>
      ) : (
        <div className="mt-4 space-y-3">
          {campaigns.data!.map((c) => {
            const isOpen = openId?.toLowerCase() === c.campaignId.toLowerCase();
            const s = c.stack;
            const warnNoStack = !s || !s.shareToken;
            return (
              <Card key={c.campaignId}>
                <CardHeader className="flex flex-row items-start justify-between gap-3">
                  <div>
                    <CardTitle className="flex items-center gap-2">
                      {c.tokenMeta?.symbol ?? "Campaign"}
                      <Badge tone={warnNoStack ? "warn" : "good"}>
                        {warnNoStack ? "Legacy/unknown stack" : "Factory stack"}
                      </Badge>
                    </CardTitle>
                    <CardDescription>
                      {shortHex32(c.campaignId)} · Plot {shortHex32(c.plotRef)} · Settlement {shortAddr(c.settlementAsset)}
                    </CardDescription>
                  </div>
                  <div className="flex items-center gap-2">
                    <Link className="text-sm text-primary underline" href={`/campaigns/${c.campaignId}`}>
                      View
                    </Link>
                    <Button variant="secondary" onClick={() => setOpenId(isOpen ? null : c.campaignId)}>
                      {isOpen ? "Hide" : "Modules"}
                    </Button>
                  </div>
                </CardHeader>

                {isOpen ? (
                  <CardContent className="space-y-3">
                    <div className="grid gap-2 md:grid-cols-2">
                      {kv("RoleManager", s?.roleManager)}
                      {kv("CampaignRegistry", s?.registry)}
                      {kv("ShareToken", s?.shareToken)}
                      {kv("Treasury", s?.treasury)}
                      {kv("FundingManager", s?.fundingManager)}
                      {kv("SettlementQueue", s?.settlementQueue)}
                      {kv("Compliance", s?.compliance)}
                      {kv("Disaster", s?.disaster)}
                      {kv("Freeze", s?.freezeModule)}
                      {kv("Custody", s?.custody)}
                      {kv("Trace", s?.trace)}
                      {kv("DocumentRegistry", s?.documentRegistry)}
                      {kv("BatchAnchor", s?.batchAnchor)}
                      {kv("Distribution", s?.distribution)}
                      {kv("Insurance", s?.insurance)}
                    </div>

                    <div className="flex flex-wrap gap-2">
                      <Link
                        href={`/admin/roles?addr=${s?.roleManager ?? ""}`}
                        className="rounded-xl border border-border bg-card px-3 py-2 text-sm hover:shadow-soft"
                      >
                        Roles
                      </Link>
                      <Link
                        href={`/admin/settlement?addr=${s?.settlementQueue ?? ""}`}
                        className="rounded-xl border border-border bg-card px-3 py-2 text-sm hover:shadow-soft"
                      >
                        Settlement
                      </Link>
                      <Link
                        href={`/admin/onramp?addr=${s?.fundingManager ?? ""}`}
                        className="rounded-xl border border-border bg-card px-3 py-2 text-sm hover:shadow-soft"
                      >
                        OnRamp
                      </Link>
                      <Link
                        href={`/admin/payouts?addr=${s?.distribution ?? ""}`}
                        className="rounded-xl border border-border bg-card px-3 py-2 text-sm hover:shadow-soft"
                      >
                        Payouts
                      </Link>
                      <Link
                        href={`/admin/liquidations?addr=${s?.distribution ?? ""}`}
                        className="rounded-xl border border-border bg-card px-3 py-2 text-sm hover:shadow-soft"
                      >
                        Liquidations
                      </Link>
                      <Link
                        href={`/admin/oracles?campaignId=${c.campaignId}`}
                        className="rounded-xl border border-border bg-card px-3 py-2 text-sm hover:shadow-soft"
                      >
                        Oracles
                      </Link>
                      <Link
                        href={`/admin/treasury?addr=${s?.treasury ?? ""}`}
                        className="rounded-xl border border-border bg-card px-3 py-2 text-sm hover:shadow-soft"
                      >
                        Treasury
                      </Link>
                      <Link
                        href={`/admin/disaster?addr=${s?.disaster ?? ""}&token=${s?.shareToken ?? ""}&campaignId=${c.campaignId}`}
                        className="rounded-xl border border-border bg-card px-3 py-2 text-sm hover:shadow-soft"
                      >
                        Disaster
                      </Link>
                      <Link
                        href={`/admin/trace?trace=${s?.trace ?? ""}&docs=${s?.documentRegistry ?? ""}&anchor=${s?.batchAnchor ?? ""}&campaignId=${c.campaignId}`}
                        className="rounded-xl border border-border bg-card px-3 py-2 text-sm hover:shadow-soft"
                      >
                        Trace & Docs
                      </Link>
                      <Link
                        href={`/admin/contract-tool?address=${s?.shareToken ?? ""}`}
                        className="rounded-xl border border-border bg-card px-3 py-2 text-sm hover:shadow-soft"
                      >
                        Contract Tool
                      </Link>
                    </div>

                    <div className="rounded-xl border border-border/80 bg-muted p-3">
                      <div className="text-xs text-text2">Quick-save presets for this campaign</div>
                      <div className="mt-2 flex flex-wrap gap-2">
                        {ACTION_ORDER.map((action) => {
                          const target = actionTargetFromCampaign(action, c);
                          const disabled = !target || !canAddr(target);
                          return (
                            <Button
                              key={`${c.campaignId}-${action}`}
                              size="sm"
                              variant="secondary"
                              disabled={disabled}
                              onClick={() => quickSave(c, action)}
                            >
                              Save {ACTION_DEFS[action].label}
                            </Button>
                          );
                        })}
                      </div>
                    </div>
                  </CardContent>
                ) : null}
              </Card>
            );
          })}
        </div>
      )}
    </div>
  );
}
