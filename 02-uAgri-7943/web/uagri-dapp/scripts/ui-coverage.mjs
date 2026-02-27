import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = path.resolve(SCRIPT_DIR, "..");
const APP_DIR = path.join(PROJECT_ROOT, "app");
const ABI_INDEX_PATH = path.join(PROJECT_ROOT, "src", "lib", "abi", "index.ts");
const UI_MAP_PATH = path.join(PROJECT_ROOT, "docs", "abi", "ui-map.yml");
const SURFACE_PATH = path.join(PROJECT_ROOT, "docs", "abi", "abi-surface.json");
const COVERAGE_JSON_PATH = path.join(PROJECT_ROOT, "docs", "abi", "ui-coverage.json");
const COVERAGE_MD_PATH = path.join(PROJECT_ROOT, "docs", "abi", "coverage-report.md");

function readJson(filePath) {
  if (!fs.existsSync(filePath)) {
    throw new Error(`Missing file: ${filePath}`);
  }
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function listFilesRecursive(dirPath, predicate) {
  const out = [];
  if (!fs.existsSync(dirPath)) {
    return out;
  }
  for (const entry of fs.readdirSync(dirPath, { withFileTypes: true })) {
    const fullPath = path.join(dirPath, entry.name);
    if (entry.isDirectory()) {
      out.push(...listFilesRecursive(fullPath, predicate));
    } else if (entry.isFile() && predicate(fullPath)) {
      out.push(fullPath);
    }
  }
  return out;
}

function toPosix(filePath) {
  return filePath.split(path.sep).join("/");
}

function routeFromPageFile(filePath) {
  const relativePath = toPosix(path.relative(APP_DIR, filePath));
  if (relativePath === "page.tsx") {
    return "/";
  }
  return `/${relativePath.replace(/\/page\.tsx$/u, "")}`;
}

function stripJsonComments(input) {
  return input
    .split(/\r?\n/u)
    .filter((line) => !line.trim().startsWith("#"))
    .join("\n");
}

function readUiMap() {
  if (!fs.existsSync(UI_MAP_PATH)) {
    throw new Error(`Missing UI map: ${UI_MAP_PATH}`);
  }
  const raw = fs.readFileSync(UI_MAP_PATH, "utf8");
  const clean = stripJsonComments(raw).trim();
  if (!clean) {
    return {};
  }
  try {
    return JSON.parse(clean);
  } catch (error) {
    throw new Error(`Invalid UI map (JSON-compatible YAML expected): ${error.message}`);
  }
}

function parseAbiVariableToContractMap() {
  if (!fs.existsSync(ABI_INDEX_PATH)) {
    return new Map();
  }
  const text = fs.readFileSync(ABI_INDEX_PATH, "utf8");
  const importAliasToContract = new Map();
  const variableToContract = new Map();

  const importPattern = /import\s+([A-Za-z0-9_]+)\s+from\s+["']@\/abis\/[^/]+\/([^/]+)\.abi\.json["'];/gu;
  let importMatch = importPattern.exec(text);
  while (importMatch) {
    importAliasToContract.set(importMatch[1], importMatch[2]);
    importMatch = importPattern.exec(text);
  }

  const exportPattern = /export\s+const\s+([A-Za-z0-9_]+)\s*=\s*([A-Za-z0-9_]+)\s+as unknown as Abi;/gu;
  let exportMatch = exportPattern.exec(text);
  while (exportMatch) {
    const exportVar = exportMatch[1];
    const importAlias = exportMatch[2];
    const contractName = importAliasToContract.get(importAlias);
    if (contractName) {
      variableToContract.set(exportVar, contractName);
    }
    exportMatch = exportPattern.exec(text);
  }

  return variableToContract;
}

function addRouteHit(hitMap, key, route, isAdminRoute) {
  if (!hitMap.has(key)) {
    hitMap.set(key, {
      productRoutes: new Set(),
      adminRoutes: new Set()
    });
  }
  const entry = hitMap.get(key);
  if (isAdminRoute) {
    entry.adminRoutes.add(route);
  } else {
    entry.productRoutes.add(route);
  }
}

function scanPageCoverage(variableToContract) {
  const functionHits = new Map();
  const eventHits = new Map();
  const pageFiles = listFilesRecursive(APP_DIR, (filePath) => filePath.endsWith(`${path.sep}page.tsx`) || filePath.endsWith("/page.tsx"));
  const routes = {
    product: new Set(),
    admin: new Set(),
    contractTool: new Set()
  };

  for (const filePath of pageFiles) {
    const route = routeFromPageFile(filePath);
    const isAdminRoute = route.startsWith("/admin");
    if (isAdminRoute) {
      routes.admin.add(route);
    } else {
      routes.product.add(route);
    }
    if (route.startsWith("/admin/contract-tool")) {
      routes.contractTool.add(route);
    }

    const text = fs.readFileSync(filePath, "utf8");

    // Common call shape: { abi: someAbi, functionName: "..." }
    const fnPatternA = /abi\s*:\s*([A-Za-z0-9_]+)[\s\S]{0,450}?functionName\s*:\s*["']([^"']+)["']/gu;
    let fnMatch = fnPatternA.exec(text);
    while (fnMatch) {
      const abiVar = fnMatch[1];
      const functionName = fnMatch[2];
      const contractName = variableToContract.get(abiVar);
      if (contractName) {
        addRouteHit(functionHits, `${contractName}.${functionName}`, route, isAdminRoute);
      }
      fnMatch = fnPatternA.exec(text);
    }

    // Less common shape: { functionName: "...", abi: someAbi }
    const fnPatternB = /functionName\s*:\s*["']([^"']+)["'][\s\S]{0,450}?abi\s*:\s*([A-Za-z0-9_]+)/gu;
    let fnMatchB = fnPatternB.exec(text);
    while (fnMatchB) {
      const functionName = fnMatchB[1];
      const abiVar = fnMatchB[2];
      const contractName = variableToContract.get(abiVar);
      if (contractName) {
        addRouteHit(functionHits, `${contractName}.${functionName}`, route, isAdminRoute);
      }
      fnMatchB = fnPatternB.exec(text);
    }

    const eventPattern = /abi\s*:\s*([A-Za-z0-9_]+)[\s\S]{0,450}?eventName\s*:\s*["']([^"']+)["']/gu;
    let eventMatch = eventPattern.exec(text);
    while (eventMatch) {
      const abiVar = eventMatch[1];
      const eventName = eventMatch[2];
      const contractName = variableToContract.get(abiVar);
      if (contractName) {
        addRouteHit(eventHits, `${contractName}.${eventName}`, route, isAdminRoute);
      }
      eventMatch = eventPattern.exec(text);
    }
  }

  return {
    functionHits,
    eventHits,
    routes: {
      product: [...routes.product].sort(),
      admin: [...routes.admin].sort(),
      contractTool: [...routes.contractTool].sort()
    }
  };
}

function escapeRegex(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
}

function matchesPattern(pattern, candidates) {
  const trimmed = String(pattern ?? "").trim();
  if (!trimmed) {
    return false;
  }

  const regex = new RegExp(`^${escapeRegex(trimmed).replace(/\\\*/gu, ".*")}$`, "u");
  return candidates.some((candidate) => regex.test(candidate));
}

function normalizePatternList(input, fallbackReason) {
  if (!Array.isArray(input)) {
    return [];
  }
  const out = [];
  for (const item of input) {
    if (typeof item === "string") {
      out.push({ match: item, reason: fallbackReason });
      continue;
    }
    if (item && typeof item === "object" && typeof item.match === "string") {
      out.push({
        match: item.match,
        reason: typeof item.reason === "string" && item.reason.length > 0 ? item.reason : fallbackReason
      });
    }
  }
  return out;
}

function normalizePriorityRules(input) {
  if (!Array.isArray(input)) {
    return [];
  }
  const out = [];
  for (const item of input) {
    if (!item || typeof item !== "object") {
      continue;
    }
    if (typeof item.match !== "string") {
      continue;
    }
    const priorityValue = Number(item.priority);
    if (!Number.isFinite(priorityValue)) {
      continue;
    }
    out.push({
      match: item.match,
      priority: Math.trunc(priorityValue),
      reason: typeof item.reason === "string" && item.reason.length > 0 ? item.reason : "Manual rule"
    });
  }
  return out;
}

function defaultPriorityForFunction(functionEntry) {
  const mutability = functionEntry.stateMutability;
  if (mutability === "payable") return 90;
  if (mutability === "nonpayable") return 75;
  return 30;
}

function toSortedArray(setValue) {
  return [...setValue].sort();
}

function calculatePercentage(numerator, denominator) {
  if (!denominator) return "0.0";
  return ((numerator / denominator) * 100).toFixed(1);
}

function buildReportMarkdown(payload) {
  const lines = [];
  lines.push("# ABI Coverage Report");
  lines.push("");
  lines.push(`Generated: ${payload.generatedAt}`);
  lines.push("");
  lines.push("## Totals");
  lines.push("");
  lines.push(`- Functions: ${payload.summary.functions.total}`);
  lines.push(`- Events: ${payload.summary.events.total}`);
  lines.push("");
  lines.push("## Function Coverage");
  lines.push("");
  lines.push(
    `- Accessible: ${payload.summary.functions.accessible}/${payload.summary.functions.total} (${payload.summary.functions.accessiblePct}%)`
  );
  lines.push(
    `- Dedicated UI: ${payload.summary.functions.dedicated}/${payload.summary.functions.total} (${payload.summary.functions.dedicatedPct}%)`
  );
  lines.push(
    `- Product UI: ${payload.summary.functions.product}/${payload.summary.functions.total} (${payload.summary.functions.productPct}%)`
  );
  lines.push(
    `- Admin UI: ${payload.summary.functions.admin}/${payload.summary.functions.total} (${payload.summary.functions.adminPct}%)`
  );
  lines.push(
    `- Contract Tool: ${payload.summary.functions.contractTool}/${payload.summary.functions.total} (${payload.summary.functions.contractToolPct}%)`
  );
  lines.push("");
  lines.push("## Event Coverage");
  lines.push("");
  lines.push(
    `- Product UI: ${payload.summary.events.product}/${payload.summary.events.total} (${payload.summary.events.productPct}%)`
  );
  lines.push(
    `- Admin UI: ${payload.summary.events.admin}/${payload.summary.events.total} (${payload.summary.events.adminPct}%)`
  );
  lines.push("");
  lines.push("## Needs Dedicated UI (prioritized)");
  lines.push("");
  if (payload.needsDedicatedUI.length === 0) {
    lines.push("- None");
  } else {
    lines.push("| Priority | Target | Mutability | Reason |");
    lines.push("| ---: | --- | --- | --- |");
    for (const item of payload.needsDedicatedUI) {
      lines.push(
        `| ${item.priority} | \`${item.contractName}.${item.signature}\` | ${item.stateMutability} | ${item.reason} |`
      );
    }
  }
  lines.push("");
  lines.push("## Routes Scanned");
  lines.push("");
  lines.push(`- Product routes: ${payload.routes.product.join(", ") || "none"}`);
  lines.push(`- Admin routes: ${payload.routes.admin.join(", ") || "none"}`);
  lines.push(`- Contract tool routes: ${payload.routes.contractTool.join(", ") || "none"}`);
  lines.push("");
  lines.push("## Notes");
  lines.push("");
  lines.push(
    `- Contract Tool full-callable mode: ${payload.contractTool.v2CallableAll ? "enabled" : "disabled"}`
  );
  lines.push("- Accessible metric applies to functions (events are informational/read stream).");
  lines.push("");

  return `${lines.join("\n")}\n`;
}

function main() {
  const surface = readJson(SURFACE_PATH);
  const uiMap = readUiMap();
  const variableToContract = parseAbiVariableToContractMap();
  const scan = scanPageCoverage(variableToContract);

  const productPatterns = normalizePatternList(uiMap?.manualCoverage?.productUI, "manual product coverage");
  const adminPatterns = normalizePatternList(uiMap?.manualCoverage?.adminUI, "manual admin coverage");
  const contractToolPatterns = normalizePatternList(uiMap?.manualCoverage?.contractTool, "manual contract tool coverage");
  const priorityRules = normalizePriorityRules(uiMap?.priorityRules);
  const contractToolCallableAll = Boolean(uiMap?.contractTool?.v2CallableAll);

  const functionEntries = [];
  const eventEntries = [];

  for (const fn of surface.functions ?? []) {
    const keyShort = `${fn.contractName}.${fn.functionName}`;
    const keyFull = `${fn.contractName}.${fn.signature}`;
    const hit = scan.functionHits.get(keyShort);
    const autoProductRoutes = hit ? toSortedArray(hit.productRoutes) : [];
    const autoAdminRoutes = hit ? toSortedArray(hit.adminRoutes) : [];
    const candidates = [keyShort, keyFull, fn.signature, fn.functionName];

    const manualProductHits = productPatterns.filter((item) => matchesPattern(item.match, candidates));
    const manualAdminHits = adminPatterns.filter((item) => matchesPattern(item.match, candidates));
    const manualContractToolHits = contractToolPatterns.filter((item) => matchesPattern(item.match, candidates));

    const coveredByProductUI = autoProductRoutes.length > 0 || manualProductHits.length > 0;
    const coveredByAdminUI = autoAdminRoutes.length > 0 || manualAdminHits.length > 0;
    const coveredByContractTool = contractToolCallableAll || manualContractToolHits.length > 0;
    const dedicatedUI = coveredByProductUI || coveredByAdminUI;
    const accessible = dedicatedUI || coveredByContractTool;

    let priority = defaultPriorityForFunction(fn);
    let reason = fn.stateMutability === "view" || fn.stateMutability === "pure" ? "Read-only surface" : "Writable surface";
    for (const rule of priorityRules) {
      if (matchesPattern(rule.match, candidates) && rule.priority >= priority) {
        priority = rule.priority;
        reason = rule.reason;
      }
    }

    functionEntries.push({
      contractName: fn.contractName,
      category: fn.category,
      functionName: fn.functionName,
      signature: fn.signature,
      stateMutability: fn.stateMutability,
      coveredByProductUI,
      coveredByAdminUI,
      coveredByContractTool,
      dedicatedUI,
      accessible,
      autoRoutes: {
        product: autoProductRoutes,
        admin: autoAdminRoutes
      },
      manualMatches: {
        productUI: manualProductHits.map((item) => item.match),
        adminUI: manualAdminHits.map((item) => item.match),
        contractTool: manualContractToolHits.map((item) => item.match)
      },
      priority,
      reason
    });
  }

  for (const eventItem of surface.events ?? []) {
    const keyShort = `${eventItem.contractName}.${eventItem.eventName}`;
    const keyFull = `${eventItem.contractName}.${eventItem.signature}`;
    const hit = scan.eventHits.get(keyShort);
    const autoProductRoutes = hit ? toSortedArray(hit.productRoutes) : [];
    const autoAdminRoutes = hit ? toSortedArray(hit.adminRoutes) : [];
    const candidates = [keyShort, keyFull, eventItem.signature, eventItem.eventName];

    const manualProductHits = productPatterns.filter((item) => matchesPattern(item.match, candidates));
    const manualAdminHits = adminPatterns.filter((item) => matchesPattern(item.match, candidates));
    const manualContractToolHits = contractToolPatterns.filter((item) => matchesPattern(item.match, candidates));

    eventEntries.push({
      contractName: eventItem.contractName,
      category: eventItem.category,
      eventName: eventItem.eventName,
      signature: eventItem.signature,
      coveredByProductUI: autoProductRoutes.length > 0 || manualProductHits.length > 0,
      coveredByAdminUI: autoAdminRoutes.length > 0 || manualAdminHits.length > 0,
      coveredByContractTool: manualContractToolHits.length > 0,
      autoRoutes: {
        product: autoProductRoutes,
        admin: autoAdminRoutes
      },
      manualMatches: {
        productUI: manualProductHits.map((item) => item.match),
        adminUI: manualAdminHits.map((item) => item.match),
        contractTool: manualContractToolHits.map((item) => item.match)
      }
    });
  }

  functionEntries.sort((a, b) => `${a.contractName}.${a.signature}`.localeCompare(`${b.contractName}.${b.signature}`));
  eventEntries.sort((a, b) => `${a.contractName}.${a.signature}`.localeCompare(`${b.contractName}.${b.signature}`));

  const needsDedicatedUI = functionEntries
    .filter((item) => !item.dedicatedUI)
    .sort((a, b) => {
      if (b.priority !== a.priority) return b.priority - a.priority;
      return `${a.contractName}.${a.signature}`.localeCompare(`${b.contractName}.${b.signature}`);
    })
    .map((item) => ({
      contractName: item.contractName,
      functionName: item.functionName,
      signature: item.signature,
      stateMutability: item.stateMutability,
      priority: item.priority,
      reason: item.reason
    }));

  const functionsTotal = functionEntries.length;
  const functionsAccessible = functionEntries.filter((item) => item.accessible).length;
  const functionsDedicated = functionEntries.filter((item) => item.dedicatedUI).length;
  const functionsProduct = functionEntries.filter((item) => item.coveredByProductUI).length;
  const functionsAdmin = functionEntries.filter((item) => item.coveredByAdminUI).length;
  const functionsContractTool = functionEntries.filter((item) => item.coveredByContractTool).length;

  const eventsTotal = eventEntries.length;
  const eventsProduct = eventEntries.filter((item) => item.coveredByProductUI).length;
  const eventsAdmin = eventEntries.filter((item) => item.coveredByAdminUI).length;

  const payload = {
    generatedAt: new Date().toISOString(),
    inputs: {
      surfacePath: toPosix(path.relative(PROJECT_ROOT, SURFACE_PATH)),
      uiMapPath: toPosix(path.relative(PROJECT_ROOT, UI_MAP_PATH)),
      appDir: toPosix(path.relative(PROJECT_ROOT, APP_DIR))
    },
    contractTool: {
      v2CallableAll: contractToolCallableAll
    },
    routes: scan.routes,
    summary: {
      functions: {
        total: functionsTotal,
        accessible: functionsAccessible,
        accessiblePct: calculatePercentage(functionsAccessible, functionsTotal),
        dedicated: functionsDedicated,
        dedicatedPct: calculatePercentage(functionsDedicated, functionsTotal),
        product: functionsProduct,
        productPct: calculatePercentage(functionsProduct, functionsTotal),
        admin: functionsAdmin,
        adminPct: calculatePercentage(functionsAdmin, functionsTotal),
        contractTool: functionsContractTool,
        contractToolPct: calculatePercentage(functionsContractTool, functionsTotal)
      },
      events: {
        total: eventsTotal,
        product: eventsProduct,
        productPct: calculatePercentage(eventsProduct, eventsTotal),
        admin: eventsAdmin,
        adminPct: calculatePercentage(eventsAdmin, eventsTotal)
      }
    },
    functions: functionEntries,
    events: eventEntries,
    needsDedicatedUI
  };

  fs.mkdirSync(path.dirname(COVERAGE_JSON_PATH), { recursive: true });
  fs.writeFileSync(COVERAGE_JSON_PATH, `${JSON.stringify(payload, null, 2)}\n`, "utf8");
  fs.writeFileSync(COVERAGE_MD_PATH, buildReportMarkdown(payload), "utf8");

  console.log(
    `[abi:coverage] functions accessible ${functionsAccessible}/${functionsTotal} (${payload.summary.functions.accessiblePct}%), dedicated ${functionsDedicated}/${functionsTotal} (${payload.summary.functions.dedicatedPct}%)`
  );
  console.log(`[abi:coverage] wrote ${toPosix(path.relative(PROJECT_ROOT, COVERAGE_JSON_PATH))}`);
  console.log(`[abi:coverage] wrote ${toPosix(path.relative(PROJECT_ROOT, COVERAGE_MD_PATH))}`);
}

main();
