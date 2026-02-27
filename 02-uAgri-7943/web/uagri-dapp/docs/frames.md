# Frames / Screens (Mobile + Desktop)

This is a **frame checklist** mirroring the implemented routes and core components.

Breakpoints: **360 / 390 / 768 / 1024 / 1440**.

## Global layout

**Header (sticky)**
- Brand + network badge
- ConnectButton (RainbowKit)
- Wallet state banner (disconnected/read-only, wrong network switch)

**Bottom nav (mobile)**
- Home, Campaigns, Portfolio, Activity, Docs, Admin

## Screens

### Home (`/`)
- KPI cards (demo or on-chain)
- Quick actions CTA strip
- Recent campaigns preview

### Campaigns list (`/campaigns`)
- Search + filter chips (state)
- Campaign cards grid/list
- Skeleton list / empty state CTA

### Campaign detail (`/campaigns/[campaignId]`)
Tabs:
- **Overview**: campaign metadata, state badge, funding cap, time window
- **Actions**: Deposit / Redeem / Claim (with tx modal/toasts)
- **Modules**: addresses + quick links for Compliance / Treasury / Distribution / SettlementQueue
- **Docs & Trace**: shortcuts to Admin Trace/Docs flows

### Portfolio (`/portfolio`)
- Positions list by discovered shareTokens
- Per-token balance + pending claim
- Empty state CTA: go to campaigns

### Activity (`/activity`)
- Recent on-chain actions (placeholder timeline in demo mode)
- Error + retry

### Docs (`/docs`)
- Quickstart
- On-chain discovery explanation
- Env variables

### Admin hub (`/admin`)
- Admin navigation cards
- Warning callout if RoleManager not configured

#### Roles (`/admin/roles`)
- Role selector (bytes32)
- Member list (pagination)
- Grant/Revoke forms

#### Settlement Queue (`/admin/settlement`)
- Inspect request by id
- Create demo requests (demo mode)
- Batch process (ids + epoch + reportHash)

#### Treasury (`/admin/treasury`)
- Available balance + settlement asset
- pay(to, amount, purpose)
- noteInflow(epoch, amount, reportHash)

#### Disaster (`/admin/disaster`)
- getDisaster(campaignId)
- declare / confirm / clear

#### Trace (`/admin/trace`)
- emitTrace()
- anchorRoot()
- registerDoc()

## Global states

- **Loading**: skeletons for lists/cards, inline spinners for tx buttons
- **Empty**: CTA to create/visit campaigns
- **Error**: retry + diagnostics
- **Wallet**: disconnected/read-only, wrong network with “Switch to Base / Base Sepolia”
- **Tx UX**: modal + toasts (pending/success/error) with hash/copy/explorer