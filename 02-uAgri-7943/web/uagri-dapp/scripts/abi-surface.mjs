import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = path.resolve(SCRIPT_DIR, "..");
const ABI_ROOT = path.join(PROJECT_ROOT, "src", "abis");
const MANIFEST_PATH = path.join(ABI_ROOT, "manifest.json");
const OUTPUT_DIR = path.join(PROJECT_ROOT, "docs", "abi");
const OUTPUT_PATH = path.join(OUTPUT_DIR, "abi-surface.json");

function readJson(filePath) {
  if (!fs.existsSync(filePath)) {
    throw new Error(`Missing file: ${filePath}`);
  }
  try {
    return JSON.parse(fs.readFileSync(filePath, "utf8"));
  } catch (error) {
    throw new Error(`Invalid JSON at ${filePath}: ${error.message}`);
  }
}

function canonicalType(param) {
  const rawType = typeof param?.type === "string" ? param.type : "";
  if (!rawType.startsWith("tuple")) {
    return rawType;
  }

  const suffix = rawType.slice("tuple".length);
  const components = Array.isArray(param?.components) ? param.components : [];
  const inner = components.map((component) => canonicalType(component)).join(",");
  return `(${inner})${suffix}`;
}

function normalizeParam(param) {
  const out = {
    name: typeof param?.name === "string" ? param.name : "",
    type: typeof param?.type === "string" ? param.type : "",
    canonicalType: canonicalType(param)
  };

  if (typeof param?.internalType === "string" && param.internalType.length > 0) {
    out.internalType = param.internalType;
  }

  if (typeof param?.indexed === "boolean") {
    out.indexed = param.indexed;
  }

  if (Array.isArray(param?.components) && param.components.length > 0) {
    out.components = param.components.map((component) => normalizeParam(component));
  }

  return out;
}

function toFunctionEntry(contractName, category, fn) {
  const inputs = Array.isArray(fn.inputs) ? fn.inputs.map((item) => normalizeParam(item)) : [];
  const outputs = Array.isArray(fn.outputs) ? fn.outputs.map((item) => normalizeParam(item)) : [];
  const functionName = typeof fn.name === "string" ? fn.name : "";
  const signature = `${functionName}(${inputs.map((item) => item.canonicalType).join(",")})`;

  return {
    contractName,
    category,
    functionName,
    signature,
    inputs,
    outputs,
    stateMutability: typeof fn.stateMutability === "string" ? fn.stateMutability : "nonpayable"
  };
}

function toEventEntry(contractName, category, eventItem) {
  const inputs = Array.isArray(eventItem.inputs) ? eventItem.inputs.map((item) => normalizeParam(item)) : [];
  const eventName = typeof eventItem.name === "string" ? eventItem.name : "";
  const signature = `${eventName}(${inputs.map((item) => item.canonicalType).join(",")})`;

  return {
    contractName,
    category,
    eventName,
    signature,
    anonymous: Boolean(eventItem.anonymous),
    inputs
  };
}

function stableSort(items, keySelector) {
  return [...items].sort((a, b) => keySelector(a).localeCompare(keySelector(b)));
}

function main() {
  const manifest = readJson(MANIFEST_PATH);
  if (!Array.isArray(manifest)) {
    throw new Error(`Manifest must be an array: ${MANIFEST_PATH}`);
  }

  const contracts = [];
  const functions = [];
  const events = [];
  const skipped = [];

  for (const entry of manifest) {
    const contractName = typeof entry?.name === "string" ? entry.name : "";
    const category = typeof entry?.category === "string" ? entry.category : "";
    if (!contractName || !category) {
      skipped.push({ reason: "invalid-manifest-entry", entry });
      continue;
    }

    const abiPath = path.join(ABI_ROOT, category, `${contractName}.abi.json`);
    if (!fs.existsSync(abiPath)) {
      skipped.push({ reason: "missing-abi", contractName, abiPath });
      continue;
    }

    const abi = readJson(abiPath);
    if (!Array.isArray(abi)) {
      skipped.push({ reason: "abi-not-array", contractName, abiPath });
      continue;
    }

    const contractFunctions = [];
    const contractEvents = [];

    for (const item of abi) {
      if (item?.type === "function") {
        const fn = toFunctionEntry(contractName, category, item);
        contractFunctions.push(fn);
        functions.push(fn);
      } else if (item?.type === "event") {
        const eventEntry = toEventEntry(contractName, category, item);
        contractEvents.push(eventEntry);
        events.push(eventEntry);
      }
    }

    contracts.push({
      contractName,
      category,
      sourceFolder: typeof entry.sourceFolder === "string" ? entry.sourceFolder : null,
      artifactPath: typeof entry.artifactPath === "string" ? entry.artifactPath : null,
      functions: stableSort(contractFunctions, (item) => item.signature),
      events: stableSort(contractEvents, (item) => item.signature)
    });
  }

  const payload = {
    generatedAt: new Date().toISOString(),
    source: {
      manifestPath: path.relative(PROJECT_ROOT, MANIFEST_PATH).split(path.sep).join("/"),
      abiRoot: path.relative(PROJECT_ROOT, ABI_ROOT).split(path.sep).join("/")
    },
    summary: {
      contracts: contracts.length,
      functions: functions.length,
      events: events.length,
      skipped: skipped.length
    },
    contracts: stableSort(contracts, (item) => item.contractName),
    functions: stableSort(functions, (item) => `${item.contractName}.${item.signature}`),
    events: stableSort(events, (item) => `${item.contractName}.${item.signature}`),
    skipped
  };

  fs.mkdirSync(OUTPUT_DIR, { recursive: true });
  fs.writeFileSync(OUTPUT_PATH, `${JSON.stringify(payload, null, 2)}\n`, "utf8");

  console.log(
    `[abi:surface] contracts=${payload.summary.contracts} functions=${payload.summary.functions} events=${payload.summary.events} -> ${path.relative(PROJECT_ROOT, OUTPUT_PATH)}`
  );
}

main();
