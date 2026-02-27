import { keccak256, stringToHex } from "viem";

export const ZERO_BYTES32 = (`0x${"00".repeat(32)}`) as `0x${string}`;
const BYTES32_RE = /^0x[0-9a-fA-F]{64}$/u;

export function isBytes32(value: string): value is `0x${string}` {
  return BYTES32_RE.test(String(value ?? "").trim());
}

export function bytes32FromText(value: string): `0x${string}` | undefined {
  try {
    const out = stringToHex(String(value ?? ""), { size: 32 });
    return out as `0x${string}`;
  } catch {
    return undefined;
  }
}

export function keccakBytes32(value: string): `0x${string}` {
  return keccak256(stringToHex(String(value ?? "")));
}

