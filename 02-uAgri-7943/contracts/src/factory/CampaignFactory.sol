// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {TwoStepAdmin} from "../_shared/TwoStepAdmin.sol";
import {ClonesLib} from "./ClonesLib.sol";
import {CampaignTemplate} from "./CampaignTemplate.sol";

import {RoleManager} from "../access/RoleManager.sol";

import {UAgriTypes} from "../interfaces/constants/UAgriTypes.sol";
import {UAgriRoles} from "../interfaces/constants/UAgriRoles.sol";
import {IAgriModulesV1} from "../interfaces/v1/IAgriModulesV1.sol";

import {AgriCampaignRegistry} from "../campaign/AgriCampaignRegistry.sol";
import {AgriShareToken} from "../core/AgriShareToken.sol";
import {CampaignTreasury} from "../campaign/CampaignTreasury.sol";
import {FundingManager} from "../campaign/FundingManager.sol";
import {SettlementQueue} from "../campaign/SettlementQueue.sol";

import {IdentityAttestation} from "../compliance/IdentityAttestation.sol";
import {ComplianceModuleV1} from "../compliance/ComplianceModuleV1.sol";

import {DisasterModule} from "../disaster/DisasterModule.sol";

import {FreezeManager} from "../control/FreezeManager.sol";
import {ForcedTransferController} from "../control/ForcedTransferController.sol";

import {TraceabilityRegistry} from "../trace/TraceabilityRegistry.sol";
import {DocumentRegistry} from "../trace/DocumentRegistry.sol";
import {BatchMerkleAnchor} from "../trace/BatchMerkleAnchor.sol";

import {SnapshotModule} from "../distribution/SnapshotModule.sol";
import {YieldAccumulator} from "../distribution/YieldAccumulator.sol";

import {InsurancePool} from "../disaster/InsurancePool.sol";

import {CustodyOracle} from "../oracles/CustodyOracle.sol";

/// @title CampaignFactory
/// @notice Productizable deployment of full uAgri campaign stacks (token + modules).
/// @dev Uses EIP-1167 clones for cloneable contracts (no constructors executed).
///      RoleManager is instantiated per-campaign with DEFAULT_ADMIN = this factory,
///      enabling single-tx wiring and role grants. Admin handoff can be done post-deploy.
contract CampaignFactory is TwoStepAdmin {
    modifier onlyAdmin() {
        _requireAdmin();
        _;
    }

    // --------------------------------- Errors ---------------------------------
    error CampaignFactory__InvalidAddress();
    error CampaignFactory__InvalidCampaignId();
    error CampaignFactory__UnknownCampaign(bytes32 campaignId);
    error CampaignFactory__CampaignExists(bytes32 campaignId);
    error CampaignFactory__MissingTemplate();
    error CampaignFactory__TemplateMissingImpl(bytes32 which);
    error CampaignFactory__InvalidFees();
    error CampaignFactory__InvalidRewardToken();
    error CampaignFactory__InvalidConfig();
    error CampaignFactory__InvalidViewGas();

    // --------------------------------- Labels ---------------------------------
    bytes32 internal constant L_ROLE_MANAGER        = keccak256("uAgri.factory.ROLE_MANAGER");
    bytes32 internal constant L_CAMPAIGN_REGISTRY   = keccak256("uAgri.factory.CAMPAIGN_REGISTRY");
    bytes32 internal constant L_SHARE_TOKEN         = keccak256("uAgri.factory.SHARE_TOKEN");
    bytes32 internal constant L_TREASURY            = keccak256("uAgri.factory.TREASURY");
    bytes32 internal constant L_FUNDING_MANAGER     = keccak256("uAgri.factory.FUNDING_MANAGER");
    bytes32 internal constant L_SETTLEMENT_QUEUE    = keccak256("uAgri.factory.SETTLEMENT_QUEUE");
    bytes32 internal constant L_IDENTITY_ATTESTATION= keccak256("uAgri.factory.IDENTITY_ATTESTATION");
    bytes32 internal constant L_COMPLIANCE_MODULE   = keccak256("uAgri.factory.COMPLIANCE_MODULE");
    bytes32 internal constant L_DISASTER_MODULE     = keccak256("uAgri.factory.DISASTER_MODULE");
    bytes32 internal constant L_FREEZE_MANAGER      = keccak256("uAgri.factory.FREEZE_MANAGER");
    bytes32 internal constant L_FORCED_TRANSFER     = keccak256("uAgri.factory.FORCED_TRANSFER");
    bytes32 internal constant L_TRACE_REGISTRY      = keccak256("uAgri.factory.TRACE_REGISTRY");
    bytes32 internal constant L_DOC_REGISTRY        = keccak256("uAgri.factory.DOC_REGISTRY");
    bytes32 internal constant L_BATCH_ANCHOR        = keccak256("uAgri.factory.BATCH_ANCHOR");
    bytes32 internal constant L_SNAPSHOT_MODULE     = keccak256("uAgri.factory.SNAPSHOT_MODULE");
    bytes32 internal constant L_YIELD_ACCUMULATOR   = keccak256("uAgri.factory.YIELD_ACCUMULATOR");
    bytes32 internal constant L_INSURANCE_POOL      = keccak256("uAgri.factory.INSURANCE_POOL");

    // --------------------------------- Types ----------------------------------
    struct RolesConfig {
        address governance;
        address guardian;
        address treasuryAdmin;
        address complianceOfficer;
        address farmOperator;
        address regulatorEnforcer;
        address disasterAdmin;
        address oracleUpdater;
        address custodyAttester;
        address insuranceAdmin;
        address onRampOperator;
        address payoutOperator;
        address rewardNotifier;
    }

    struct CampaignConfig {
        UAgriTypes.Campaign campaign;
        string name;
        string symbol;
        uint8 decimals;

        bool enforceComplianceOnPay;

        uint16 depositFeeBps;
        uint16 redeemFeeBps;
        address feeRecipient;

        bool allowDepositsWhenActive;
        bool allowRedeemsDuringFunding;
        bool enforceCustodyFreshOnRedeem;

        bool depositExactSharesMode;

        bool enableForcedTransfers;
        bool enableCustodyOracle;

        bool enableTrace;
        bool enableDocuments;
        bool enableBatchAnchor;

        bool enableDistribution;
        address rewardToken;
        bool enforceComplianceOnClaim;

        bool enableInsurance;

        UAgriTypes.ViewGasLimits viewGas;
    }

    struct CampaignStack {
        address roleManager;
        address registry;

        address shareToken;
        address treasury;
        address fundingManager;
        address settlementQueue;

        address identityAttestation;
        address compliance;
        address disaster;
        address freezeModule;
        address forcedTransferController;
        address custody;

        address trace;
        address documentRegistry;
        address batchAnchor;

        address snapshot;
        address distribution;
        address insurance;
    }

    // -------------------------------- Storage --------------------------------
    CampaignTemplate public template;
    mapping(bytes32 => CampaignStack) private _stacks;

    // --------------------------------- Events --------------------------------
    event TemplateUpdated(address indexed oldTemplate, address indexed newTemplate);

    event CampaignDeployed(
        bytes32 indexed campaignId,
        address indexed roleManager,
        address indexed shareToken,
        address registry,
        address treasury,
        address fundingManager,
        address settlementQueue
    );

    // ------------------------------ Constructor -------------------------------
    constructor(address admin_, address template_) TwoStepAdmin(admin_) {
        if (template_ == address(0)) revert CampaignFactory__InvalidAddress();
        template = CampaignTemplate(template_);
        emit TemplateUpdated(address(0), template_);
    }

    // ------------------------------ Admin ops ---------------------------------
    function setTemplate(address newTemplate) external onlyAdmin {
        if (newTemplate == address(0)) revert CampaignFactory__InvalidAddress();
        address old = address(template);
        template = CampaignTemplate(newTemplate);
        emit TemplateUpdated(old, newTemplate);
    }

    function beginRoleManagerAdminHandoff(bytes32 campaignId, address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert CampaignFactory__InvalidAddress();
        address rm = _stacks[campaignId].roleManager;
        if (rm == address(0)) revert CampaignFactory__UnknownCampaign(campaignId);
        RoleManager(rm).beginDefaultAdminTransfer(newAdmin);
    }

    function stacks(bytes32 campaignId) external view returns (CampaignStack memory) {
        return _stacks[campaignId];
    }

    // ------------------------------ Deployment --------------------------------
    function createCampaign(CampaignConfig calldata cfg, RolesConfig calldata roles)
        external
        onlyAdmin
        returns (CampaignStack memory out)
    {
        (CampaignTemplate tplt, bytes32 cid) = _validateCreateCampaign(cfg);
        out = _wireCampaignStack(cfg, roles, cid, tplt);

        _stacks[cid] = out;
        _emitCampaignDeployed(cid, out);

        return out;
    }

    // -------------------------------- Internals ------------------------------
    function _wireCampaignStack(
        CampaignConfig calldata cfg,
        RolesConfig calldata roles,
        bytes32 cid,
        CampaignTemplate tplt
    ) internal returns (CampaignStack memory out) {
        out = _deployStack(cfg, cid, tplt.getTemplateV1());
        _initializeRoleManager(out.roleManager, roles, out.fundingManager);
        _initializeCoreModules(cfg, cid, out);
        _initializeToken(cfg, cid, tplt, out);
        _initializeFunding(cfg, cid, out);
        _initializeDistributionAndInsurance(cfg, cid, out);
        _applyComplianceExemptions(out);
    }

    function _emitCampaignDeployed(bytes32 cid, CampaignStack memory out) internal {
        emit CampaignDeployed(
            cid,
            out.roleManager,
            out.shareToken,
            out.registry,
            out.treasury,
            out.fundingManager,
            out.settlementQueue
        );
    }

    function _validateCreateCampaign(CampaignConfig calldata cfg)
        internal
        view
        returns (CampaignTemplate tplt, bytes32 cid)
    {
        tplt = template;
        if (address(tplt) == address(0)) revert CampaignFactory__MissingTemplate();

        cid = cfg.campaign.campaignId;
        if (cid == bytes32(0)) revert CampaignFactory__InvalidCampaignId();
        if (_stacks[cid].shareToken != address(0)) revert CampaignFactory__CampaignExists(cid);

        if (cfg.depositFeeBps >= 10_000 || cfg.redeemFeeBps >= 10_000) revert CampaignFactory__InvalidFees();
        if ((cfg.depositFeeBps != 0 || cfg.redeemFeeBps != 0) && cfg.feeRecipient == address(0)) {
            revert CampaignFactory__InvalidFees();
        }

        if (cfg.enableDistribution && cfg.rewardToken == address(0)) revert CampaignFactory__InvalidRewardToken();
        if (cfg.enableDistribution && cfg.rewardToken != cfg.campaign.settlementAsset) {
            revert CampaignFactory__InvalidRewardToken();
        }
        if (cfg.enableInsurance && !cfg.enableDistribution) revert CampaignFactory__InvalidConfig();

        _validateViewGas(cfg.viewGas);
    }

    function _deployStack(CampaignConfig calldata cfg, bytes32 cid, CampaignTemplate.TemplateV1 memory impl)
        internal
        returns (CampaignStack memory out)
    {
        out = _deployCoreStack(cid, impl);
        out = _deployOptionalStack(cfg, cid, impl, out);
    }

    function _deployCoreStack(bytes32 cid, CampaignTemplate.TemplateV1 memory impl)
        internal
        returns (CampaignStack memory out)
    {
        out.roleManager = _cloneOrRevert(impl.roleManager, _salt(cid, L_ROLE_MANAGER));
        out.registry = _cloneOrRevert(impl.campaignRegistry, _salt(cid, L_CAMPAIGN_REGISTRY));
        out.shareToken = _cloneOrRevert(impl.shareToken, _salt(cid, L_SHARE_TOKEN));
        out.fundingManager = _cloneOrRevert(impl.fundingManager, _salt(cid, L_FUNDING_MANAGER));
        out.settlementQueue = _cloneOrRevert(impl.settlementQueue, _salt(cid, L_SETTLEMENT_QUEUE));
        out.treasury = _cloneOrRevert(impl.treasury, _salt(cid, L_TREASURY));
        out.identityAttestation = _cloneOrRevert(impl.identityAttestation, _salt(cid, L_IDENTITY_ATTESTATION));
        out.compliance = _cloneOrRevert(impl.complianceModule, _salt(cid, L_COMPLIANCE_MODULE));
        out.disaster = _cloneOrRevert(impl.disasterModule, _salt(cid, L_DISASTER_MODULE));
        out.freezeModule = _cloneOrRevert(impl.freezeManager, _salt(cid, L_FREEZE_MANAGER));
    }

    function _deployOptionalStack(
        CampaignConfig calldata cfg,
        bytes32 cid,
        CampaignTemplate.TemplateV1 memory impl,
        CampaignStack memory out
    ) internal returns (CampaignStack memory) {
        if (cfg.enableForcedTransfers) {
            if (impl.forcedTransferController == address(0)) revert CampaignFactory__TemplateMissingImpl(L_FORCED_TRANSFER);
            out.forcedTransferController = _cloneOrRevert(impl.forcedTransferController, _salt(cid, L_FORCED_TRANSFER));
        }

        if (cfg.enableTrace) {
            if (impl.traceRegistry == address(0)) revert CampaignFactory__TemplateMissingImpl(L_TRACE_REGISTRY);
            out.trace = _cloneOrRevert(impl.traceRegistry, _salt(cid, L_TRACE_REGISTRY));
        }

        if (cfg.enableDocuments) {
            if (impl.documentRegistry == address(0)) revert CampaignFactory__TemplateMissingImpl(L_DOC_REGISTRY);
            out.documentRegistry = _cloneOrRevert(impl.documentRegistry, _salt(cid, L_DOC_REGISTRY));
        }

        if (cfg.enableBatchAnchor) {
            if (impl.batchMerkleAnchor == address(0)) revert CampaignFactory__TemplateMissingImpl(L_BATCH_ANCHOR);
            out.batchAnchor = _cloneOrRevert(impl.batchMerkleAnchor, _salt(cid, L_BATCH_ANCHOR));
        }

        if (cfg.enableDistribution) {
            if (impl.snapshotModule == address(0)) revert CampaignFactory__TemplateMissingImpl(L_SNAPSHOT_MODULE);
            if (impl.yieldAccumulator == address(0)) revert CampaignFactory__TemplateMissingImpl(L_YIELD_ACCUMULATOR);
            out.snapshot = _cloneOrRevert(impl.snapshotModule, _salt(cid, L_SNAPSHOT_MODULE));
            out.distribution = _cloneOrRevert(impl.yieldAccumulator, _salt(cid, L_YIELD_ACCUMULATOR));
        }

        if (cfg.enableInsurance) {
            if (impl.insurancePool == address(0)) revert CampaignFactory__TemplateMissingImpl(L_INSURANCE_POOL);
            out.insurance = _cloneOrRevert(impl.insurancePool, _salt(cid, L_INSURANCE_POOL));
        }

        if (cfg.enableCustodyOracle) {
            out.custody = address(new CustodyOracle(out.roleManager));
        }

        return out;
    }

    function _initializeRoleManager(address roleManager, RolesConfig calldata roles, address fundingManager) internal {
        RoleManager rm = RoleManager(roleManager);
        rm.initialize(address(this));

        _grantIfSet(rm, UAgriRoles.GOVERNANCE_ROLE, roles.governance);
        _grantIfSet(rm, UAgriRoles.GUARDIAN_ROLE, roles.guardian);
        _grantIfSet(rm, UAgriRoles.TREASURY_ADMIN_ROLE, roles.treasuryAdmin);
        _grantIfSet(rm, UAgriRoles.COMPLIANCE_OFFICER_ROLE, roles.complianceOfficer);
        _grantIfSet(rm, UAgriRoles.FARM_OPERATOR_ROLE, roles.farmOperator);
        _grantIfSet(rm, UAgriRoles.REGULATOR_ENFORCER_ROLE, roles.regulatorEnforcer);
        _grantIfSet(rm, UAgriRoles.DISASTER_ADMIN_ROLE, roles.disasterAdmin);
        _grantIfSet(rm, UAgriRoles.ORACLE_UPDATER_ROLE, roles.oracleUpdater);
        _grantIfSet(rm, UAgriRoles.CUSTODY_ATTESTER_ROLE, roles.custodyAttester);
        _grantIfSet(rm, UAgriRoles.INSURANCE_ADMIN_ROLE, roles.insuranceAdmin);
        _grantIfSet(rm, UAgriRoles.ONRAMP_OPERATOR_ROLE, roles.onRampOperator);
        _grantIfSet(rm, UAgriRoles.PAYOUT_OPERATOR_ROLE, roles.payoutOperator);
        _grantIfSet(rm, UAgriRoles.REWARD_NOTIFIER_ROLE, roles.rewardNotifier);

        rm.grantRole(UAgriRoles.TREASURY_ADMIN_ROLE, fundingManager);
    }

    function _initializeCoreModules(CampaignConfig calldata cfg, bytes32 cid, CampaignStack memory out) internal {
        AgriCampaignRegistry(out.registry).initialize(out.roleManager);
        AgriCampaignRegistry(out.registry).createCampaign(cfg.campaign);

        IdentityAttestation(out.identityAttestation).initialize(out.roleManager);
        ComplianceModuleV1(out.compliance).initialize(out.roleManager, out.identityAttestation);

        DisasterModule(out.disaster).initialize(out.roleManager);
        FreezeManager(out.freezeModule).initialize(out.roleManager, out.shareToken);

        if (out.trace != address(0)) TraceabilityRegistry(out.trace).initialize(out.roleManager);
        if (out.documentRegistry != address(0)) DocumentRegistry(out.documentRegistry).initialize(out.roleManager);
        if (out.batchAnchor != address(0)) BatchMerkleAnchor(out.batchAnchor).initialize(out.roleManager);

        CampaignTreasury(out.treasury).initialize(
            out.roleManager,
            cid,
            out.shareToken,
            cfg.campaign.settlementAsset,
            out.fundingManager,
            cfg.enforceComplianceOnPay
        );
    }

    function _initializeToken(CampaignConfig calldata cfg, bytes32 cid, CampaignTemplate tplt, CampaignStack memory out)
        internal
    {
        UAgriTypes.ViewGasLimits memory gasCfg = _resolveViewGas(cfg.viewGas, tplt.getDefaultViewGasLimits());

        AgriShareToken(out.shareToken).initialize(
            out.roleManager,
            cid,
            cfg.name,
            cfg.symbol,
            cfg.decimals,
            _buildModules(out),
            cfg.enableForcedTransfers ? out.forcedTransferController : address(0),
            gasCfg
        );

        if (out.forcedTransferController != address(0)) {
            ForcedTransferController(out.forcedTransferController).initialize(
                out.roleManager,
                out.freezeModule,
                out.shareToken,
                true
            );
        }
    }

    function _initializeFunding(CampaignConfig calldata cfg, bytes32 cid, CampaignStack memory out) internal {
        FundingManager(out.fundingManager).initialize(
            out.roleManager,
            cid,
            out.shareToken,
            out.registry,
            out.settlementQueue,
            cfg.depositFeeBps,
            cfg.redeemFeeBps,
            cfg.feeRecipient,
            cfg.allowDepositsWhenActive,
            cfg.allowRedeemsDuringFunding,
            cfg.enforceCustodyFreshOnRedeem && (out.custody != address(0))
        );

        SettlementQueue(out.settlementQueue).initialize(
            out.roleManager,
            cid,
            out.fundingManager,
            cfg.depositExactSharesMode
        );
    }

    function _initializeDistributionAndInsurance(CampaignConfig calldata cfg, bytes32 cid, CampaignStack memory out)
        internal
    {
        if (out.distribution != address(0)) {
            YieldAccumulator(out.distribution).initialize(
                out.roleManager,
                out.shareToken,
                cfg.rewardToken,
                cfg.enforceComplianceOnClaim
            );
            CampaignTreasury(out.treasury).setSpender(out.distribution, true);
        }

        if (out.snapshot != address(0)) {
            SnapshotModule(out.snapshot).initialize(out.roleManager, out.shareToken);
        }

        if (out.insurance != address(0)) {
            InsurancePool(out.insurance).initialize(
                out.roleManager,
                cid,
                cfg.campaign.settlementAsset,
                out.snapshot,
                out.disaster
            );
        }
    }

    function _buildModules(CampaignStack memory out) internal pure returns (IAgriModulesV1.ModulesV1 memory mods) {
        mods.compliance = out.compliance;
        mods.disaster = out.disaster;
        mods.freezeModule = out.freezeModule;
        mods.custody = out.custody;
        mods.trace = out.trace;
        mods.documentRegistry = out.documentRegistry;
        mods.settlementQueue = out.settlementQueue;
        mods.treasury = out.treasury;
        mods.distribution = out.distribution;
        mods.insurance = out.insurance;
    }

    function _applyComplianceExemptions(CampaignStack memory out) internal {
        _exemptIfSet(out.compliance, out.treasury);
        _exemptIfSet(out.compliance, out.fundingManager);
        _exemptIfSet(out.compliance, out.settlementQueue);
        _exemptIfSet(out.compliance, out.distribution);
        _exemptIfSet(out.compliance, out.insurance);
        _exemptIfSet(out.compliance, out.trace);
        _exemptIfSet(out.compliance, out.documentRegistry);
        _exemptIfSet(out.compliance, out.batchAnchor);
    }

    function _cloneOrRevert(address impl, bytes32 salt) internal returns (address instance) {
        if (impl.code.length == 0) revert CampaignFactory__InvalidAddress();
        instance = ClonesLib.cloneDeterministic(impl, salt);
        if (instance == address(0)) revert CampaignFactory__InvalidAddress();
    }

    function _salt(bytes32 campaignId, bytes32 label) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(campaignId, label));
    }

    function _grantIfSet(RoleManager rm, bytes32 role, address account) internal {
        if (account != address(0)) rm.grantRole(role, account);
    }

    function _exemptIfSet(address compliance, address account) internal {
        if (compliance != address(0) && account != address(0)) {
            ComplianceModuleV1(compliance).setExempt(account, true);
        }
    }

    function _validateViewGas(UAgriTypes.ViewGasLimits calldata limits) internal pure {
        bool allZero =
            limits.complianceGas == 0 &&
            limits.disasterGas == 0 &&
            limits.freezeGas == 0 &&
            limits.custodyGas == 0 &&
            limits.extraGas == 0;

        if (!allZero) {
            if (limits.complianceGas == 0 || limits.disasterGas == 0 || limits.freezeGas == 0) {
                revert CampaignFactory__InvalidViewGas();
            }
        }
    }

    function _resolveViewGas(
        UAgriTypes.ViewGasLimits calldata perCampaign,
        UAgriTypes.ViewGasLimits memory templateDefault
    ) internal pure returns (UAgriTypes.ViewGasLimits memory out) {
        bool allZero =
            perCampaign.complianceGas == 0 &&
            perCampaign.disasterGas == 0 &&
            perCampaign.freezeGas == 0 &&
            perCampaign.custodyGas == 0 &&
            perCampaign.extraGas == 0;

        if (!allZero) return perCampaign;
        return templateDefault;
    }
}
