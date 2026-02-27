import { spawn } from "node:child_process";
import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import lighthouse from "lighthouse";
import { launch } from "chrome-launcher";

const host = process.env.LIGHTHOUSE_HOST ?? "127.0.0.1";
const port = Number(process.env.LIGHTHOUSE_PORT ?? 3300);
const baseUrl = process.env.LIGHTHOUSE_BASE_URL ?? `http://${host}:${port}`;
const threshold = Number(process.env.LIGHTHOUSE_A11Y_THRESHOLD ?? "0.9");
const routes = ["/", "/campaigns", "/payout"];

const outDir = path.resolve("artifacts", "lighthouse");

function slugForRoute(route) {
  if (route === "/") return "home";
  return route.replace(/\//g, "-").replace(/^-+/u, "");
}

async function waitForServer(url, timeoutMs = 120_000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      const res = await fetch(url);
      if (res.ok || (res.status >= 200 && res.status < 500)) return;
    } catch {
      // keep polling until timeout
    }
    await new Promise((resolve) => setTimeout(resolve, 1_000));
  }
  throw new Error(`Timed out waiting for ${url}`);
}

function startDevServer() {
  const npmCmd = process.platform === "win32" ? "npm.cmd" : "npm";
  const rawEnv = {
    ...process.env,
    NEXT_PUBLIC_BASE_MAINNET_CAMPAIGN_FACTORY: "",
    NEXT_PUBLIC_BASE_MAINNET_CAMPAIGN_REGISTRY: "",
    NEXT_PUBLIC_BASE_MAINNET_ROLE_MANAGER: "",
    NEXT_PUBLIC_BASE_SEPOLIA_CAMPAIGN_FACTORY: "",
    NEXT_PUBLIC_BASE_SEPOLIA_CAMPAIGN_REGISTRY: "",
    NEXT_PUBLIC_BASE_SEPOLIA_ROLE_MANAGER: "",
    NEXT_PUBLIC_CAMPAIGN_FACTORY: "",
    NEXT_PUBLIC_CAMPAIGN_REGISTRY: "",
    NEXT_PUBLIC_ROLE_MANAGER: "",
    NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID: ""
  };
  const env = {};
  for (const [key, value] of Object.entries(rawEnv)) {
    if (typeof value !== "string") continue;
    if (!key || key.includes("=") || key.includes("\u0000")) continue;
    env[key] = value;
  }

  const child = spawn(`${npmCmd} run dev -- --hostname ${host} --port ${port}`, {
    stdio: "inherit",
    env,
    shell: true
  });

  return child;
}

async function stopDevServer(child) {
  if (!child || child.killed || child.exitCode !== null) return;
  if (process.platform === "win32") {
    await new Promise((resolve) => {
      const killer = spawn("taskkill", ["/pid", String(child.pid), "/f", "/t"], { stdio: "ignore" });
      killer.on("exit", () => resolve(undefined));
    });
    return;
  }
  child.kill("SIGTERM");
}

async function run() {
  let server;
  let chrome;
  try {
    await fs.mkdir(outDir, { recursive: true });

    if (!process.env.LIGHTHOUSE_BASE_URL) {
      server = startDevServer();
      await waitForServer(baseUrl);
    }

    chrome = await launch({
      chromeFlags: ["--headless=new", "--no-sandbox", "--disable-dev-shm-usage"]
    });

    const scores = [];
    for (const route of routes) {
      const url = `${baseUrl}${route}`;
      const runner = await lighthouse(url, {
        port: chrome.port,
        logLevel: "error",
        output: ["json", "html"],
        onlyCategories: ["accessibility"],
        formFactor: "mobile",
        screenEmulation: {
          mobile: true,
          width: 390,
          height: 844,
          deviceScaleFactor: 3,
          disabled: false
        }
      });

      if (!runner) {
        throw new Error(`No Lighthouse result for ${url}`);
      }

      const score = runner.lhr.categories.accessibility.score ?? 0;
      scores.push(score);

      const report = Array.isArray(runner.report) ? runner.report : [runner.report];
      const slug = slugForRoute(route);
      await fs.writeFile(path.join(outDir, `${slug}.a11y.json`), report[0], "utf8");
      if (report[1]) {
        await fs.writeFile(path.join(outDir, `${slug}.a11y.html`), report[1], "utf8");
      }

      const scorePct = (score * 100).toFixed(1);
      // eslint-disable-next-line no-console
      console.log(`[lighthouse] ${route} accessibility score: ${scorePct}`);
    }

    const minScore = Math.min(...scores);
    const minPct = (minScore * 100).toFixed(1);
    if (minScore < threshold) {
      throw new Error(`Accessibility threshold failed. Min score ${minPct} < ${(threshold * 100).toFixed(1)}.`);
    }

    // eslint-disable-next-line no-console
    console.log(`[lighthouse] PASS. Min accessibility score: ${minPct}`);
  } finally {
    if (chrome) {
      await chrome.kill();
    }
    if (server) {
      await stopDevServer(server);
    }
  }
}

run().catch((error) => {
  // eslint-disable-next-line no-console
  console.error(error);
  process.exit(1);
});
