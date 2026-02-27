// scripts/export-abis.mjs
// Usage:
//   node scripts/export-abis.mjs --out ../../contracts/out --dest ./src/abis
//
// Exports ABI-only JSON files from Foundry artifacts and generates:
// - src/abis/{contracts,interfaces,standards}/*.abi.json
// - src/abis/manifest.json
// - src/abis/index.ts (abiByName + getAbi)

import fs from "node:fs";
import path from "node:path";

const args = process.argv.slice(2);

function arg(name, fallback) {
  const i = args.indexOf(name);
  if (i === -1) return fallback;
  return args[i + 1] ?? fallback;
}

const OUT_DIR = path.resolve(arg("--out", "out"));
const DEST_DIR = path.resolve(arg("--dest", "abis"));

const EXCLUDE_DIRS = new Set(["build-info", "console.sol", "safeconsole.sol", "Base.sol"]);
const EXCLUDE_FOLDER_PREFIXES = ["Std"];
const EXCLUDE_FOLDER_SUFFIXES = [".s.sol", ".t.sol"]; // scripts/tests
const EXCLUDE_NAME_PREFIXES = ["Std", "Vm", "Script", "TestBase", "CommonBase", "ScriptBase"];
const EXCLUDE_NAME_EXACT = new Set(["console", "safeconsole"]);
const EXCLUDE_TOPLEVEL_FOLDERS = new Set([
  "Vm.sol",
  "Script.sol",
  "StdAssertions.sol",
  "StdChains.sol",
  "StdCheats.sol",
  "StdConstants.sol",
  "StdError.sol",
  "StdInvariant.sol",
  "StdJson.sol",
  "StdMath.sol",
  "StdStorage.sol",
  "StdStyle.sol",
  "StdToml.sol",
  "StdUtils.sol"
]);

const STANDARD_ABI_NAMES = new Set(["IERC20", "IERC1271", "IERC20Decimals", "IERC7943Fungible", "IERC165", "IMulticall3"]);

function toPosix(p) {
  return p.split(path.sep).join("/");
}

function mkdirp(p) {
  fs.mkdirSync(p, { recursive: true });
}

function readJson(filePath) {
  try {
    return JSON.parse(fs.readFileSync(filePath, "utf8"));
  } catch {
    return null;
  }
}

function extractCompilationTargetSource(artifact) {
  let metadata = artifact?.metadata;
  if (typeof metadata === "string") {
    try {
      metadata = JSON.parse(metadata);
    } catch {
      metadata = null;
    }
  }

  const targets = metadata?.settings?.compilationTarget;
  if (!targets || typeof targets !== "object") return null;
  const keys = Object.keys(targets);
  if (keys.length === 0) return null;
  return String(keys[0]);
}

function isTestOrScriptTarget(sourcePath) {
  if (!sourcePath) return false;
  const normalized = sourcePath.replace(/\\\\/g, "/");
  return (
    normalized.startsWith("lib/") ||
    normalized.includes("/lib/") ||
    normalized.startsWith("test/") ||
    normalized.includes("/test/") ||
    normalized.startsWith("script/") ||
    normalized.includes("/script/")
  );
}

function walk(dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...walk(full));
    else if (entry.isFile() && entry.name.endsWith(".json")) out.push(full);
  }
  return out;
}

function shouldExclude(filePath) {
  const rel = path.relative(OUT_DIR, filePath);
  const parts = rel.split(path.sep);

  if (parts.some((part) => EXCLUDE_DIRS.has(part))) return true;

  const topFolder = parts.length >= 2 ? parts[0] : "";
  if (EXCLUDE_TOPLEVEL_FOLDERS.has(topFolder)) return true;
  if (EXCLUDE_FOLDER_SUFFIXES.some((suffix) => topFolder.endsWith(suffix))) return true;
  if (EXCLUDE_FOLDER_PREFIXES.some((prefix) => topFolder.startsWith(prefix))) return true;

  const fileName = path.basename(filePath, ".json");
  if (EXCLUDE_NAME_EXACT.has(fileName)) return true;
  if (EXCLUDE_NAME_PREFIXES.some((prefix) => fileName.startsWith(prefix))) return true;

  return false;
}

function normalizeName(raw) {
  if (typeof raw !== "string") return "";

  let value = raw.trim();
  value = value.replace(/\.sol$/i, "");
  value = value.replace(/\s+/g, "");
  value = value.replace(/[^a-zA-Z0-9_]/g, "_");
  value = value.replace(/_+/g, "_");
  value = value.replace(/^_+|_+$/g, "");

  if (!value) return "Unnamed";
  return value;
}

function categorize(name) {
  if (STANDARD_ABI_NAMES.has(name)) return "standards";
  if (name.startsWith("I") && name.length > 1 && name[1] === name[1].toUpperCase()) return "interfaces";
  return "contracts";
}

function ensureUniqueName(baseName, fileHint, takenNames) {
  if (!takenNames.has(baseName)) {
    takenNames.add(baseName);
    return baseName;
  }

  const hint = normalizeName(fileHint || "artifact");
  let candidate = `${baseName}__${hint}`;
  if (!takenNames.has(candidate)) {
    takenNames.add(candidate);
    return candidate;
  }

  let n = 2;
  while (true) {
    candidate = `${baseName}__${hint}_${n}`;
    if (!takenNames.has(candidate)) {
      takenNames.add(candidate);
      return candidate;
    }
    n += 1;
  }
}

function safeIdentifier(name, takenIdentifiers) {
  let ident = normalizeName(name);
  if (!/^[A-Za-z_]/.test(ident)) ident = `Abi_${ident}`;

  if (!takenIdentifiers.has(ident)) {
    takenIdentifiers.add(ident);
    return ident;
  }

  let n = 2;
  while (true) {
    const candidate = `${ident}_${n}`;
    if (!takenIdentifiers.has(candidate)) {
      takenIdentifiers.add(candidate);
      return candidate;
    }
    n += 1;
  }
}

function clearDestFolders(destDir) {
  for (const category of ["contracts", "interfaces", "standards"]) {
    fs.rmSync(path.join(destDir, category), { recursive: true, force: true });
    mkdirp(path.join(destDir, category));
  }
}

function main() {
  if (!fs.existsSync(OUT_DIR)) {
    console.error(`[export-abis] out dir not found: ${OUT_DIR}`);
    process.exit(1);
  }

  mkdirp(DEST_DIR);
  clearDestFolders(DEST_DIR);

  const jsonFiles = walk(OUT_DIR)
    .filter((filePath) => !shouldExclude(filePath))
    .sort((a, b) => toPosix(path.relative(OUT_DIR, a)).localeCompare(toPosix(path.relative(OUT_DIR, b))));

  const takenNames = new Set();
  const manifest = [];
  const collisions = [];

  for (const artifactPath of jsonFiles) {
    const relArtifact = toPosix(path.relative(OUT_DIR, artifactPath));
    const sourceFolder = relArtifact.includes("/") ? relArtifact.split("/")[0] : "";

    const artifact = readJson(artifactPath);
    const abi = artifact?.abi;
    if (!Array.isArray(abi) || abi.length === 0) {
      continue;
    }

    const sourcePath = extractCompilationTargetSource(artifact);
    if (isTestOrScriptTarget(sourcePath)) {
      continue;
    }

    const originalName = path.basename(artifactPath, ".json");
    const normalizedBaseName = normalizeName(originalName);
    const fileHint = normalizeName(sourceFolder || "artifact");
    const exportName = ensureUniqueName(normalizedBaseName, fileHint, takenNames);

    if (exportName !== normalizedBaseName) {
      collisions.push({
        baseName: normalizedBaseName,
        resolvedName: exportName,
        artifactPath: relArtifact
      });
    }

    const category = categorize(exportName);
    const destPath = path.join(DEST_DIR, category, `${exportName}.abi.json`);
    fs.writeFileSync(destPath, `${JSON.stringify(abi, null, 2)}\n`, "utf8");

    manifest.push({
      name: exportName,
      category,
      sourceFolder,
      artifactPath: relArtifact,
      originalName
    });
  }

  manifest.sort((a, b) => `${a.category}/${a.name}`.localeCompare(`${b.category}/${b.name}`));

  const manifestPath = path.join(DEST_DIR, "manifest.json");
  fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, "utf8");

  const takenIdentifiers = new Set();
  const imports = [];
  const mapEntries = [];

  for (const item of manifest) {
    const importIdent = safeIdentifier(`${item.name}Json`, takenIdentifiers);
    imports.push(`import ${importIdent} from "./${item.category}/${item.name}.abi.json";`);
    mapEntries.push(`  "${item.name}": ${importIdent} as unknown as Abi,`);
  }

  const indexTs = [
    "/* Auto-generated by scripts/export-abis.mjs. Do not edit manually. */",
    "/* eslint-disable */",
    'import type { Abi } from "viem";',
    'import abiManifestJson from "./manifest.json";',
    "",
    ...imports,
    "",
    "export const abiByName: Record<string, Abi> = {",
    ...mapEntries,
    "};",
    "",
    "export type AbiManifestEntry = {",
    "  name: string;",
    "  category: string;",
    "  sourceFolder: string;",
    "  artifactPath: string;",
    "  originalName: string;",
    "};",
    "",
    "export const abiManifest = abiManifestJson as AbiManifestEntry[];",
    "",
    "export function getAbi(name: string): Abi {",
    "  const abi = abiByName[name];",
    '  if (!abi) throw new Error(`ABI not found: ${name}`);',
    "  return abi;",
    "}",
    ""
  ].join("\n");

  fs.writeFileSync(path.join(DEST_DIR, "index.ts"), indexTs, "utf8");

  console.log(`[export-abis] exported ${manifest.length} ABIs to ${DEST_DIR}`);
  console.log(`[export-abis] categories -> contracts=${manifest.filter((m) => m.category === "contracts").length}, interfaces=${manifest.filter((m) => m.category === "interfaces").length}, standards=${manifest.filter((m) => m.category === "standards").length}`);
  if (collisions.length > 0) {
    console.log(`[export-abis] resolved ${collisions.length} name collisions with __fileHint fallback`);
    for (const c of collisions) {
      console.log(`  - ${c.baseName} -> ${c.resolvedName} (${c.artifactPath})`);
    }
  }
}

main();
