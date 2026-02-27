import { expect, test, type Page } from "@playwright/test";

function isMobileViewport(page: Page) {
  return (page.viewportSize()?.width ?? 1440) < 768;
}

async function expectNoHorizontalOverflow(page: Page) {
  const hasOverflow = await page.evaluate(() => {
    const html = document.documentElement;
    return html.scrollWidth - window.innerWidth > 1;
  });
  expect(hasOverflow).toBeFalsy();
}

test("@demo browse campaigns and invest panel", async ({ page }) => {
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "Dashboard" })).toBeVisible();
  await expect(page.getByText(/Wallet disconnected/i).first()).toBeVisible();
  await expectNoHorizontalOverflow(page);

  await page.goto("/campaigns");
  await expect(page.getByRole("heading", { name: "Campaigns" })).toBeVisible();

  const firstCampaign = page.locator('a[href^="/campaigns/0x"]').first();
  await expect(firstCampaign).toBeVisible();
  await firstCampaign.click();

  await expect(page).toHaveURL(/\/campaigns\/0x[a-fA-F0-9]{64}$/);
  await page.getByRole("tab", { name: "Invest" }).click();
  await expect(page.getByRole("heading", { name: "Funding" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Redeem" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "My Requests" })).toBeVisible();

  const sticky = page.getByTestId("invest-sticky-actions");
  if (isMobileViewport(page)) {
    await expect(sticky).toBeVisible();
  } else {
    await expect(sticky).toBeHidden();
  }

  await expectNoHorizontalOverflow(page);
});

test("@demo payout signature UI and sticky actions", async ({ page }) => {
  await page.goto("/payout");
  await expect(page.getByRole("heading", { name: "Payout" })).toBeVisible();

  await page.getByPlaceholder("Distribution (YieldAccumulator) 0x...").fill("0x000000000000000000000000000000000000dEaD");
  await page.getByPlaceholder("to (destination wallet) 0x...").fill("0x000000000000000000000000000000000000bEEF");
  await page.getByPlaceholder("maxAmount (RWD)").fill("100");
  await page.getByPlaceholder("deadline (unix, uint64)").fill("32503680000");
  await page.getByPlaceholder("ref bytes32 (non-zero)").fill(`0x${"11".repeat(32)}`);
  await page.getByPlaceholder("payoutRailHash bytes32 (non-zero)").fill(`0x${"22".repeat(32)}`);

  await page.getByPlaceholder("rail text (bank transfer id / wire id)").fill("wire-1234");
  const builtRail = page.getByPlaceholder("keccak(rail text)");
  await expect(builtRail).toHaveValue(/^0x[a-fA-F0-9]{64}$/);

  const signButton = page.getByRole("button", { name: "Sign claim payload" }).first();
  await expect(signButton).toBeDisabled();
  await expect(page.getByText("Connect wallet").first()).toBeVisible();

  const sticky = page.getByTestId("payout-sticky-actions");
  if (isMobileViewport(page)) {
    await expect(sticky).toBeVisible();
  } else {
    await expect(sticky).toBeHidden();
  }

  await expectNoHorizontalOverflow(page);
});

test("@demo admin onramp sticky actions", async ({ page }) => {
  await page.goto("/admin/onramp");
  await expect(page.getByRole("heading", { name: /OnRamp/i })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Sponsored Deposit" })).toBeVisible();

  const sticky = page.getByTestId("onramp-sticky-actions");
  if (isMobileViewport(page)) {
    await expect(sticky).toBeVisible();
  } else {
    await expect(sticky).toBeHidden();
  }

  await expectNoHorizontalOverflow(page);
});
