"use client";

import * as React from "react";
import {
  Abi,
  AbiFunction,
  encodeFunctionData,
  encodePacked,
  isAddress,
  isHex,
  keccak256,
  parseAbi,
  toHex
} from "viem";
import { useAccount, useChainId, usePublicClient } from "wagmi";

import { PageHeader } from "@/components/ui/PageHeader";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { Textarea } from "@/components/ui/Textarea";
import { Button } from "@/components/ui/Button";
import { Badge } from "@/components/ui/Badge";
import { explorerAddressUrl, explorerTxUrl } from "@/lib/explorer";
import { bytes32FromText, isBytes32 } from "@/lib/bytes32";
import { useTx } from "@/hooks/useTx";
import { abiByName, abiManifest } from "@/abis";

const HISTORY_STORAGE_KEY = "uagri.contract-tool.v2.history";
const HISTORY_LIMIT = 40;
const DEFAULT_DEMO_ADDRESS = "0x0000000000000000000000000000000000000000";

type ContractToolHistoryEntry = {
  id: string;
  at: string;
  chainId: number;
  address: `0x${string}`;
  abiName: string;
  functionSignature: string;
  mode: "read" | "write";
  calldata: `0x${string}`;
  argsJson: string;
  resultJson?: string;
  txHash?: `0x${string}`;
  error?: string;
};

function safeJsonParse<T>(s: string): T | null {
  try {
    return JSON.parse(s) as T;
  } catch {
    return null;
  }
}

function toDisplayJson(value: unknown): string {
  return JSON.stringify(
    value,
    (_k, v) => (typeof v === "bigint" ? v.toString() : v),
    2
  );
}

function canonicalParamType(param: any): string {
  const rawType = typeof param?.type === "string" ? param.type : "";
  if (!rawType.startsWith("tuple")) return rawType;
  const suffix = rawType.slice("tuple".length);
  const components = Array.isArray(param?.components) ? param.components : [];
  return `(${components.map((c: any) => canonicalParamType(c)).join(",")})${suffix}`;
}

function fnSignature(fn: AbiFunction): string {
  const inputs = Array.isArray(fn.inputs) ? fn.inputs : [];
  return `${fn.name}(${inputs.map((i) => canonicalParamType(i)).join(",")})`;
}

function isArrayType(type: string): boolean {
  return /\[[0-9]*\]$/u.test(type);
}

function arrayMeta(type: string): { itemType: string; fixed: number | null } {
  const m = type.match(/^(.*)\[([0-9]*)\]$/u);
  if (!m) return { itemType: type, fixed: null };
  return { itemType: m[1], fixed: m[2] ? Number(m[2]) : null };
}

function arrayItemParam(param: any): any {
  return { ...param, type: arrayMeta(String(param?.type ?? "")).itemType };
}

function paramName(param: any, idx: number): string {
  const raw = String(param?.name ?? "").trim();
  return raw || `arg${idx}`;
}

function enumLabel(param: any): string | null {
  const it = String(param?.internalType ?? "");
  return it.startsWith("enum ") ? it.replace(/^enum\s+/u, "") : null;
}

function defaultValueForParam(param: any): unknown {
  const type = String(param?.type ?? "");
  if (isArrayType(type)) {
    const { fixed } = arrayMeta(type);
    const item = arrayItemParam(param);
    return Array.from({ length: fixed ?? 0 }).map(() => defaultValueForParam(item));
  }
  if (type.startsWith("tuple")) {
    const components = Array.isArray(param?.components) ? param.components : [];
    return components.map((c: any) => defaultValueForParam(c));
  }
  if (type === "bool") return false;
  return "";
}

function getAtPath(root: unknown, path: number[]): unknown {
  let cur = root;
  for (const i of path) {
    if (!Array.isArray(cur)) return undefined;
    cur = cur[i];
  }
  return cur;
}

function setAtPath(root: unknown, path: number[], value: unknown): unknown {
  if (path.length === 0) return value;
  const [head, ...rest] = path;
  const out = Array.isArray(root) ? [...root] : [];
  out[head] = setAtPath(out[head], rest, value);
  return out;
}

function parseBool(value: unknown): boolean {
  if (typeof value === "boolean") return value;
  const t = String(value ?? "").trim().toLowerCase();
  if (t === "true" || t === "1") return true;
  if (t === "false" || t === "0") return false;
  throw new Error("bool expects true/false");
}

function parseInteger(type: string, value: unknown): bigint {
  if (typeof value === "bigint") return value;
  if (typeof value === "number" && Number.isFinite(value)) return BigInt(Math.trunc(value));
  const text = String(value ?? "").trim();
  if (!text) throw new Error(`${type} expects a number`);
  try {
    return BigInt(text);
  } catch {
    throw new Error(`${type} expects a valid integer`);
  }
}

function parseAddress(value: unknown): `0x${string}` {
  const text = String(value ?? "").trim();
  if (!isAddress(text)) throw new Error("address expects a valid 0x address");
  return text as `0x${string}`;
}

function parseBytes(type: string, value: unknown, opts: { hashBytes32Labels: boolean }): `0x${string}` {
  const text = String(value ?? "").trim();
  const plain = text.length > 0 && !text.startsWith("0x");

  if (type === "bytes32") {
    if (!text) throw new Error("bytes32 expects a value");
    if (!plain) {
      if (!isBytes32(text)) throw new Error("bytes32 expects 0x + 64 hex chars");
      return text;
    }
    if (opts.hashBytes32Labels) return keccak256(toHex(text));
    const padded = bytes32FromText(text);
    if (!padded) throw new Error("bytes32 text is too long (max 32 bytes)");
    return padded;
  }

  if (!text) return "0x";
  if (text.startsWith("0x")) {
    if (!isHex(text)) throw new Error(`${type} expects valid hex (0x...)`);
    return text;
  }
  return toHex(text);
}

function castByParam(param: any, value: unknown, opts: { hashBytes32Labels: boolean }): any {
  const type = String(param?.type ?? "");

  if (isArrayType(type)) {
    if (!Array.isArray(value)) throw new Error(`${type} expects an array`);
    const { fixed } = arrayMeta(type);
    if (fixed != null && value.length !== fixed) throw new Error(`${type} expects exactly ${fixed} item(s)`);
    const item = arrayItemParam(param);
    return value.map((v) => castByParam(item, v, opts));
  }

  if (type.startsWith("tuple")) {
    if (!Array.isArray(value)) throw new Error(`${type} expects a tuple`);
    const components = Array.isArray(param?.components) ? param.components : [];
    if (value.length !== components.length) throw new Error(`${type} expects ${components.length} field(s)`);
    return components.map((c: any, i: number) => castByParam(c, value[i], opts));
  }

  if (type === "bool") return parseBool(value);
  if (type === "address") return parseAddress(value);
  if (type === "string") return String(value ?? "");
  if (type.startsWith("bytes")) return parseBytes(type, value, opts);
  if (type.startsWith("uint") || type.startsWith("int")) return parseInteger(type, value);

  if (typeof value === "string") {
    const parsed = safeJsonParse<any>(value.trim());
    return parsed ?? value;
  }
  return value;
}

export default function ContractToolPage() {
  const chainId = useChainId();
  const client = usePublicClient();
  const { isConnected } = useAccount();
  const { sendTx } = useTx();

  const [address, setAddress] = React.useState<string>(DEFAULT_DEMO_ADDRESS);
  const [abiQuery, setAbiQuery] = React.useState<string>("");
  const [knownAbiName, setKnownAbiName] = React.useState<string>("");
  const [abiMode, setAbiMode] = React.useState<"signatures" | "json">("signatures");
  const [hashBytes32Labels, setHashBytes32Labels] = React.useState<boolean>(false);

  const [abiText, setAbiText] = React.useState<string>(
    [
      "// Paste Solidity signatures (one per line), for example:\n",
      "function stacks(bytes32) view returns (tuple(address roleManager,address registry,address shareToken,address treasury,address fundingManager,address settlementQueue,address distribution,address complianceModule,address documentRegistry,address traceModule,address freezeModule,address custodyModule,address insuranceModule))\n",
      "event CampaignDeployed(bytes32 indexed campaignId, address indexed roleManager, address indexed shareToken, address registry, address treasury, address fundingManager, address settlementQueue)\n"
    ].join("")
  );
  const [abiJsonText, setAbiJsonText] = React.useState<string>("[]");

  const [abi, setAbi] = React.useState<Abi | null>(null);
  const [functions, setFunctions] = React.useState<Array<{ signature: string; fn: AbiFunction }>>([]);
  const [selectedSignature, setSelectedSignature] = React.useState<string>("");
  const [functionQuery, setFunctionQuery] = React.useState<string>("");
  const [argValues, setArgValues] = React.useState<unknown[]>([]);
  const [calldata, setCalldata] = React.useState<`0x${string}` | "">("");
  const [result, setResult] = React.useState<string>("");
  const [error, setError] = React.useState<string>("");
  const [hint, setHint] = React.useState<string>("");

  const [history, setHistory] = React.useState<ContractToolHistoryEntry[]>([]);
  const [historyLoaded, setHistoryLoaded] = React.useState<boolean>(false);
  const [focusedBytes32Path, setFocusedBytes32Path] = React.useState<number[] | null>(null);

  const [refLabel, setRefLabel] = React.useState<string>("");
  const [refTs, setRefTs] = React.useState<string>(() => String(Math.floor(Date.now() / 1000)));
  const [refCampaignId, setRefCampaignId] = React.useState<string>("");

  const knownAbiOptions = React.useMemo(
    () =>
      [...abiManifest]
        .sort((a, b) => `${a.category}.${a.name}`.localeCompare(`${b.category}.${b.name}`))
        .filter((entry) => {
          const q = abiQuery.trim().toLowerCase();
          if (!q) return true;
          return entry.name.toLowerCase().includes(q) || entry.category.toLowerCase().includes(q);
        }),
    [abiQuery]
  );

  const selectedFunction = React.useMemo(
    () => functions.find((entry) => entry.signature === selectedSignature) ?? null,
    [functions, selectedSignature]
  );

  const filteredFunctions = React.useMemo(() => {
    const q = functionQuery.trim().toLowerCase();
    if (!q) return functions;
    return functions.filter((entry) => {
      const mut = String(entry.fn.stateMutability ?? "").toLowerCase();
      return entry.signature.toLowerCase().includes(q) || entry.fn.name.toLowerCase().includes(q) || mut.includes(q);
    });
  }, [functions, functionQuery]);

  const refTsBigInt = React.useMemo(() => {
    const trimmed = refTs.trim();
    if (!trimmed) return null;
    try {
      return BigInt(trimmed);
    } catch {
      return null;
    }
  }, [refTs]);

  const builtRef = React.useMemo(() => {
    const label = refLabel.trim();
    const campaign = refCampaignId.trim();
    if (!label || refTsBigInt == null || !isBytes32(campaign)) return "";
    try {
      return keccak256(encodePacked(["string", "uint64", "bytes32"], [label, refTsBigInt, campaign]));
    } catch {
      return "";
    }
  }, [refLabel, refTsBigInt, refCampaignId]);

  React.useEffect(() => {
    if (typeof window === "undefined") return;
    const query = new URLSearchParams(window.location.search);
    const qAddress = query.get("address") ?? DEFAULT_DEMO_ADDRESS;
    const qAbi = query.get("abi") ?? "";
    const qCampaignId = query.get("campaignId") ?? "";
    if (qAddress) setAddress(qAddress);
    if (qAbi) setKnownAbiName(qAbi);
    if (qCampaignId) setRefCampaignId(qCampaignId);
  }, []);

  React.useEffect(() => {
    if (typeof window === "undefined") return;
    try {
      const raw = window.localStorage.getItem(HISTORY_STORAGE_KEY);
      if (!raw) {
        setHistoryLoaded(true);
        return;
      }
      const parsed = JSON.parse(raw) as ContractToolHistoryEntry[];
      if (Array.isArray(parsed)) {
        setHistory(parsed.slice(0, HISTORY_LIMIT));
      }
    } catch {
      // ignore malformed cache
    } finally {
      setHistoryLoaded(true);
    }
  }, []);

  React.useEffect(() => {
    if (!historyLoaded || typeof window === "undefined") return;
    window.localStorage.setItem(HISTORY_STORAGE_KEY, JSON.stringify(history.slice(0, HISTORY_LIMIT)));
  }, [historyLoaded, history]);

  const setLoadedAbi = React.useCallback((loaded: Abi) => {
    const entries = (loaded as any[])
      .filter((item) => item?.type === "function")
      .map((fn) => ({ fn: fn as AbiFunction, signature: fnSignature(fn as AbiFunction) }))
      .sort((a, b) => `${a.fn.name}.${a.signature}`.localeCompare(`${b.fn.name}.${b.signature}`));
    setAbi(loaded);
    setFunctions(entries);
    setSelectedSignature(entries[0]?.signature ?? "");
    setFunctionQuery("");
    setArgValues(entries[0] ? (entries[0].fn.inputs ?? []).map((p) => defaultValueForParam(p)) : []);
    setCalldata("");
    setResult("");
    setError("");
  }, []);

  const loadAbi = React.useCallback(() => {
    setError("");
    setResult("");
    setHint("");
    try {
      let loaded: Abi;
      if (abiMode === "json") {
        const parsed = safeJsonParse<any>(abiJsonText);
        if (!Array.isArray(parsed)) throw new Error("ABI JSON must be an array");
        loaded = parsed as Abi;
      } else {
        const lines = abiText
          .split("\n")
          .map((line) => line.trim())
          .filter((line) => !!line && !line.startsWith("//"));
        loaded = parseAbi(lines);
      }
      setLoadedAbi(loaded);
    } catch (e: any) {
      setError(e?.message ?? "Failed to parse ABI");
    }
  }, [abiMode, abiJsonText, abiText, setLoadedAbi]);

  const loadKnownAbi = React.useCallback(() => {
    setError("");
    setResult("");
    setHint("");
    try {
      if (!knownAbiName) throw new Error("Select a known ABI");
      const loaded = abiByName[knownAbiName];
      if (!loaded) throw new Error(`Unknown ABI: ${knownAbiName}`);
      setLoadedAbi(loaded);
      setAbiMode("json");
      setAbiJsonText(JSON.stringify(loaded, null, 2));
    } catch (e: any) {
      setError(e?.message ?? "Failed to load ABI");
    }
  }, [knownAbiName, setLoadedAbi]);

  React.useEffect(() => {
    if (!selectedFunction) {
      setArgValues([]);
      return;
    }
    setArgValues((selectedFunction.fn.inputs ?? []).map((p) => defaultValueForParam(p)));
    setCalldata("");
    setResult("");
    setError("");
  }, [selectedSignature, selectedFunction]);

  const addHistory = React.useCallback((entry: Omit<ContractToolHistoryEntry, "id" | "at">) => {
    const next: ContractToolHistoryEntry = {
      ...entry,
      id: `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
      at: new Date().toISOString()
    };
    setHistory((prev) => [next, ...prev].slice(0, HISTORY_LIMIT));
  }, []);

  const copyText = React.useCallback(async (label: string, text: string) => {
    if (!text) return;
    try {
      await navigator.clipboard.writeText(text);
      setHint(`${label} copied.`);
    } catch {
      setHint(`Failed to copy ${label}.`);
    }
  }, []);

  const parseInvocation = React.useCallback(() => {
    if (!selectedFunction) throw new Error("Select a function first");
    if (!isAddress(address)) throw new Error("Invalid contract address");
    const args = (selectedFunction.fn.inputs ?? []).map((param, index) =>
      castByParam(param, argValues[index], { hashBytes32Labels })
    );
    const fnAbi = [selectedFunction.fn] as unknown as Abi;
    const encoded = encodeFunctionData({
      abi: fnAbi,
      functionName: selectedFunction.fn.name as any,
      args
    } as any);
    return {
      fnAbi,
      args,
      calldata: encoded,
      isRead:
        selectedFunction.fn.stateMutability === "view" ||
        selectedFunction.fn.stateMutability === "pure"
    };
  }, [selectedFunction, address, argValues, hashBytes32Labels]);

  const buildCalldata = React.useCallback(() => {
    setError("");
    setHint("");
    try {
      const parsed = parseInvocation();
      setCalldata(parsed.calldata);
      setHint("Calldata generated.");
    } catch (e: any) {
      setError(e?.shortMessage ?? e?.message ?? "Could not encode calldata");
    }
  }, [parseInvocation]);

  const execute = React.useCallback(async () => {
    setError("");
    setResult("");
    setHint("");
    if (!client) {
      setError("Public client is unavailable.");
      return;
    }

    try {
      const parsed = parseInvocation();
      setCalldata(parsed.calldata);
      const argsJson = toDisplayJson(parsed.args);
      if (parsed.isRead) {
        const out = await client.readContract({
          address: address as `0x${string}`,
          abi: parsed.fnAbi,
          functionName: selectedFunction!.fn.name as any,
          args: parsed.args
        } as any);
        const outText = toDisplayJson(out);
        setResult(outText);
        addHistory({
          chainId,
          address: address as `0x${string}`,
          abiName: knownAbiName || "custom",
          functionSignature: selectedFunction!.signature,
          mode: "read",
          calldata: parsed.calldata,
          argsJson,
          resultJson: outText
        });
        setHint("Read call executed.");
      } else {
        if (!isConnected) throw new Error("Connect wallet to send transactions");
        const txHash = await sendTx({
          title: `Write: ${selectedFunction!.fn.name}`,
          address: address as `0x${string}`,
          abi: parsed.fnAbi,
          functionName: selectedFunction!.fn.name as any,
          args: parsed.args
        } as any);
        addHistory({
          chainId,
          address: address as `0x${string}`,
          abiName: knownAbiName || "custom",
          functionSignature: selectedFunction!.signature,
          mode: "write",
          calldata: parsed.calldata,
          argsJson,
          txHash
        });
        setHint("Transaction submitted.");
      }
    } catch (e: any) {
      const msg = e?.shortMessage ?? e?.message ?? "Call failed";
      setError(msg);
      if (selectedFunction && isAddress(address) && calldata) {
        addHistory({
          chainId,
          address: address as `0x${string}`,
          abiName: knownAbiName || "custom",
          functionSignature: selectedFunction.signature,
          mode:
            selectedFunction.fn.stateMutability === "view" ||
            selectedFunction.fn.stateMutability === "pure"
              ? "read"
              : "write",
          calldata,
          argsJson: toDisplayJson(argValues),
          error: msg
        });
      }
    }
  }, [
    client,
    parseInvocation,
    chainId,
    address,
    selectedFunction,
    knownAbiName,
    isConnected,
    sendTx,
    addHistory,
    calldata,
    argValues
  ]);

  const updateArgAtPath = React.useCallback((path: number[], value: unknown) => {
    setArgValues((prev) => setAtPath(prev, path, value) as unknown[]);
  }, []);

  function renderParamEditor(param: any, path: number[], fallbackIndex: number): React.ReactNode {
    const type = String(param?.type ?? "");
    const label = paramName(param, fallbackIndex);
    const currentValue = getAtPath(argValues, path);
    const enumType = enumLabel(param);

    if (isArrayType(type)) {
      const { fixed } = arrayMeta(type);
      const itemParam = arrayItemParam(param);
      const list = Array.isArray(currentValue) ? currentValue : [];
      return (
        <div className="space-y-2 rounded-xl border border-border/70 bg-card p-3">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <div className="text-xs text-text2">
              <span className="font-medium text-text">{label}</span> <span className="font-mono">{type}</span>
            </div>
            <div className="flex items-center gap-2">
              {fixed == null ? (
                <>
                  <Input
                    type="number"
                    min={0}
                    value={list.length}
                    onChange={(e) => {
                      const nextLen = Math.max(0, Number(e.target.value || 0));
                      setArgValues((prev) => {
                        const current = getAtPath(prev, path);
                        const next = Array.isArray(current) ? [...current] : [];
                        while (next.length < nextLen) next.push(defaultValueForParam(itemParam));
                        while (next.length > nextLen) next.pop();
                        return setAtPath(prev, path, next) as unknown[];
                      });
                    }}
                    className="h-9 w-24"
                  />
                  <Button
                    size="sm"
                    variant="secondary"
                    onClick={() =>
                      setArgValues((prev) => {
                        const current = getAtPath(prev, path);
                        const next = Array.isArray(current) ? [...current] : [];
                        next.push(defaultValueForParam(itemParam));
                        return setAtPath(prev, path, next) as unknown[];
                      })
                    }
                  >
                    Add
                  </Button>
                </>
              ) : (
                <Badge tone="warn">fixed length {fixed}</Badge>
              )}
            </div>
          </div>
          {list.length === 0 ? (
            <div className="text-xs text-text2">No items yet.</div>
          ) : (
            <div className="space-y-2">
              {list.map((_entry, index) => (
                <div key={`${path.join(".")}:${index}`} className="space-y-2 rounded-lg border border-border/60 p-2">
                  <div className="flex items-center justify-between">
                    <div className="text-xs text-text2">
                      item[{index}] <span className="font-mono">{itemParam.type}</span>
                    </div>
                    {fixed == null ? (
                      <Button
                        size="sm"
                        variant="ghost"
                        onClick={() =>
                          setArgValues((prev) => {
                            const current = getAtPath(prev, path);
                            const next = Array.isArray(current) ? [...current] : [];
                            next.splice(index, 1);
                            return setAtPath(prev, path, next) as unknown[];
                          })
                        }
                      >
                        Remove
                      </Button>
                    ) : null}
                  </div>
                  {renderParamEditor(itemParam, [...path, index], index)}
                </div>
              ))}
            </div>
          )}
        </div>
      );
    }

    if (type.startsWith("tuple")) {
      const components = Array.isArray(param?.components) ? param.components : [];
      return (
        <div className="space-y-2 rounded-xl border border-border/70 bg-card p-3">
          <div className="text-xs text-text2">
            <span className="font-medium text-text">{label}</span> <span className="font-mono">{type}</span>
          </div>
          {components.length === 0 ? (
            <div className="text-xs text-text2">Tuple without components.</div>
          ) : (
            <div className="space-y-2">
              {components.map((component: any, index: number) => (
                <div key={`${path.join(".")}:${index}`}>{renderParamEditor(component, [...path, index], index)}</div>
              ))}
            </div>
          )}
        </div>
      );
    }

    if (type === "bool") {
      const boolValue =
        currentValue === true || String(currentValue ?? "").toLowerCase() === "true" || String(currentValue ?? "") === "1";
      return (
        <div className="grid gap-1">
          <div className="text-xs text-text2">
            {label} <span className="font-mono">{type}</span>
          </div>
          <select
            className="h-11 w-full rounded-xl border border-border/90 bg-card px-3 text-sm"
            value={boolValue ? "true" : "false"}
            onChange={(e) => updateArgAtPath(path, e.target.value === "true")}
          >
            <option value="false">false</option>
            <option value="true">true</option>
          </select>
        </div>
      );
    }

    if (type === "bytes32") {
      const text = String(currentValue ?? "");
      const trimmed = text.trim();
      const plain = trimmed.length > 0 && !trimmed.startsWith("0x");
      const padded = plain ? bytes32FromText(trimmed) : undefined;
      const hash = plain ? keccak256(toHex(trimmed)) : undefined;
      return (
        <div className="space-y-2 rounded-xl border border-border/70 bg-card p-3">
          <div className="text-xs text-text2">
            {label} <span className="font-mono">{type}</span>
          </div>
          <Input
            value={text}
            onFocus={() => setFocusedBytes32Path(path)}
            onChange={(e) => updateArgAtPath(path, e.target.value)}
            placeholder={hashBytes32Labels ? "0x... or plain label (keccak)" : "0x... or plain text (bytes32)"}
            className="font-mono text-xs"
          />
          <div className="flex flex-wrap gap-2">
            <Button size="sm" variant="secondary" disabled={!padded} onClick={() => padded && updateArgAtPath(path, padded)}>
              Use bytes32(text)
            </Button>
            <Button size="sm" variant="secondary" disabled={!hash} onClick={() => hash && updateArgAtPath(path, hash)}>
              Use keccak(text)
            </Button>
            <Button size="sm" variant="ghost" disabled={!trimmed} onClick={() => trimmed && copyText(label, trimmed)}>
              Copy
            </Button>
          </div>
          {plain ? (
            <div className="grid gap-1 rounded-lg border border-border/60 bg-muted p-2 text-xs">
              <div className="text-text2">bytes32 padded: {padded ?? "text too long (>32 bytes)"}</div>
              <div className="break-all text-text2">keccak256: {hash}</div>
            </div>
          ) : null}
        </div>
      );
    }

    return (
      <div className="grid gap-1">
        <div className="text-xs text-text2">
          {label} <span className="font-mono">{type}</span>
          {enumType ? <span className="ml-1 text-amber-300">enum {enumType}</span> : null}
        </div>
        <Input
          value={String(currentValue ?? "")}
          onChange={(e) => updateArgAtPath(path, e.target.value)}
          placeholder={enumType ? "enum index (number)" : type}
          className={
            type.startsWith("uint") || type.startsWith("int") || type.startsWith("bytes")
              ? "font-mono text-xs"
              : ""
          }
        />
      </div>
    );
  }

  return (
    <div>
      <PageHeader
        title="Admin - Contract Tool v2"
        subtitle="Known ABI selector, tuple/array auto-forms, bytes32 helpers, calldata builder, and local history."
      />

      <div className="grid gap-4 xl:grid-cols-[420px_minmax(0,1fr)]">
        <Card>
          <CardHeader>
            <CardTitle>Target</CardTitle>
            <CardDescription>Set contract address, load ABI, and configure helpers.</CardDescription>
          </CardHeader>
          <CardContent className="space-y-3">
            <div className="grid gap-2 md:grid-cols-3">
              <div className="md:col-span-2">
                <Input value={address} onChange={(e) => setAddress(e.target.value)} placeholder="0x..." className="font-mono text-xs" />
              </div>
              <div className="flex items-center gap-2">
                <Badge tone={isAddress(address) ? "good" : "warn"}>{isAddress(address) ? "Ready" : "Missing"}</Badge>
                {isAddress(address) ? (
                  <a
                    className="text-sm text-primary underline"
                    href={explorerAddressUrl(chainId, address as `0x${string}`)}
                    target="_blank"
                    rel="noreferrer"
                  >
                    Explorer
                  </a>
                ) : null}
              </div>
            </div>

            <Input
              value={abiQuery}
              onChange={(e) => setAbiQuery(e.target.value)}
              placeholder="Filter known ABIs by name/category"
            />

            <div className="grid gap-2 md:grid-cols-3">
              <div className="md:col-span-2">
                <label className="text-xs text-text2">Known ABI</label>
                <select
                  className="mt-1 w-full rounded-xl border border-border bg-surface px-3 py-2 text-sm"
                  value={knownAbiName}
                  onChange={(e) => setKnownAbiName(e.target.value)}
                >
                  <option value="">Select ABI...</option>
                  {knownAbiOptions.map((entry) => (
                    <option key={entry.name} value={entry.name}>
                      {entry.name} - {entry.category}
                    </option>
                  ))}
                </select>
              </div>
              <div className="flex items-end gap-2">
                <Button variant="secondary" onClick={loadKnownAbi} className="w-full">
                  Load Selected
                </Button>
              </div>
            </div>

            <div className="flex flex-wrap items-center gap-2">
              <Button variant={abiMode === "signatures" ? "primary" : "secondary"} onClick={() => setAbiMode("signatures")}>
                Signatures
              </Button>
              <Button variant={abiMode === "json" ? "primary" : "secondary"} onClick={() => setAbiMode("json")}>
                ABI JSON
              </Button>
              <label className="ml-auto flex items-center gap-2 text-sm text-text2">
                <input type="checkbox" checked={hashBytes32Labels} onChange={(e) => setHashBytes32Labels(e.target.checked)} />
                bytes32 plain text -&gt; keccak
              </label>
            </div>

            {abiMode === "json" ? (
              <Textarea value={abiJsonText} onChange={(e) => setAbiJsonText(e.target.value)} className="min-h-[220px] font-mono text-xs" />
            ) : (
              <Textarea value={abiText} onChange={(e) => setAbiText(e.target.value)} className="min-h-[220px] font-mono text-xs" />
            )}

            <div className="flex items-center gap-2">
              <Button onClick={loadAbi}>Load ABI</Button>
              {abi ? <Badge tone="good">Loaded ({functions.length} functions)</Badge> : <Badge tone="warn">Not loaded</Badge>}
            </div>

            <div className="rounded-xl border border-border/80 bg-muted/30 p-3">
              <div className="mb-2 text-xs text-text2">keccak ref builder</div>
              <div className="grid gap-2">
                <Input value={refLabel} onChange={(e) => setRefLabel(e.target.value)} placeholder="userRef label" />
                <Input value={refTs} onChange={(e) => setRefTs(e.target.value)} placeholder="timestamp (unix, uint64)" className="font-mono text-xs" />
                <Input
                  value={refCampaignId}
                  onChange={(e) => setRefCampaignId(e.target.value)}
                  placeholder="campaignId bytes32"
                  className="font-mono text-xs"
                />
                <Input value={builtRef} readOnly placeholder="keccak(userRef + timestamp + campaignId)" className="font-mono text-xs" />
                <div className="flex flex-wrap gap-2">
                  <Button size="sm" variant="secondary" disabled={!builtRef} onClick={() => builtRef && copyText("ref", builtRef)}>
                    Copy ref
                  </Button>
                  <Button
                    size="sm"
                    variant="secondary"
                    disabled={!builtRef || !focusedBytes32Path}
                    onClick={() => focusedBytes32Path && builtRef && updateArgAtPath(focusedBytes32Path, builtRef)}
                  >
                    Use in focused bytes32 arg
                  </Button>
                </div>
                {!builtRef && (refLabel.trim() || refTs.trim() || refCampaignId.trim()) ? (
                  <div className="text-xs text-bad">Ref requires label, uint64 timestamp, and campaignId as bytes32.</div>
                ) : null}
              </div>
            </div>

            {error ? <div className="rounded-xl border border-border bg-red-950/20 p-3 text-sm text-red-200">{error}</div> : null}
            {hint ? <div className="rounded-xl border border-border bg-emerald-950/20 p-3 text-sm text-emerald-200">{hint}</div> : null}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Call</CardTitle>
            <CardDescription>
              Select function by full signature (overloads safe). Inputs render recursively for tuples and arrays.
            </CardDescription>
          </CardHeader>
          <CardContent className="space-y-3">
            {!abi ? (
              <div className="text-sm text-text2">Load an ABI first.</div>
            ) : (
              <>
                <Input
                  value={functionQuery}
                  onChange={(e) => setFunctionQuery(e.target.value)}
                  placeholder="Filter functions by name/signature/mutability"
                />

                <div className="grid gap-2 md:grid-cols-4">
                  <div className="md:col-span-2">
                    <div className="mb-1 text-xs text-text2">Function signature</div>
                    <select
                      className="w-full rounded-xl border border-border bg-card px-3 py-2 text-xs font-mono"
                      value={selectedSignature}
                      onChange={(e) => {
                        setSelectedSignature(e.target.value);
                        setResult("");
                        setError("");
                        setHint("");
                        setCalldata("");
                      }}
                    >
                      {filteredFunctions.map((entry) => (
                        <option key={entry.signature} value={entry.signature}>
                          {entry.signature} [{entry.fn.stateMutability}]
                        </option>
                      ))}
                    </select>
                  </div>
                  <div className="flex flex-wrap items-end gap-2 md:col-span-2">
                    <Button onClick={buildCalldata} disabled={!selectedFunction}>
                      Build calldata
                    </Button>
                    <Button onClick={execute} disabled={!selectedFunction}>
                      {selectedFunction?.fn.stateMutability === "view" || selectedFunction?.fn.stateMutability === "pure"
                        ? "Read"
                        : "Write"}
                    </Button>
                    {calldata ? (
                      <Button variant="secondary" onClick={() => copyText("calldata", calldata)}>
                        Copy calldata
                      </Button>
                    ) : null}
                    {!isConnected &&
                    selectedFunction &&
                    !(selectedFunction.fn.stateMutability === "view" || selectedFunction.fn.stateMutability === "pure") ? (
                      <Badge tone="warn">Connect wallet</Badge>
                    ) : null}
                  </div>
                </div>

                {selectedFunction ? (
                  <div className="space-y-2">
                    {(selectedFunction.fn.inputs ?? []).length === 0 ? (
                      <div className="text-sm text-text2">No args.</div>
                    ) : (
                      (selectedFunction.fn.inputs ?? []).map((param, index) => (
                        <div key={`arg-${index}`}>{renderParamEditor(param, [index], index)}</div>
                      ))
                    )}
                  </div>
                ) : null}

                {calldata ? (
                  <div>
                    <div className="mb-1 text-xs text-text2">Calldata</div>
                    <Textarea value={calldata} readOnly className="min-h-[80px] font-mono text-xs" />
                  </div>
                ) : null}

                {result ? (
                  <div>
                    <div className="mb-1 text-xs text-text2">Result</div>
                    <Textarea value={result} readOnly className="min-h-[160px] font-mono text-xs" />
                  </div>
                ) : null}
              </>
            )}
          </CardContent>
        </Card>
      </div>

      <Card className="mt-4">
        <CardHeader>
          <CardTitle>Local History</CardTitle>
          <CardDescription>Latest invocations in browser localStorage. Includes calldata and tx hash when available.</CardDescription>
        </CardHeader>
        <CardContent className="space-y-3">
          <div className="flex flex-wrap items-center gap-2">
            <Badge tone="good">{history.length} entries</Badge>
            <Button size="sm" variant="ghost" onClick={() => setHistory([])} disabled={history.length === 0}>
              Clear history
            </Button>
          </div>
          {history.length === 0 ? (
            <div className="text-sm text-text2">No calls yet.</div>
          ) : (
            <div className="space-y-2">
              {history.map((entry) => (
                <div key={entry.id} className="rounded-xl border border-border/80 bg-card p-3">
                  <div className="flex flex-wrap items-center justify-between gap-2">
                    <div className="text-xs text-text2">
                      {new Date(entry.at).toLocaleString()} - <span className="font-medium text-text">{entry.mode.toUpperCase()}</span> - {entry.abiName}
                    </div>
                    <div className="flex flex-wrap items-center gap-2">
                      <Button size="sm" variant="secondary" onClick={() => copyText("calldata", entry.calldata)}>
                        Copy calldata
                      </Button>
                      <Button size="sm" variant="ghost" onClick={() => copyText("args", entry.argsJson)}>
                        Copy args
                      </Button>
                      {entry.txHash ? (
                        <>
                          <Button size="sm" variant="ghost" onClick={() => copyText("tx hash", entry.txHash!)}>
                            Copy tx
                          </Button>
                          <a
                            className="text-xs text-primary underline"
                            href={explorerTxUrl(entry.chainId, entry.txHash)}
                            target="_blank"
                            rel="noreferrer"
                          >
                            Explorer
                          </a>
                        </>
                      ) : null}
                    </div>
                  </div>
                  <div className="mt-2 text-xs text-text2">
                    <div className="break-all font-mono">{entry.functionSignature}</div>
                    <div className="mt-1 break-all font-mono">target: {entry.address}</div>
                  </div>
                  {entry.error ? <div className="mt-2 rounded-lg border border-bad/40 bg-bad/10 p-2 text-xs text-bad">{entry.error}</div> : null}
                  {entry.resultJson ? (
                    <details className="mt-2 rounded-lg border border-border/60 bg-muted/40 p-2">
                      <summary className="cursor-pointer text-xs text-text2">View result</summary>
                      <pre className="mt-2 whitespace-pre-wrap break-all font-mono text-xs text-text">{entry.resultJson}</pre>
                    </details>
                  ) : null}
                </div>
              ))}
            </div>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
