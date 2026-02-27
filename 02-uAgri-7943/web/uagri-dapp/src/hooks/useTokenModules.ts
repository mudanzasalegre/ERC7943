"use client";

import { useQuery } from "@tanstack/react-query";
import { usePublicClient } from "wagmi";
import { shareTokenAbi } from "@/lib/abi";

export type TokenModules = {
  compliance: `0x${string}`;
  disaster: `0x${string}`;
  freeze: `0x${string}`;
  custody: `0x${string}`;
  trace: `0x${string}`;
  documentRegistry: `0x${string}`;
  settlementQueue: `0x${string}`;
  treasury: `0x${string}`;
  distribution: `0x${string}`;
  bridge: `0x${string}`;
  marketplace: `0x${string}`;
  delivery: `0x${string}`;
  insurance: `0x${string}`;
};

export function useTokenModules(token?: `0x${string}`) {
  const client = usePublicClient();

  return useQuery({
    queryKey: ["tokenModules", token],
    enabled: !!client && !!token,
    queryFn: async (): Promise<TokenModules> => {
      if (!token) throw new Error("token missing");
      if (!client) throw new Error("client missing");
      const [
        compliance,
        disaster,
        freeze,
        custody,
        trace,
        documentRegistry,
        settlementQueue,
        treasury,
        distribution,
        bridge,
        marketplace,
        delivery,
        insurance
      ] = await Promise.all([
        client.readContract({ address: token, abi: shareTokenAbi, functionName: "complianceModule" }) as Promise<`0x${string}`>,
        client.readContract({ address: token, abi: shareTokenAbi, functionName: "disasterModule" }) as Promise<`0x${string}`>,
        client.readContract({ address: token, abi: shareTokenAbi, functionName: "freezeModule" }) as Promise<`0x${string}`>,
        client.readContract({ address: token, abi: shareTokenAbi, functionName: "custodyModule" }) as Promise<`0x${string}`>,
        client.readContract({ address: token, abi: shareTokenAbi, functionName: "traceModule" }) as Promise<`0x${string}`>,
        client.readContract({ address: token, abi: shareTokenAbi, functionName: "documentRegistry" }) as Promise<`0x${string}`>,
        client.readContract({ address: token, abi: shareTokenAbi, functionName: "settlementQueue" }) as Promise<`0x${string}`>,
        client.readContract({ address: token, abi: shareTokenAbi, functionName: "treasury" }) as Promise<`0x${string}`>,
        client.readContract({ address: token, abi: shareTokenAbi, functionName: "distribution" }) as Promise<`0x${string}`>,
        client.readContract({ address: token, abi: shareTokenAbi, functionName: "bridgeModule" }) as Promise<`0x${string}`>,
        client.readContract({ address: token, abi: shareTokenAbi, functionName: "marketplaceModule" }) as Promise<`0x${string}`>,
        client.readContract({ address: token, abi: shareTokenAbi, functionName: "deliveryModule" }) as Promise<`0x${string}`>,
        client.readContract({ address: token, abi: shareTokenAbi, functionName: "insuranceModule" }) as Promise<`0x${string}`>
      ]);

      return { compliance, disaster, freeze, custody, trace, documentRegistry, settlementQueue, treasury, distribution, bridge, marketplace, delivery, insurance };
    }
  });
}
