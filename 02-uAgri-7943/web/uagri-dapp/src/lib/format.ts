export function shortAddr(a?: string, chars = 4) {
  if (!a) return "";
  return `${a.slice(0, 2 + chars)}…${a.slice(-chars)}`;
}

export function shortHex32(v?: string) {
  if (!v) return "";
  return `${v.slice(0, 10)}…${v.slice(-6)}`;
}

export function formatUnitsSafe(value: bigint, decimals = 18, precision = 4) {
  const s = (Number(value) / 10 ** decimals).toString();
  const [i, d] = s.split(".");
  if (!d) return i;
  return `${i}.${d.slice(0, precision)}`;
}
