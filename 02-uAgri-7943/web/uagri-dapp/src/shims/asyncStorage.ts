/**
 * Web-safe shim for `@react-native-async-storage/async-storage`.
 *
 * Why: MetaMask SDK (pulled transitively by wagmi/rainbowkit export paths)
 * references RN AsyncStorage even in web bundles. Next/Webpack tries to resolve
 * the module and fails. We alias that import to this file via next.config.mjs.
 *
 * This shim implements a minimal AsyncStorage-like API using localStorage when
 * available, otherwise an in-memory Map.
 */

type KV = Map<string, string>;

const memory: KV = new Map();

function hasLocalStorage(): boolean {
  try {
    return typeof window !== "undefined" && !!window.localStorage;
  } catch {
    return false;
  }
}

function lsGet(key: string): string | null {
  if (!hasLocalStorage()) return memory.get(key) ?? null;
  const v = window.localStorage.getItem(key);
  return v === null ? null : v;
}

function lsSet(key: string, value: string): void {
  if (!hasLocalStorage()) {
    memory.set(key, value);
    return;
  }
  window.localStorage.setItem(key, value);
}

function lsRemove(key: string): void {
  if (!hasLocalStorage()) {
    memory.delete(key);
    return;
  }
  window.localStorage.removeItem(key);
}

function lsClear(): void {
  if (!hasLocalStorage()) {
    memory.clear();
    return;
  }
  window.localStorage.clear();
}

function lsKeys(): string[] {
  if (!hasLocalStorage()) return Array.from(memory.keys());
  const keys: string[] = [];
  for (let i = 0; i < window.localStorage.length; i++) {
    const k = window.localStorage.key(i);
    if (k) keys.push(k);
  }
  return keys;
}

async function mergeJson(existing: string | null, incoming: string): Promise<string> {
  try {
    const a = existing ? JSON.parse(existing) : {};
    const b = JSON.parse(incoming);
    return JSON.stringify({ ...a, ...b });
  } catch {
    // If not JSON, fallback to overwrite.
    return incoming;
  }
}

const AsyncStorage = {
  async getItem(key: string): Promise<string | null> {
    return lsGet(key);
  },
  async setItem(key: string, value: string): Promise<void> {
    lsSet(key, value);
  },
  async removeItem(key: string): Promise<void> {
    lsRemove(key);
  },
  async clear(): Promise<void> {
    lsClear();
  },
  async getAllKeys(): Promise<string[]> {
    return lsKeys();
  },
  async multiGet(keys: string[]): Promise<[string, string | null][]> {
    return keys.map((k) => [k, lsGet(k)]);
  },
  async multiSet(pairs: [string, string][]): Promise<void> {
    for (const [k, v] of pairs) lsSet(k, v);
  },
  async multiRemove(keys: string[]): Promise<void> {
    for (const k of keys) lsRemove(k);
  },
  async mergeItem(key: string, value: string): Promise<void> {
    const existing = lsGet(key);
    const merged = await mergeJson(existing, value);
    lsSet(key, merged);
  },
  async multiMerge(pairs: [string, string][]): Promise<void> {
    for (const [k, v] of pairs) {
      const existing = lsGet(k);
      const merged = await mergeJson(existing, v);
      lsSet(k, merged);
    }
  }
};

export default AsyncStorage;
export { AsyncStorage };
