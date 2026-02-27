import { decodeEventLog } from "viem";

export async function getLogsChunked(args: {
  // `usePublicClient()` can carry slightly different TS identities across deps;
  // keep this helper client-agnostic.
  client: {
    getLogs: (params: any) => Promise<any[]>;
  };
  fromBlock: bigint;
  toBlock: bigint;
  maxChunk: bigint;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  params: any;
}) {
  const { client, fromBlock, toBlock, maxChunk, params } = args;

  const logs = [];
  let start = fromBlock;
  while (start <= toBlock) {
    const end = start + maxChunk - 1n <= toBlock ? start + maxChunk - 1n : toBlock;
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const part = await client.getLogs({ ...params, fromBlock: start, toBlock: end } as any);
    if (params?.abi && params?.eventName) {
      const decoded = part.map((log: any) => {
        try {
          const parsed = decodeEventLog({
            abi: params.abi,
            eventName: params.eventName,
            data: log.data,
            topics: log.topics
          });
          return { ...log, args: parsed.args, eventName: parsed.eventName };
        } catch {
          return log;
        }
      });
      logs.push(...decoded);
    } else {
      logs.push(...part);
    }
    start = end + 1n;
  }
  return logs;
}

export function uniq<T>(arr: T[]): T[] {
  return Array.from(new Set(arr));
}
