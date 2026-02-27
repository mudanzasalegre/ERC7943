// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {TwoStepAdmin} from "../_shared/TwoStepAdmin.sol";
import {UAgriTypes} from "../interfaces/constants/UAgriTypes.sol";

/// @title CampaignTemplate
/// @notice Pointer-set for uAgri campaign stack cloning.
/// @dev Holds addresses of implementation contracts (singletons) to clone via EIP-1167.
contract CampaignTemplate is TwoStepAdmin {
    modifier onlyAdmin() {
        _requireAdmin();
        _;
    }

    // --------------------------------- Errors ---------------------------------
    error CampaignTemplate__InvalidImpl(bytes32 which);
    error CampaignTemplate__InvalidViewGas();

    // --------------------------------- Types ----------------------------------
    struct TemplateV1 {
        // Core
        address roleManager;
        address campaignRegistry;
        address shareToken;

        // Campaign system
        address treasury;
        address fundingManager;
        address settlementQueue;

        // Modules (core)
        address identityAttestation;
        address complianceModule;
        address disasterModule;
        address freezeManager;
        address forcedTransferController; // OPTIONAL (can be zero)

        // Trace / audit (OPTIONAL)
        address traceRegistry;
        address documentRegistry;
        address batchMerkleAnchor; // OPTIONAL

        // Distribution / Insurance (OPTIONAL)
        address snapshotModule;
        address yieldAccumulator;
        address insurancePool;
    }

    // -------------------------------- Storage --------------------------------
    TemplateV1 internal _t;
    UAgriTypes.ViewGasLimits public defaultViewGasLimits;

    // --------------------------------- Events --------------------------------
    event TemplateUpdated(TemplateV1 template);
    event DefaultViewGasLimitsUpdated(UAgriTypes.ViewGasLimits limits);

    // ------------------------------ Constructor -------------------------------
    constructor(
        address admin_,
        TemplateV1 memory template_,
        UAgriTypes.ViewGasLimits memory defaultGas_
    ) TwoStepAdmin(admin_) {
        _setTemplate(template_);
        _setDefaultViewGas(defaultGas_);
    }

    // --------------------------------- Views ---------------------------------
    function getTemplateV1() external view returns (TemplateV1 memory) {
        return _t;
    }

    function getDefaultViewGasLimits() external view returns (UAgriTypes.ViewGasLimits memory) {
        return defaultViewGasLimits;
    }

    // ------------------------------ Admin ops ---------------------------------
    function setTemplate(TemplateV1 calldata template_) external onlyAdmin {
        _setTemplate(template_);
    }

    function setDefaultViewGasLimits(UAgriTypes.ViewGasLimits calldata limits) external onlyAdmin {
        _setDefaultViewGas(limits);
    }

    // -------------------------------- Internals ------------------------------
    function _setDefaultViewGas(UAgriTypes.ViewGasLimits memory limits) internal {
        bool allZero =
            limits.complianceGas == 0 &&
            limits.disasterGas == 0 &&
            limits.freezeGas == 0 &&
            limits.custodyGas == 0 &&
            limits.extraGas == 0;

        if (!allZero) {
            if (limits.complianceGas == 0 || limits.disasterGas == 0 || limits.freezeGas == 0) {
                revert CampaignTemplate__InvalidViewGas();
            }
        }

        defaultViewGasLimits = limits;
        emit DefaultViewGasLimitsUpdated(limits);
    }

    function _setTemplate(TemplateV1 memory t) internal {
        _requireImpl(t.roleManager, keccak256("ROLE_MANAGER"));
        _requireImpl(t.campaignRegistry, keccak256("CAMPAIGN_REGISTRY"));
        _requireImpl(t.shareToken, keccak256("SHARE_TOKEN"));

        _requireImpl(t.treasury, keccak256("TREASURY"));
        _requireImpl(t.fundingManager, keccak256("FUNDING_MANAGER"));
        _requireImpl(t.settlementQueue, keccak256("SETTLEMENT_QUEUE"));

        _requireImpl(t.identityAttestation, keccak256("IDENTITY_ATTESTATION"));
        _requireImpl(t.complianceModule, keccak256("COMPLIANCE_MODULE"));
        _requireImpl(t.disasterModule, keccak256("DISASTER_MODULE"));
        _requireImpl(t.freezeManager, keccak256("FREEZE_MANAGER"));

        if (t.forcedTransferController != address(0)) _requireImpl(t.forcedTransferController, keccak256("FORCED_TRANSFER"));
        if (t.traceRegistry != address(0)) _requireImpl(t.traceRegistry, keccak256("TRACE_REGISTRY"));
        if (t.documentRegistry != address(0)) _requireImpl(t.documentRegistry, keccak256("DOC_REGISTRY"));
        if (t.batchMerkleAnchor != address(0)) _requireImpl(t.batchMerkleAnchor, keccak256("BATCH_ANCHOR"));

        if (t.snapshotModule != address(0)) _requireImpl(t.snapshotModule, keccak256("SNAPSHOT_MODULE"));
        if (t.yieldAccumulator != address(0)) _requireImpl(t.yieldAccumulator, keccak256("YIELD_ACCUMULATOR"));
        if (t.insurancePool != address(0)) _requireImpl(t.insurancePool, keccak256("INSURANCE_POOL"));

        _t = t;
        emit TemplateUpdated(t);
    }

    function _requireImpl(address impl, bytes32 which) private view {
        if (impl.code.length == 0) revert CampaignTemplate__InvalidImpl(which);
    }
}
