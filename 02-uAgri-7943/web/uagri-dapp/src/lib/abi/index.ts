import type { Abi } from "viem";

// We import JSON ABIs exported from Foundry `out/` (stored in `src/abis/**`).
// This avoids `parseAbi()` string pitfalls with structs/tuples.

import AgriCampaignRegistryAbiJson from "@/abis/contracts/AgriCampaignRegistry.abi.json";
import CampaignFactoryAbiJson from "@/abis/contracts/CampaignFactory.abi.json";
import AgriShareTokenAbiJson from "@/abis/contracts/AgriShareToken.abi.json";
import FundingManagerAbiJson from "@/abis/contracts/FundingManager.abi.json";
import YieldAccumulatorAbiJson from "@/abis/contracts/YieldAccumulator.abi.json";
import HarvestOracleAbiJson from "@/abis/contracts/HarvestOracle.abi.json";
import SalesProceedsOracleAbiJson from "@/abis/contracts/SalesProceedsOracle.abi.json";
import CustodyOracleAbiJson from "@/abis/contracts/CustodyOracle.abi.json";
import DisasterEvidenceOracleAbiJson from "@/abis/contracts/DisasterEvidenceOracle.abi.json";
import RoleManagerAbiJson from "@/abis/contracts/RoleManager.abi.json";
import SettlementQueueAbiJson from "@/abis/contracts/SettlementQueue.abi.json";
import ComplianceModuleV1AbiJson from "@/abis/contracts/ComplianceModuleV1.abi.json";
import IdentityAttestationAbiJson from "@/abis/contracts/IdentityAttestation.abi.json";

import IAgriDisasterAdminV1AbiJson from "@/abis/interfaces/IAgriDisasterAdminV1.abi.json";
import IAgriDisasterV1AbiJson from "@/abis/interfaces/IAgriDisasterV1.abi.json";
import IAgriComplianceV1AbiJson from "@/abis/interfaces/IAgriComplianceV1.abi.json";
import IAgriModulesV1AbiJson from "@/abis/interfaces/IAgriModulesV1.abi.json";
import IAgriDistributionV1AbiJson from "@/abis/interfaces/IAgriDistributionV1.abi.json";
import IAgriDocumentRegistryV1AbiJson from "@/abis/interfaces/IAgriDocumentRegistryV1.abi.json";
import IAgriTraceV1AbiJson from "@/abis/interfaces/IAgriTraceV1.abi.json";
import IAgriTreasuryV1AbiJson from "@/abis/interfaces/IAgriTreasuryV1.abi.json";
import BatchMerkleAnchorAbiJson from "@/abis/contracts/BatchMerkleAnchor.abi.json";

import IERC20AbiJson from "@/abis/standards/IERC20.abi.json";
import IERC20DecimalsAbiJson from "@/abis/standards/IERC20Decimals.abi.json";

// Core discovery + reads
export const campaignRegistryAbi = AgriCampaignRegistryAbiJson as unknown as Abi;
export const campaignFactoryAbi = CampaignFactoryAbiJson as unknown as Abi;
export const shareTokenAbi = AgriShareTokenAbiJson as unknown as Abi;
export const fundingManagerAbi = FundingManagerAbiJson as unknown as Abi;

// Queue + rewards
export const settlementQueueAbi = SettlementQueueAbiJson as unknown as Abi;
export const distributionAbi = IAgriDistributionV1AbiJson as unknown as Abi;
export const yieldAccumulatorAbi = YieldAccumulatorAbiJson as unknown as Abi;
export const treasuryAbi = IAgriTreasuryV1AbiJson as unknown as Abi;
export const disasterViewAbi = IAgriDisasterV1AbiJson as unknown as Abi;
export const complianceAbi = IAgriComplianceV1AbiJson as unknown as Abi;
export const complianceModuleAbi = ComplianceModuleV1AbiJson as unknown as Abi;
export const identityAttestationAbi = IdentityAttestationAbiJson as unknown as Abi;
export const harvestOracleAbi = HarvestOracleAbiJson as unknown as Abi;
export const salesProceedsOracleAbi = SalesProceedsOracleAbiJson as unknown as Abi;
export const custodyOracleAbi = CustodyOracleAbiJson as unknown as Abi;
export const disasterEvidenceOracleAbi = DisasterEvidenceOracleAbiJson as unknown as Abi;

// Used for on-chain discovery when Factory is not configured (scan `ModulesUpdated` logs)
export const modulesUpdatedEventAbi = IAgriModulesV1AbiJson as unknown as Abi;

// Standard ERC20 (settlement asset)
export const erc20Abi = IERC20AbiJson as unknown as Abi;
export const erc20DecimalsAbi = IERC20DecimalsAbiJson as unknown as Abi;
export const erc20AllowanceAbi = AgriShareTokenAbiJson as unknown as Abi;

// Admin ABIs
export const roleManagerAbi = RoleManagerAbiJson as unknown as Abi;
export const disasterAdminAbi = IAgriDisasterAdminV1AbiJson as unknown as Abi;
export const traceAbi = IAgriTraceV1AbiJson as unknown as Abi;
export const documentRegistryAbi = IAgriDocumentRegistryV1AbiJson as unknown as Abi;
export const batchMerkleAnchorAbi = BatchMerkleAnchorAbiJson as unknown as Abi;
