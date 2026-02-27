import { base, baseSepolia } from "wagmi/chains";

export function explorerBaseUrl(chainId: number): string {
  if (chainId === base.id) return "https://basescan.org";
  if (chainId === baseSepolia.id) return "https://sepolia.basescan.org";
  return "https://basescan.org";
}

export function explorerTxUrl(chainId: number, hash: `0x${string}`): string {
  return `${explorerBaseUrl(chainId)}/tx/${hash}`;
}

export function explorerAddressUrl(chainId: number, address: `0x${string}`): string {
  return `${explorerBaseUrl(chainId)}/address/${address}`;
}
