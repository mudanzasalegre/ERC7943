import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  createPublicClient,
  decodeEventLog,
  getAddress,
  http,
  isAddress,
  zeroAddress
} from "viem";
import { base, baseSepolia } from "viem/chains";

const LOOKBACK_DEFAULT = 200_000n;

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const webRoot = path.resolve(__dirname, "..");

function readJson(relPath) {
  const fullPath = path.join(webRoot, relPath);
  return JSON.parse(fs.readFileSync(fullPath, "utf8"));
}

function parseDotEnv(filePath) {
  const out = {};
  if (!fs.existsSync(filePath)) return out;

  const text = fs.readFileSync(filePath, "utf8");
  for (const rawLine of text.split(/\r?\n/u)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    const idx = line.indexOf("=");
    if (idx <= 0) continue;
    const key = line.slice(0, idx).trim();
    if (!key) continue;
    let value = line.slice(idx + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    out[key] = value;
  }
  return out;
}

function normalizeAddress(value) {
  const raw = String(value ?? "").trim();
  if (!raw) return undefined;
  if (!isAddress(raw)) return undefined;
  return getAddress(raw);
}

function parseBigIntOrUndefined(value) {
  const raw = String(value ?? "").trim();
  if (!raw) return undefined;
  try {
    return BigInt(raw);
  } catch {
    return undefined;
  }
}

function pickAddress(env, keys) {
  for (const key of keys) {
    const addr = normalizeAddress(env[key]);
    if (addr) return addr;
  }
  return undefined;
}

function isLiveAddress(addr) {
  return Boolean(addr && addr !== zeroAddress);
}

function short(addr) {
  if (!addr) return "-";
  return `${addr.slice(0, 6)}...${addr.slice(-4)}`;
}

function decodeCampaignDeployed(rawLogs, eventAbi) {
  const out = [];
  for (const log of rawLogs) {
    try {
      const decoded = decodeEventLog({
        abi: [eventAbi],
        data: log.data,
        topics: log.topics
      });
      out.push({
        campaignId: decoded.args.campaignId,
        roleManager: decoded.args.roleManager,
        shareToken: decoded.args.shareToken,
        registry: decoded.args.registry,
        treasury: decoded.args.treasury,
        fundingManager: decoded.args.fundingManager,
        settlementQueue: decoded.args.settlementQueue,
        blockNumber: log.blockNumber ?? 0n,
        txHash: log.transactionHash
      });
    } catch {
      // Ignore non-matching events in same contract.
    }
  }
  return out;
}

function decodeCampaignCreated(rawLogs, eventAbi) {
  const out = [];
  for (const log of rawLogs) {
    try {
      const decoded = decodeEventLog({
        abi: [eventAbi],
        data: log.data,
        topics: log.topics
      });
      out.push({
        campaignId: decoded.args.campaignId,
        plotRef: decoded.args.plotRef,
        settlementAsset: decoded.args.settlementAsset,
        blockNumber: log.blockNumber ?? 0n,
        txHash: log.transactionHash
      });
    } catch {
      // Ignore non-matching events in same contract.
    }
  }
  return out;
}

async function main() {
  const dotEnv = parseDotEnv(path.join(webRoot, ".env.local"));
  const env = { ...dotEnv, ...process.env };
  const verifyChainRaw = String(env.VERIFY_CHAIN ?? "base-sepolia").trim().toLowerCase();
  const isBaseMainnet =
    verifyChainRaw === "base" ||
    verifyChainRaw === "base-mainnet" ||
    verifyChainRaw === "mainnet" ||
    verifyChainRaw === "8453";
  const chain = isBaseMainnet ? base : baseSepolia;

  const rpcUrl = String(
    env[isBaseMainnet ? "NEXT_PUBLIC_BASE_RPC_URL" : "NEXT_PUBLIC_BASE_SEPOLIA_RPC_URL"] ??
      (isBaseMainnet ? "https://mainnet.base.org" : "https://sepolia.base.org")
  ).trim();

  const factory = pickAddress(env, [
    isBaseMainnet ? "NEXT_PUBLIC_BASE_MAINNET_CAMPAIGN_FACTORY" : "NEXT_PUBLIC_BASE_SEPOLIA_CAMPAIGN_FACTORY",
    "NEXT_PUBLIC_CAMPAIGN_FACTORY"
  ]);
  const registryFallback = pickAddress(env, [
    isBaseMainnet ? "NEXT_PUBLIC_BASE_MAINNET_CAMPAIGN_REGISTRY" : "NEXT_PUBLIC_BASE_SEPOLIA_CAMPAIGN_REGISTRY",
    "NEXT_PUBLIC_CAMPAIGN_REGISTRY"
  ]);
  const roleManagerFallback = pickAddress(env, [
    isBaseMainnet ? "NEXT_PUBLIC_BASE_MAINNET_ROLE_MANAGER" : "NEXT_PUBLIC_BASE_SEPOLIA_ROLE_MANAGER",
    "NEXT_PUBLIC_ROLE_MANAGER"
  ]);

  if (!factory && !registryFallback) {
    throw new Error(
      "No campaign factory/registry configured in env (.env.local or process env)."
    );
  }

  const campaignFactoryAbi = readJson("src/abis/contracts/CampaignFactory.abi.json");
  const campaignRegistryAbi = readJson("src/abis/contracts/AgriCampaignRegistry.abi.json");
  const shareTokenAbi = readJson("src/abis/contracts/AgriShareToken.abi.json");
  const factoryEventAbi = campaignFactoryAbi.find(
    (x) => x.type === "event" && x.name === "CampaignDeployed"
  );
  const registryEventAbi = campaignRegistryAbi.find(
    (x) => x.type === "event" && x.name === "CampaignCreated"
  );

  if (!factoryEventAbi || !registryEventAbi) {
    throw new Error("Required ABI events not found (CampaignDeployed/CampaignCreated).");
  }

  const client = createPublicClient({
    chain,
    transport: http(rpcUrl)
  });

  const head = await client.getBlockNumber();
  const fromBlockEnv = parseBigIntOrUndefined(env.NEXT_PUBLIC_DISCOVERY_FROM_BLOCK);
  const fromBlock =
    typeof fromBlockEnv === "bigint"
      ? fromBlockEnv
      : head > LOOKBACK_DEFAULT
        ? head - LOOKBACK_DEFAULT
        : 0n;

  const codeCache = new Map();
  async function hasCode(address) {
    if (!isLiveAddress(address)) return false;
    const key = address.toLowerCase();
    if (codeCache.has(key)) return codeCache.get(key);
    const bytecode = await client.getBytecode({ address });
    const ok = Boolean(bytecode && bytecode !== "0x");
    codeCache.set(key, ok);
    return ok;
  }

  const campaignMap = new Map();

  if (factory) {
    const rawFactoryLogs = await client.getLogs({
      address: factory,
      fromBlock,
      toBlock: head
    });
    const deployed = decodeCampaignDeployed(rawFactoryLogs, factoryEventAbi);
    for (const event of deployed) {
      campaignMap.set(event.campaignId, { ...campaignMap.get(event.campaignId), deployed: event });
    }
  }

  if (registryFallback) {
    const rawRegistryLogs = await client.getLogs({
      address: registryFallback,
      fromBlock,
      toBlock: head
    });
    const created = decodeCampaignCreated(rawRegistryLogs, registryEventAbi);
    for (const event of created) {
      campaignMap.set(event.campaignId, { ...campaignMap.get(event.campaignId), created: event });
    }
  }

  const campaignIds = [...campaignMap.keys()];
  if (campaignIds.length === 0) {
    throw new Error(
      `No campaigns discovered between blocks ${fromBlock} and ${head} for configured factory/registry.`
    );
  }

  campaignIds.sort((a, b) => (a.toLowerCase() > b.toLowerCase() ? 1 : -1));

  console.log(`verify:onchain wiring`);
  console.log(`chain: ${chain.name} (${chain.id})`);
  console.log(`rpc: ${rpcUrl}`);
  console.log(`factory: ${factory ?? "-"}`);
  console.log(`registry fallback: ${registryFallback ?? "-"}`);
  console.log(`roleManager fallback: ${roleManagerFallback ?? "-"}`);
  console.log(`fromBlock: ${fromBlock}`);
  console.log(`head: ${head}`);
  console.log(`campaigns discovered: ${campaignIds.length}`);

  let fatalCount = 0;
  let warningCount = 0;

  for (const campaignId of campaignIds) {
    const row = campaignMap.get(campaignId) ?? {};
    const issues = [];
    const warnings = [];

    let stack;
    if (factory) {
      try {
        stack = await client.readContract({
          address: factory,
          abi: campaignFactoryAbi,
          functionName: "stacks",
          args: [campaignId]
        });
      } catch (error) {
        warnings.push(`factory.stacks read failed: ${error?.shortMessage ?? error?.message ?? "unknown error"}`);
      }
    }

    const registryAddr = normalizeAddress(
      stack?.registry ?? row?.deployed?.registry ?? registryFallback
    );
    const shareTokenAddr = normalizeAddress(
      stack?.shareToken ?? row?.deployed?.shareToken
    );
    const roleManagerAddr = normalizeAddress(
      stack?.roleManager ?? row?.deployed?.roleManager ?? roleManagerFallback
    );

    if (!registryAddr) {
      issues.push("registry unresolved");
    } else if (!(await hasCode(registryAddr))) {
      issues.push(`registry has no bytecode: ${registryAddr}`);
    }

    let campaignState;
    if (registryAddr) {
      try {
        campaignState = await client.readContract({
          address: registryAddr,
          abi: campaignRegistryAbi,
          functionName: "getCampaign",
          args: [campaignId]
        });
      } catch (error) {
        issues.push(`registry.getCampaign failed: ${error?.shortMessage ?? error?.message ?? "unknown error"}`);
      }
    }

    if (!shareTokenAddr) {
      issues.push("shareToken unresolved");
    } else if (!(await hasCode(shareTokenAddr))) {
      issues.push(`shareToken has no bytecode: ${shareTokenAddr}`);
    }

    let tokenName = "-";
    let tokenSymbol = "-";
    let tokenDecimals = "-";

    if (shareTokenAddr && (await hasCode(shareTokenAddr))) {
      try {
        const [name, symbol, decimals] = await Promise.all([
          client.readContract({
            address: shareTokenAddr,
            abi: shareTokenAbi,
            functionName: "name"
          }),
          client.readContract({
            address: shareTokenAddr,
            abi: shareTokenAbi,
            functionName: "symbol"
          }),
          client.readContract({
            address: shareTokenAddr,
            abi: shareTokenAbi,
            functionName: "decimals"
          })
        ]);
        tokenName = String(name);
        tokenSymbol = String(symbol);
        tokenDecimals = String(decimals);
      } catch (error) {
        issues.push(`shareToken metadata read failed: ${error?.shortMessage ?? error?.message ?? "unknown error"}`);
      }
    }

    let modules = null;
    if (shareTokenAddr && (await hasCode(shareTokenAddr))) {
      try {
        const [
          settlementQueue,
          treasury,
          distribution,
          compliance,
          freeze,
          disaster,
          trace,
          documentRegistry
        ] = await Promise.all([
          client.readContract({
            address: shareTokenAddr,
            abi: shareTokenAbi,
            functionName: "settlementQueue"
          }),
          client.readContract({
            address: shareTokenAddr,
            abi: shareTokenAbi,
            functionName: "treasury"
          }),
          client.readContract({
            address: shareTokenAddr,
            abi: shareTokenAbi,
            functionName: "distribution"
          }),
          client.readContract({
            address: shareTokenAddr,
            abi: shareTokenAbi,
            functionName: "complianceModule"
          }),
          client.readContract({
            address: shareTokenAddr,
            abi: shareTokenAbi,
            functionName: "freezeModule"
          }),
          client.readContract({
            address: shareTokenAddr,
            abi: shareTokenAbi,
            functionName: "disasterModule"
          }),
          client.readContract({
            address: shareTokenAddr,
            abi: shareTokenAbi,
            functionName: "traceModule"
          }),
          client.readContract({
            address: shareTokenAddr,
            abi: shareTokenAbi,
            functionName: "documentRegistry"
          })
        ]);

        modules = {
          settlementQueue: normalizeAddress(settlementQueue),
          treasury: normalizeAddress(treasury),
          distribution: normalizeAddress(distribution),
          compliance: normalizeAddress(compliance),
          freeze: normalizeAddress(freeze),
          disaster: normalizeAddress(disaster),
          trace: normalizeAddress(trace),
          documentRegistry: normalizeAddress(documentRegistry)
        };
      } catch (error) {
        issues.push(`shareToken module views failed: ${error?.shortMessage ?? error?.message ?? "unknown error"}`);
      }
    }

    const requiredModules = [
      ["settlementQueue", modules?.settlementQueue],
      ["treasury", modules?.treasury],
      ["compliance", modules?.compliance],
      ["freeze", modules?.freeze],
      ["disaster", modules?.disaster]
    ];

    for (const [label, address] of requiredModules) {
      if (!isLiveAddress(address)) {
        issues.push(`${label} is zero/unset`);
        continue;
      }
      if (!(await hasCode(address))) {
        issues.push(`${label} has no bytecode: ${address}`);
      }
    }

    const optionalModules = [
      ["distribution", modules?.distribution],
      ["trace", modules?.trace],
      ["documentRegistry", modules?.documentRegistry]
    ];
    for (const [label, address] of optionalModules) {
      if (!isLiveAddress(address)) {
        warnings.push(`${label} is zero/unset`);
        continue;
      }
      if (!(await hasCode(address))) {
        warnings.push(`${label} has no bytecode: ${address}`);
      }
    }

    if (!campaignState) {
      issues.push("campaign state not readable from registry");
    }

    console.log("");
    console.log(`campaign: ${campaignId}`);
    console.log(`  roleManager: ${roleManagerAddr ?? "-"}`);
    console.log(`  registry: ${registryAddr ?? "-"}`);
    console.log(`  shareToken: ${shareTokenAddr ?? "-"}`);
    console.log(`  tokenMeta: ${tokenSymbol}/${tokenName} (decimals=${tokenDecimals})`);
    if (modules) {
      console.log(
        `  modules: queue=${short(modules.settlementQueue)} treasury=${short(modules.treasury)} distribution=${short(modules.distribution)} compliance=${short(modules.compliance)} freeze=${short(modules.freeze)} disaster=${short(modules.disaster)} trace=${short(modules.trace)} docs=${short(modules.documentRegistry)}`
      );
    } else {
      console.log(`  modules: -`);
    }

    if (issues.length > 0) {
      fatalCount += issues.length;
      for (const issue of issues) {
        console.log(`  [ERROR] ${issue}`);
      }
    } else {
      console.log("  [OK] core contract reads and module wiring");
    }

    if (warnings.length > 0) {
      warningCount += warnings.length;
      for (const warning of warnings) {
        console.log(`  [WARN] ${warning}`);
      }
    }
  }

  console.log("");
  console.log(`summary: errors=${fatalCount}, warnings=${warningCount}`);
  if (fatalCount > 0) {
    process.exitCode = 1;
    return;
  }
  console.log("verify:onchain passed");
}

main().catch((error) => {
  console.error(`verify:onchain failed: ${error?.message ?? error}`);
  process.exitCode = 1;
});
