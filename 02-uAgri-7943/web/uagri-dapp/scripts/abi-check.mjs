import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = path.resolve(SCRIPT_DIR, "..");
const ABI_SURFACE_PATH = path.join(PROJECT_ROOT, "docs", "abi", "abi-surface.json");
const UI_COVERAGE_PATH = path.join(PROJECT_ROOT, "docs", "abi", "ui-coverage.json");
const COVERAGE_REPORT_PATH = path.join(PROJECT_ROOT, "docs", "abi", "coverage-report.md");

function fail(message) {
  console.error(`[abi:check] ${message}`);
  process.exit(1);
}

function readJson(filePath) {
  if (!fs.existsSync(filePath)) {
    fail(`Missing file: ${path.relative(PROJECT_ROOT, filePath)}`);
  }
  try {
    return JSON.parse(fs.readFileSync(filePath, "utf8"));
  } catch (error) {
    fail(`Invalid JSON at ${path.relative(PROJECT_ROOT, filePath)}: ${error.message}`);
  }
}

function main() {
  const abiSurface = readJson(ABI_SURFACE_PATH);
  const uiCoverage = readJson(UI_COVERAGE_PATH);

  if (!fs.existsSync(COVERAGE_REPORT_PATH)) {
    fail(`Missing file: ${path.relative(PROJECT_ROOT, COVERAGE_REPORT_PATH)}`);
  }

  const functionsTotal = Number(uiCoverage?.summary?.functions?.total ?? 0);
  const functionsAccessible = Number(uiCoverage?.summary?.functions?.accessible ?? 0);
  const functionsDedicated = Number(uiCoverage?.summary?.functions?.dedicated ?? 0);
  const eventsTotal = Number(uiCoverage?.summary?.events?.total ?? 0);
  const needsDedicated = Array.isArray(uiCoverage?.needsDedicatedUI) ? uiCoverage.needsDedicatedUI.length : 0;
  const contractToolCallableAll = Boolean(uiCoverage?.contractTool?.v2CallableAll);

  if (functionsTotal <= 0) {
    fail("Function total is zero. Run `npm run abi:report` after generating ABIs.");
  }

  const surfaceFunctionsTotal = Number(abiSurface?.summary?.functions ?? 0);
  if (surfaceFunctionsTotal !== functionsTotal) {
    fail(
      `Function totals mismatch (abi-surface=${surfaceFunctionsTotal}, ui-coverage=${functionsTotal}). Run \`npm run abi:report\`.`
    );
  }

  if (functionsAccessible !== functionsTotal) {
    fail(`Accessible coverage must be 100%. Got ${functionsAccessible}/${functionsTotal}.`);
  }

  const reportText = fs.readFileSync(COVERAGE_REPORT_PATH, "utf8");
  if (!reportText.includes("## Function Coverage")) {
    fail("Coverage markdown does not include the Function Coverage section.");
  }

  if (!contractToolCallableAll) {
    console.warn("[abi:check] Warning: contractTool.v2CallableAll is false; accessible 100% relies on dedicated/manual coverage only.");
  }

  console.log("[abi:check] PASS");
  console.log(`[abi:check] Functions: accessible ${functionsAccessible}/${functionsTotal}, dedicated ${functionsDedicated}/${functionsTotal}`);
  console.log(`[abi:check] Events: ${eventsTotal}`);
  console.log(`[abi:check] Needs dedicated UI: ${needsDedicated}`);
}

main();

