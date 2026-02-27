// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {UAgriTypes} from "../src/interfaces/constants/UAgriTypes.sol";
import {CampaignFactory} from "../src/factory/CampaignFactory.sol";
import {RoleManager} from "../src/access/RoleManager.sol";
import {IdentityAttestation} from "../src/compliance/IdentityAttestation.sol";
import {ComplianceModuleV1} from "../src/compliance/ComplianceModuleV1.sol";

/// @dev Minimal ERC20 mock for dev/local
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "ALLOWANCE");
        if (a != type(uint256).max) {
            allowance[from][msg.sender] = a - amount;
            emit Approval(from, msg.sender, allowance[from][msg.sender]);
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(to != address(0), "TO_ZERO");
        uint256 b = balanceOf[from];
        require(b >= amount, "BALANCE");
        unchecked {
            balanceOf[from] = b - amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
}

contract CreateCampaign is Script {
    struct FeatureFlags {
        bool enableForcedTransfers;
        bool enableCustodyOracle;
        bool enableTrace;
        bool enableDocuments;
        bool enableBatchAnchor;
        bool enableDistribution;
        bool enableInsurance;
    }

    struct EconomicConfig {
        uint16 depositFeeBps;
        uint16 redeemFeeBps;
        address feeRecipient;
        bool enforceComplianceOnPay;
        bool allowDepositsWhenActive;
        bool allowRedeemsDuringFunding;
        bool enforceCustodyFreshOnRedeem;
        bool depositExactSharesMode;
        bool enforceComplianceOnClaim;
    }

    function run() external returns (bytes32 campaignId) {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);
        CampaignFactory factory = CampaignFactory(vm.envAddress("FACTORY"));

        address gov = vm.envOr("GOV", deployer);
        uint256 govPk = vm.envOr("GOV_PRIVATE_KEY", uint256(0));
        if (govPk == 0 && gov == deployer) govPk = deployerPk;

        campaignId = _readBytes32("CAMPAIGN_ID", "CAMPAIGN_ID_STR", "uAgri:DEMO:CAMPAIGN");
        (CampaignFactory.CampaignConfig memory cfg, CampaignFactory.RolesConfig memory roles, bool distributionEnabled) =
            _prepareConfig(campaignId, deployerPk, gov);

        bool beginAdminHandoff = vm.envOr("BEGIN_ROLEMANAGER_ADMIN_HANDOFF", true);
        CampaignFactory.CampaignStack memory out =
            _deployCampaign(factory, cfg, roles, campaignId, deployerPk, gov, beginAdminHandoff);

        if (govPk == 0) {
            console2.log("NOTE: GOV_PRIVATE_KEY missing and GOV != deployer. Run PostDeployCampaign with GOV key.");
            return campaignId;
        }

        _postDeployAsGov(govPk, gov, out, distributionEnabled);
    }

    function _deployCampaign(
        CampaignFactory factory,
        CampaignFactory.CampaignConfig memory cfg,
        CampaignFactory.RolesConfig memory roles,
        bytes32 campaignId,
        uint256 deployerPk,
        address gov,
        bool beginAdminHandoff
    ) internal returns (CampaignFactory.CampaignStack memory out) {
        vm.startBroadcast(deployerPk);

        out = factory.createCampaign(cfg, roles);

        console2.log("==== Campaign deployed ====");
        console2.logBytes32(campaignId);
        console2.log("roleManager:", out.roleManager);
        console2.log("registry:", out.registry);
        console2.log("shareToken:", out.shareToken);
        console2.log("treasury:", out.treasury);
        console2.log("fundingManager:", out.fundingManager);
        console2.log("settlementQueue:", out.settlementQueue);
        console2.log("identityAttestation:", out.identityAttestation);
        console2.log("compliance:", out.compliance);
        console2.log("disaster:", out.disaster);
        console2.log("freezeModule:", out.freezeModule);
        console2.log("forcedTransferController:", out.forcedTransferController);
        console2.log("custody:", out.custody);
        console2.log("trace:", out.trace);
        console2.log("documentRegistry:", out.documentRegistry);
        console2.log("batchAnchor:", out.batchAnchor);
        console2.log("snapshot:", out.snapshot);
        console2.log("distribution:", out.distribution);
        console2.log("insurance:", out.insurance);

        if (beginAdminHandoff) {
            factory.beginRoleManagerAdminHandoff(campaignId, gov);
            console2.log("RoleManager DEFAULT_ADMIN handoff STARTED -> GOV:", gov);
        }

        vm.stopBroadcast();
    }

    function _prepareConfig(bytes32 campaignId, uint256 deployerPk, address gov)
        internal
        returns (
            CampaignFactory.CampaignConfig memory cfg,
            CampaignFactory.RolesConfig memory roles,
            bool distributionEnabled
        )
    {
        bytes32 plotRef = _readBytes32("PLOT_REF", "PLOT_REF_STR", "uAgri:DEMO:PLOT");
        uint8 mockDecimals = uint8(vm.envOr("MOCK_DECIMALS", uint256(6)));
        (address settlementAsset, address rewardToken) = _resolveAssets(deployerPk, gov, mockDecimals);

        FeatureFlags memory flags = _readFeatureFlags();
        EconomicConfig memory econ = _readEconomicConfig(gov);

        require(settlementAsset != address(0), "SETTLEMENT_ASSET_REQUIRED");
        if (flags.enableDistribution) {
            if (rewardToken == address(0)) rewardToken = settlementAsset;
            require(rewardToken == settlementAsset, "REWARD_TOKEN_MUST_EQUAL_SETTLEMENT");
        }

        UAgriTypes.Campaign memory campaign = _buildCampaign(campaignId, plotRef, settlementAsset, mockDecimals);
        roles = _buildRoles(gov);
        cfg = _buildCampaignConfig(campaign, rewardToken, flags, econ);
        distributionEnabled = flags.enableDistribution;
    }

    function _postDeployAsGov(uint256 govPk, address gov, CampaignFactory.CampaignStack memory out, bool distributionEnabled)
        internal
    {
        vm.startBroadcast(govPk);

        if (vm.envOr("ACCEPT_ROLEMANAGER_ADMIN_HANDOFF", true)) {
            RoleManager rmGov = RoleManager(out.roleManager);
            address pending = rmGov.pendingDefaultAdmin();
            uint64 notBefore = rmGov.defaultAdminTransferNotBefore();
            if (pending == gov && block.timestamp >= notBefore) {
                rmGov.acceptDefaultAdminTransfer();
                console2.log("RoleManager DEFAULT_ADMIN handoff ACCEPTED by GOV.");
            }
        }

        if (vm.envOr("OPEN_DEFAULT_PROFILE", false)) {
            ComplianceModuleV1 cm = ComplianceModuleV1(out.compliance);
            ComplianceModuleV1.JurisdictionProfile memory p = ComplianceModuleV1.JurisdictionProfile({
                enabled: true,
                requireIdentity: false,
                allowNoExpiry: true,
                enforceLockupOnTransfer: false,
                sameJurisdictionOnly: false,
                minTier: 0,
                maxTier: 0,
                requiredFlags: 0,
                forbiddenFlags: 0,
                minTtlSeconds: 0,
                maxTransfer: 0
            });
            cm.setProfile(0, p);
            console2.log("Compliance opened for dev (jurisdiction 0 requireIdentity=false).");
        }

        if (vm.envOr("KYC_ENABLED", false)) {
            uint32 providerId = uint32(vm.envOr("KYC_PROVIDER_ID", uint256(1)));
            address signer = vm.envOr("KYC_SIGNER", gov);
            bool enabled = vm.envOr("KYC_SIGNER_ENABLED", true);
            IdentityAttestation(out.identityAttestation).setProvider(providerId, signer, enabled);
            console2.log("Identity provider configured. providerId:", providerId, " signer:", signer);
        }

        if (distributionEnabled && out.distribution != address(0)) {
            console2.log("Distribution enabled. notifyReward ACL is role-based (REWARD_NOTIFIER_ROLE/admin/gov).");
        }

        vm.stopBroadcast();
    }

    function _resolveAssets(uint256 deployerPk, address gov, uint8 mockDecimals)
        internal
        returns (address settlementAsset, address rewardToken)
    {
        bool deployMocks = vm.envOr("DEPLOY_MOCK_ASSETS", false);
        uint256 mockMint = vm.envOr("MOCK_MINT", uint256(10_000_000) * (10 ** uint256(mockDecimals)));

        settlementAsset = vm.envOr("SETTLEMENT_ASSET", address(0));
        rewardToken = vm.envOr("REWARD_TOKEN", address(0));

        if (!deployMocks) return (settlementAsset, rewardToken);

        vm.startBroadcast(deployerPk);

        if (settlementAsset == address(0)) {
            MockERC20 s = new MockERC20("Mock USDC", "mUSDC", mockDecimals);
            s.mint(gov, mockMint);
            settlementAsset = address(s);
            console2.log("Mock settlementAsset:", settlementAsset);
        }

        if (rewardToken == address(0)) {
            rewardToken = settlementAsset;
            console2.log("Mock rewardToken follows settlementAsset:", rewardToken);
        }

        vm.stopBroadcast();
    }

    function _readFeatureFlags() internal view returns (FeatureFlags memory flags) {
        flags.enableForcedTransfers = vm.envOr("ENABLE_FORCED_TRANSFERS", true);
        flags.enableCustodyOracle = vm.envOr("ENABLE_CUSTODY_ORACLE", false);
        flags.enableTrace = vm.envOr("ENABLE_TRACE", true);
        flags.enableDocuments = vm.envOr("ENABLE_DOCUMENTS", true);
        flags.enableBatchAnchor = vm.envOr("ENABLE_BATCH_ANCHOR", false);
        flags.enableDistribution = vm.envOr("ENABLE_DISTRIBUTION", true);
        flags.enableInsurance = vm.envOr("ENABLE_INSURANCE", false);
    }

    function _readEconomicConfig(address gov) internal view returns (EconomicConfig memory econ) {
        econ.depositFeeBps = uint16(vm.envOr("DEPOSIT_FEE_BPS", uint256(0)));
        econ.redeemFeeBps = uint16(vm.envOr("REDEEM_FEE_BPS", uint256(0)));
        econ.feeRecipient = vm.envOr("FEE_RECIPIENT", address(0));
        if (econ.feeRecipient == address(0) && (econ.depositFeeBps != 0 || econ.redeemFeeBps != 0)) {
            econ.feeRecipient = gov;
        }

        econ.enforceComplianceOnPay = vm.envOr("ENFORCE_COMPLIANCE_ON_PAY", false);
        econ.allowDepositsWhenActive = vm.envOr("ALLOW_DEPOSITS_WHEN_ACTIVE", false);
        econ.allowRedeemsDuringFunding = vm.envOr("ALLOW_REDEEMS_DURING_FUNDING", false);
        econ.enforceCustodyFreshOnRedeem = vm.envOr("ENFORCE_CUSTODY_FRESH_ON_REDEEM", false);
        econ.depositExactSharesMode = vm.envOr("DEPOSIT_EXACT_SHARES_MODE", false);
        econ.enforceComplianceOnClaim = vm.envOr("ENFORCE_COMPLIANCE_ON_CLAIM", false);
    }

    function _buildCampaign(bytes32 campaignId, bytes32 plotRef, address settlementAsset, uint8 mockDecimals)
        internal
        view
        returns (UAgriTypes.Campaign memory c)
    {
        uint256 subPlotId = vm.envOr("SUBPLOT_ID", uint256(1));
        uint16 areaBps = uint16(vm.envOr("AREA_BPS", uint256(10_000)));
        uint64 startTs = uint64(vm.envOr("START_TS", uint256(0)));
        uint64 endTs = uint64(vm.envOr("END_TS", uint256(0)));
        uint256 fundingCap = vm.envOr("FUNDING_CAP", uint256(1_000_000) * (10 ** uint256(mockDecimals)));
        bytes32 docsRootHash = _readBytes32("DOCS_ROOT_HASH", "DOCS_ROOT_HASH_STR", "");
        bytes32 jurisdictionProfile = _readBytes32("JURISDICTION_PROFILE", "JURISDICTION_PROFILE_STR", "");

        c = UAgriTypes.Campaign({
            campaignId: campaignId,
            plotRef: plotRef,
            subPlotId: bytes32(subPlotId),
            areaBps: areaBps,
            startTs: startTs,
            endTs: endTs,
            settlementAsset: settlementAsset,
            fundingCap: fundingCap,
            docsRootHash: docsRootHash,
            jurisdictionProfile: jurisdictionProfile,
            state: UAgriTypes.CampaignState.FUNDING
        });
    }

    function _buildRoles(address gov) internal view returns (CampaignFactory.RolesConfig memory roles) {
        roles = CampaignFactory.RolesConfig({
            governance: gov,
            guardian: vm.envOr("GUARDIAN", address(0)),
            treasuryAdmin: vm.envOr("TREASURY_ADMIN", gov),
            complianceOfficer: vm.envOr("COMPLIANCE_OFFICER", gov),
            farmOperator: vm.envOr("FARM_OPERATOR", gov),
            regulatorEnforcer: vm.envOr("REGULATOR_ENFORCER", gov),
            disasterAdmin: vm.envOr("DISASTER_ADMIN", gov),
            oracleUpdater: vm.envOr("ORACLE_UPDATER", gov),
            custodyAttester: vm.envOr("CUSTODY_ATTESTER", gov),
            insuranceAdmin: vm.envOr("INSURANCE_ADMIN", gov),
            onRampOperator: vm.envOr("ONRAMP_OPERATOR", address(0)),
            payoutOperator: vm.envOr("PAYOUT_OPERATOR", address(0)),
            rewardNotifier: vm.envOr("REWARD_NOTIFIER", address(0))
        });
    }

    function _buildCampaignConfig(
        UAgriTypes.Campaign memory campaign,
        address rewardToken,
        FeatureFlags memory flags,
        EconomicConfig memory econ
    ) internal view returns (CampaignFactory.CampaignConfig memory cfg) {
        cfg = CampaignFactory.CampaignConfig({
            campaign: campaign,
            name: vm.envOr("TOKEN_NAME", string("uAgri Demo Campaign")),
            symbol: vm.envOr("TOKEN_SYMBOL", string("uAGRI-DEMO")),
            decimals: uint8(vm.envOr("TOKEN_DECIMALS", uint256(18))),
            enforceComplianceOnPay: econ.enforceComplianceOnPay,
            depositFeeBps: econ.depositFeeBps,
            redeemFeeBps: econ.redeemFeeBps,
            feeRecipient: econ.feeRecipient,
            allowDepositsWhenActive: econ.allowDepositsWhenActive,
            allowRedeemsDuringFunding: econ.allowRedeemsDuringFunding,
            enforceCustodyFreshOnRedeem: econ.enforceCustodyFreshOnRedeem,
            depositExactSharesMode: econ.depositExactSharesMode,
            enableForcedTransfers: flags.enableForcedTransfers,
            enableCustodyOracle: flags.enableCustodyOracle,
            enableTrace: flags.enableTrace,
            enableDocuments: flags.enableDocuments,
            enableBatchAnchor: flags.enableBatchAnchor,
            enableDistribution: flags.enableDistribution,
            rewardToken: rewardToken,
            enforceComplianceOnClaim: econ.enforceComplianceOnClaim,
            enableInsurance: flags.enableInsurance,
            viewGas: _readViewGas()
        });
    }

    function _readViewGas() internal view returns (UAgriTypes.ViewGasLimits memory viewGas) {
        viewGas = UAgriTypes.ViewGasLimits({
            complianceGas: uint32(vm.envOr("VIEW_COMPLIANCE_GAS", uint256(0))),
            disasterGas: uint32(vm.envOr("VIEW_DISASTER_GAS", uint256(0))),
            freezeGas: uint32(vm.envOr("VIEW_FREEZE_GAS", uint256(0))),
            custodyGas: uint32(vm.envOr("VIEW_CUSTODY_GAS", uint256(0))),
            extraGas: uint32(vm.envOr("VIEW_EXTRA_GAS", uint256(0)))
        });
    }

    function _readBytes32(
        string memory directEnv,
        string memory stringEnv,
        string memory fallbackLiteral
    ) internal view returns (bytes32 out) {
        try vm.envBytes32(directEnv) returns (bytes32 v) {
            if (v != bytes32(0)) return v;
        } catch {}
        try vm.envString(stringEnv) returns (string memory s) {
            if (bytes(s).length != 0) return keccak256(bytes(s));
        } catch {}
        if (bytes(fallbackLiteral).length == 0) return bytes32(0);
        return keccak256(bytes(fallbackLiteral));
    }
}
