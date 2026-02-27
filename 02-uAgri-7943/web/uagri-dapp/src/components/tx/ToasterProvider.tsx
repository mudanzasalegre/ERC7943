"use client";

import * as React from "react";
import * as Toast from "@radix-ui/react-toast";
import { Copy, ExternalLink, RotateCcw } from "lucide-react";
import TxModal from "./TxModal";
import { cn } from "@/lib/cn";
import { explorerTxUrl } from "@/lib/explorer";

export type TxStage = "pending" | "success" | "error";
export type TxPendingPhase = "wallet" | "chain";

export type TxEntry = {
  id: string;
  stage: TxStage;
  pendingPhase?: TxPendingPhase;
  title: string;
  hash?: `0x${string}`;
  chainId?: number;
  error?: string;
  createdAt: number;
  updatedAt: number;
  attempts: number;
  retryOfTxId?: string;
  address?: string;
  functionName?: string;
};

type ToastTone = "good" | "bad" | "warn";

type ToastMessage = {
  id: string;
  title: string;
  description?: string;
  tone?: ToastTone;
  txId?: string;
};

type Ctx = {
  txs: TxEntry[];
  activeTxId?: string;
  activeTx?: TxEntry;

  createTx: (input: {
    title: string;
    chainId?: number;
    stage?: TxStage;
    pendingPhase?: TxPendingPhase;
    hash?: `0x${string}`;
    attempts?: number;
    retryOfTxId?: string;
    address?: string;
    functionName?: string;
  }) => string;
  updateTx: (id: string, patch: Partial<TxEntry>) => void;
  completeTxSuccess: (id: string, patch?: Partial<TxEntry>) => void;
  completeTxError: (id: string, error: string, patch?: Partial<TxEntry>) => void;

  notify: (msg: { title: string; description?: string; tone?: ToastTone; txId?: string }) => void;

  openTxModal: (txId?: string) => void;
  closeTxModal: () => void;

  registerRetry: (txId: string, fn: () => Promise<void>) => void;
  canRetry: (txId?: string) => boolean;
  retryTx: (txId: string) => Promise<void>;
};

const TxContext = React.createContext<Ctx | null>(null);

const STORAGE_KEY = "uagri.txcenter.v1";
const MAX_TXS = 60;

function txId() {
  return `${Date.now()}-${Math.random().toString(16).slice(2, 10)}`;
}

export function useToaster() {
  const ctx = React.useContext(TxContext);
  if (!ctx) throw new Error("useToaster must be used within ToasterProvider");
  return ctx;
}

export function ToasterProvider({ children }: { children: React.ReactNode }) {
  const [txs, setTxs] = React.useState<TxEntry[]>([]);
  const [activeTxId, setActiveTxId] = React.useState<string | undefined>(undefined);
  const [txModalOpen, setTxModalOpen] = React.useState(false);

  const [toastOpen, setToastOpen] = React.useState(false);
  const [toastMsg, setToastMsg] = React.useState<ToastMessage | null>(null);

  const retryHandlers = React.useRef<Record<string, () => Promise<void>>>({});
  const txsRef = React.useRef<TxEntry[]>([]);

  React.useEffect(() => {
    txsRef.current = txs;
  }, [txs]);

  React.useEffect(() => {
    if (typeof window === "undefined") return;
    try {
      const raw = window.localStorage.getItem(STORAGE_KEY);
      if (!raw) return;
      const parsed = JSON.parse(raw) as TxEntry[];
      if (!Array.isArray(parsed)) return;
      setTxs(parsed.slice(0, MAX_TXS));
    } catch {
      // ignore storage parse errors
    }
  }, []);

  React.useEffect(() => {
    if (typeof window === "undefined") return;
    try {
      window.localStorage.setItem(STORAGE_KEY, JSON.stringify(txs.slice(0, MAX_TXS)));
    } catch {
      // ignore quota/storage errors
    }
  }, [txs]);

  const setAndPrune = React.useCallback((updater: (prev: TxEntry[]) => TxEntry[]) => {
    setTxs((prev) => {
      const next = updater(prev).slice(0, MAX_TXS);
      const keep = new Set(next.map((x) => x.id));
      for (const key of Object.keys(retryHandlers.current)) {
        if (!keep.has(key)) delete retryHandlers.current[key];
      }
      return next;
    });
  }, []);

  const createTx = React.useCallback(
    (input: {
      title: string;
      chainId?: number;
      stage?: TxStage;
      pendingPhase?: TxPendingPhase;
      hash?: `0x${string}`;
      attempts?: number;
      retryOfTxId?: string;
      address?: string;
      functionName?: string;
    }) => {
      const id = txId();
      const now = Date.now();
      const entry: TxEntry = {
        id,
        title: input.title,
        chainId: input.chainId,
        stage: input.stage ?? "pending",
        pendingPhase: input.pendingPhase ?? "wallet",
        hash: input.hash,
        attempts: input.attempts ?? 1,
        retryOfTxId: input.retryOfTxId,
        address: input.address,
        functionName: input.functionName,
        createdAt: now,
        updatedAt: now
      };

      setAndPrune((prev) => [entry, ...prev]);
      return id;
    },
    [setAndPrune]
  );

  const updateTx = React.useCallback(
    (id: string, patch: Partial<TxEntry>) => {
      setAndPrune((prev) =>
        prev.map((tx) => (tx.id === id ? { ...tx, ...patch, updatedAt: Date.now() } : tx))
      );
    },
    [setAndPrune]
  );

  const completeTxSuccess = React.useCallback(
    (id: string, patch?: Partial<TxEntry>) => {
      updateTx(id, { ...patch, stage: "success", pendingPhase: undefined, error: undefined });
    },
    [updateTx]
  );

  const completeTxError = React.useCallback(
    (id: string, error: string, patch?: Partial<TxEntry>) => {
      updateTx(id, { ...patch, stage: "error", pendingPhase: undefined, error });
    },
    [updateTx]
  );

  const notify = React.useCallback((msg: { title: string; description?: string; tone?: ToastTone; txId?: string }) => {
    setToastMsg({ id: txId(), ...msg });
    setToastOpen(true);
  }, []);

  const openTxModal = React.useCallback((id?: string) => {
    const target = id ?? txsRef.current[0]?.id;
    if (!target) return;
    setActiveTxId(target);
    setTxModalOpen(true);
  }, []);

  const closeTxModal = React.useCallback(() => setTxModalOpen(false), []);

  const registerRetry = React.useCallback((txId: string, fn: () => Promise<void>) => {
    retryHandlers.current[txId] = fn;
  }, []);

  const canRetry = React.useCallback((id?: string) => {
    if (!id) return false;
    return Boolean(retryHandlers.current[id]);
  }, []);

  const retryTx = React.useCallback(async (id: string) => {
    const fn = retryHandlers.current[id];
    if (!fn) return;
    await fn();
  }, []);

  const activeTx = React.useMemo(() => txs.find((tx) => tx.id === activeTxId), [txs, activeTxId]);
  const toastTx = React.useMemo(() => {
    if (!toastMsg?.txId) return undefined;
    return txs.find((tx) => tx.id === toastMsg.txId);
  }, [toastMsg?.txId, txs]);

  const toneClass =
    toastMsg?.tone === "good"
      ? "border-good/30"
      : toastMsg?.tone === "bad"
      ? "border-bad/30"
      : toastMsg?.tone === "warn"
      ? "border-warn/30"
      : "border-border";

  return (
    <TxContext.Provider
      value={{
        txs,
        activeTxId,
        activeTx,
        createTx,
        updateTx,
        completeTxSuccess,
        completeTxError,
        notify,
        openTxModal,
        closeTxModal,
        registerRetry,
        canRetry,
        retryTx
      }}
    >
      <Toast.Provider swipeDirection="right">
        {children}

        <TxModal open={txModalOpen} onOpenChange={setTxModalOpen} />

        <Toast.Root
          key={toastMsg?.id ?? "toast"}
          className={cn(
            "fixed bottom-20 right-4 z-[60] w-[360px] max-w-[calc(100vw-2rem)] rounded-xl border bg-card p-4 shadow-soft outline-none",
            toneClass
          )}
          open={toastOpen}
          onOpenChange={setToastOpen}
        >
          <Toast.Title className="text-sm font-semibold">{toastMsg?.title ?? "Notification"}</Toast.Title>
          {toastMsg?.description ? (
            <Toast.Description className="mt-1 text-sm text-text2">{toastMsg.description}</Toast.Description>
          ) : null}

          {toastTx ? (
            <div className="mt-3 flex flex-wrap items-center gap-2">
              {toastTx.hash ? (
                <button
                  className="inline-flex items-center gap-1 rounded-lg border border-border px-2 py-1 text-xs text-text2 hover:bg-muted"
                  onClick={async () => navigator.clipboard.writeText(toastTx.hash!)}
                  title="Copy hash"
                >
                  <Copy size={14} /> Copy
                </button>
              ) : null}

              {toastTx.hash && toastTx.chainId ? (
                <a
                  className="inline-flex items-center gap-1 rounded-lg border border-border px-2 py-1 text-xs text-text2 hover:bg-muted"
                  href={explorerTxUrl(toastTx.chainId, toastTx.hash)}
                  target="_blank"
                  rel="noreferrer"
                >
                  <ExternalLink size={14} /> Explorer
                </a>
              ) : null}

              {toastTx.stage === "error" && canRetry(toastTx.id) ? (
                <button
                  className="inline-flex items-center gap-1 rounded-lg border border-border px-2 py-1 text-xs text-text2 hover:bg-muted"
                  onClick={() => retryTx(toastTx.id)}
                >
                  <RotateCcw size={14} /> Retry
                </button>
              ) : null}

              <button
                className="ml-auto inline-flex items-center gap-1 rounded-lg border border-border px-2 py-1 text-xs text-text2 hover:bg-muted"
                onClick={() => openTxModal(toastTx.id)}
              >
                Details
              </button>
            </div>
          ) : null}
        </Toast.Root>

        <Toast.Viewport className="fixed bottom-0 right-0 z-[60] p-4" />
      </Toast.Provider>
    </TxContext.Provider>
  );
}
