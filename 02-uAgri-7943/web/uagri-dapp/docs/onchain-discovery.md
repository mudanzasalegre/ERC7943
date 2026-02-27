# On-chain discovery (campaignId → shareToken)

The uAgri kit (as provided) defines a CampaignRegistry and an AgriShareToken, but the registry does **not** store a token address for each campaign.

To build a **100% on-chain** mapping without hardcoding, this frontend uses an event-driven approach:

## 1) Discover campaign IDs
- Read logs from `CampaignRegistry` using the `CampaignCreated(bytes32 campaignId, bytes32 plotRef, address settlementAsset)` event.

## 2) Discover candidate ShareTokens
- Scan logs for the `ModulesUpdated(...)` event defined in `IAgriModulesV1`.
- This event is emitted by the ShareToken when it is initialized/wired with modules.
- Each log's `address` is a candidate ShareToken.

## 3) Map token → campaignId
- For each candidate token address, call `campaignId()` (public getter) from `AgriShareToken`.
- Build the dictionary: `campaignId → tokenAddress`.

## 4) Performance
- The scan is done in block chunks and cached by React Query.
- You can override the scan start block using `NEXT_PUBLIC_DISCOVERY_FROM_BLOCK`.

## Code
- `src/hooks/useCampaigns.ts` (CampaignCreated scan + getCampaign)
- `src/hooks/useShareTokenMap.ts` (ModulesUpdated scan + campaignId() reads)
- `src/lib/discovery.ts` (chunked getLogs helper)