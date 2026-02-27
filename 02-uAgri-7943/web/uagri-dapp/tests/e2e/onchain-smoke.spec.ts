import { expect, test, type Page } from "@playwright/test";

const hasAddressConfig = Boolean(
  process.env.NEXT_PUBLIC_BASE_MAINNET_CAMPAIGN_FACTORY ||
    process.env.NEXT_PUBLIC_BASE_MAINNET_CAMPAIGN_REGISTRY ||
    process.env.NEXT_PUBLIC_BASE_SEPOLIA_CAMPAIGN_FACTORY ||
    process.env.NEXT_PUBLIC_BASE_SEPOLIA_CAMPAIGN_REGISTRY ||
    process.env.NEXT_PUBLIC_CAMPAIGN_FACTORY ||
    process.env.NEXT_PUBLIC_CAMPAIGN_REGISTRY
);

async function expectNoLoadErrors(page: Page) {
  await expect(page.getByText("Failed to load campaigns")).toHaveCount(0);
  await expect(page.getByText("Failed to load campaign")).toHaveCount(0);
}

test("@onchain campaigns discovery + contract wiring smoke", async ({ page }) => {
  test.skip(process.env.E2E_ONCHAIN !== "1", "Set E2E_ONCHAIN=1 to run on-chain smoke tests.");
  test.skip(!hasAddressConfig, "No on-chain campaign factory/registry addresses configured.");

  await page.goto("/campaigns");
  await expect(page.getByRole("heading", { name: "Campaigns" })).toBeVisible();
  await expectNoLoadErrors(page);
  await expect(page.getByText("No campaigns found")).toHaveCount(0);

  const firstCampaign = page.locator('a[href^="/campaigns/0x"]').first();
  await expect(firstCampaign).toBeVisible({ timeout: 20_000 });
  await firstCampaign.click();

  await expect(page).toHaveURL(/\/campaigns\/0x[a-fA-F0-9]{64}$/, { timeout: 20_000 });
  await expect(page.getByRole("heading", { name: /^Campaign 0x/i })).toBeVisible();
  await expectNoLoadErrors(page);
  await expect(page.getByText("Campaign not found")).toHaveCount(0);
  await expect(page.getByRole("heading", { name: "Overview" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Modules" })).toBeVisible();
  const explorerAddressLinks = page.locator('a[href*="/address/"]');
  const linkCount = await explorerAddressLinks.count();
  expect(linkCount).toBeGreaterThanOrEqual(6);

  await page.getByRole("tab", { name: "Invest" }).click();
  await expect(page.getByRole("heading", { name: "Funding" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Redeem" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "My Requests" })).toBeVisible();
  await expect(page.getByText("Invest actions unavailable")).toHaveCount(0);

  await page.getByRole("tab", { name: "Rewards" }).click();
  await expect(page.getByRole("heading", { name: "Rewards" })).toBeVisible();
  await expect(page.getByText("Rewards unavailable")).toHaveCount(0);

  await page.getByRole("tab", { name: "Docs" }).click();
  await expect(page.getByRole("heading", { name: "Docs and Traceability" })).toBeVisible();
  await expect(page.getByText("DocumentRegistry unavailable")).toHaveCount(0);
});
