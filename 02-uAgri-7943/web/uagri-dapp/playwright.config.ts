import { defineConfig, devices } from "@playwright/test";

const host = process.env.PLAYWRIGHT_HOST ?? "127.0.0.1";
const port = Number(process.env.PLAYWRIGHT_PORT ?? 3200);
const baseURL = process.env.PLAYWRIGHT_BASE_URL ?? `http://${host}:${port}`;
const forceDemo = process.env.E2E_ONCHAIN === "1" ? false : process.env.PLAYWRIGHT_FORCE_DEMO !== "0";

const demoEnv = forceDemo
  ? {
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
    }
  : {};

const webServerEnv: Record<string, string> = {};
for (const [key, value] of Object.entries({ ...process.env, ...demoEnv })) {
  if (typeof value === "string") {
    webServerEnv[key] = value;
  }
}

export default defineConfig({
  testDir: "./tests/e2e",
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  reporter: [["list"], ["html", { open: "never" }]],
  use: {
    baseURL,
    trace: "on-first-retry",
    screenshot: "only-on-failure",
    video: "retain-on-failure"
  },
  webServer: process.env.PLAYWRIGHT_BASE_URL
    ? undefined
    : {
        command: `npm run dev -- --hostname ${host} --port ${port}`,
        url: baseURL,
        timeout: 120_000,
        reuseExistingServer: !process.env.CI,
        env: webServerEnv
      },
  projects: [
    {
      name: "mobile-360",
      use: {
        browserName: "chromium",
        viewport: { width: 360, height: 780 },
        isMobile: true,
        hasTouch: true
      }
    },
    {
      name: "mobile-390",
      use: {
        browserName: "chromium",
        viewport: { width: 390, height: 844 },
        isMobile: true,
        hasTouch: true
      }
    },
    {
      name: "tablet-768",
      use: {
        browserName: "chromium",
        viewport: { width: 768, height: 1024 },
        hasTouch: true
      }
    },
    {
      name: "desktop-1024",
      use: {
        ...devices["Desktop Chrome"],
        viewport: { width: 1024, height: 768 }
      }
    },
    {
      name: "desktop-1440",
      use: {
        ...devices["Desktop Chrome"],
        viewport: { width: 1440, height: 900 }
      }
    }
  ]
});
