# uAgri dApp (Frontend)

Next.js frontend for the uAgri ERC-7943 contract stack.

## Stack

- Next.js (App Router) + TypeScript
- wagmi + viem
- RainbowKit
- React Query
- Tailwind CSS

## Requirements

- Node.js 18+ (20+ recommended)

## Install and Run

```bash
npm install
npm run dev
```

Open `http://localhost:3000`.

## App Modes

### Demo Mode (default)

The app runs in Demo Mode when deployment addresses are not configured in `.env.local`.

- Deterministic mock campaigns and portfolio
- Simulated transaction UX
- Full UI available without chain deployment

### On-chain Mode

1. Create env file:

```bash
cp .env.example .env.local
```

2. Configure addresses for one or both supported chains:

- `NEXT_PUBLIC_BASE_MAINNET_CAMPAIGN_FACTORY` (recommended)
- `NEXT_PUBLIC_BASE_MAINNET_CAMPAIGN_REGISTRY` (fallback)
- `NEXT_PUBLIC_BASE_MAINNET_ROLE_MANAGER` (optional but recommended)
- `NEXT_PUBLIC_BASE_SEPOLIA_CAMPAIGN_FACTORY` (recommended)
- `NEXT_PUBLIC_BASE_SEPOLIA_CAMPAIGN_REGISTRY` (fallback)
- `NEXT_PUBLIC_BASE_SEPOLIA_ROLE_MANAGER` (optional but recommended)

Legacy fallback variables are still supported:

- `NEXT_PUBLIC_CAMPAIGN_FACTORY`
- `NEXT_PUBLIC_CAMPAIGN_REGISTRY`
- `NEXT_PUBLIC_ROLE_MANAGER`

Optional but recommended:

- `NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID` (optional, must be a valid 32-char hex WalletConnect Cloud project id)
- `NEXT_PUBLIC_BASE_RPC_URL`
- `NEXT_PUBLIC_BASE_SEPOLIA_RPC_URL`
- `NEXT_PUBLIC_DISCOVERY_FROM_BLOCK`

Restart dev server after editing env values.

## Discovery Strategy

Preferred path (factory-first):

1. Read `CampaignDeployed` events from `CampaignFactory`
2. Resolve module addresses via `stacks(campaignId)`

Fallback path (registry-only):

1. Read `CampaignCreated` events from `CampaignRegistry`
2. Derive share token addresses from `ModulesUpdated`
3. Map token addresses back to campaign ids

## Main Routes

- `/`
- `/campaigns`
- `/campaigns/[campaignId]`
- `/portfolio`
- `/activity`
- `/docs`
- `/admin`
- `/admin/explorer`
- `/admin/factory`
- `/admin/contract-tool`
- `/admin/roles`
- `/admin/settlement`
- `/admin/treasury`
- `/admin/disaster`
- `/admin/trace`

## ABI Coverage Metrics

Generate ABI surface + UI coverage reports:

```bash
npm run abi:report
npm run abi:check
```

Outputs:

- `docs/abi/abi-surface.json`
- `docs/abi/ui-coverage.json`
- `docs/abi/coverage-report.md`

`abi:check` fails if function coverage is not `Accessible 100%`.

## QA (PR-20)

Install Chromium once for Playwright:

```bash
npm run e2e:install
```

Run demo E2E matrix (360/390/768/1024/1440):

```bash
npm run e2e
```

Optional on-chain smoke (only if you export valid RPC + addresses):

```powershell
$env:E2E_ONCHAIN="1"
$env:PLAYWRIGHT_FORCE_DEMO="0"
npm run e2e:onchain
```

Run basic Lighthouse accessibility checks (mobile emulation):

```bash
npm run qa:lighthouse:a11y
```

Artifacts:

- Playwright HTML report: `playwright-report/`
- Lighthouse reports: `artifacts/lighthouse/*.a11y.{json,html}`
