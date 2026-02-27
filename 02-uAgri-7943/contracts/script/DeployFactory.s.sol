// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {UAgriTypes} from "../src/interfaces/constants/UAgriTypes.sol";
import {IAgriModulesV1} from "../src/interfaces/v1/IAgriModulesV1.sol";

import {CampaignTemplate} from "../src/factory/CampaignTemplate.sol";
import {CampaignFactory} from "../src/factory/CampaignFactory.sol";

// Implementations (used by the template for clones)
import {RoleManager} from "../src/access/RoleManager.sol";
import {AgriCampaignRegistry} from "../src/campaign/AgriCampaignRegistry.sol";
import {AgriShareToken} from "../src/core/AgriShareToken.sol";
import {CampaignTreasury} from "../src/campaign/CampaignTreasury.sol";
import {FundingManager} from "../src/campaign/FundingManager.sol";
import {SettlementQueue} from "../src/campaign/SettlementQueue.sol";

import {IdentityAttestation} from "../src/compliance/IdentityAttestation.sol";
import {ComplianceModuleV1} from "../src/compliance/ComplianceModuleV1.sol";

import {DisasterModule} from "../src/disaster/DisasterModule.sol";
import {InsurancePool} from "../src/disaster/InsurancePool.sol";

import {FreezeManager} from "../src/control/FreezeManager.sol";
import {ForcedTransferController} from "../src/control/ForcedTransferController.sol";

import {TraceabilityRegistry} from "../src/trace/TraceabilityRegistry.sol";
import {DocumentRegistry} from "../src/trace/DocumentRegistry.sol";
import {BatchMerkleAnchor} from "../src/trace/BatchMerkleAnchor.sol";

import {SnapshotModule} from "../src/distribution/SnapshotModule.sol";
import {YieldAccumulator} from "../src/distribution/YieldAccumulator.sol";

/// @dev Minimal share-token stub used only while deploying implementation contracts.
/// It satisfies constructor-time view calls made by modules (roleManager/campaignId/treasury/decimals).
contract ImplShareTokenStub {
    address public roleManager;
    bytes32 public campaignId;
    address public treasury;
    uint8 public decimals;

    constructor(address roleManager_, bytes32 campaignId_, uint8 decimals_) {
        roleManager = roleManager_;
        campaignId = campaignId_;
        decimals = decimals_;
    }

    function setTreasury(address treasury_) external {
        treasury = treasury_;
    }
}

/// @dev Minimal ERC20-like stub used as settlement/reward token for implementation constructors.
contract ImplERC20Stub {
    uint8 public immutable decimals;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }
}

/// @notice Deploys the full Profile-D baseline:
/// - all implementation contracts (for clones)
/// - CampaignTemplate (points to implementations + default view gas limits)
/// - CampaignFactory (points to template)
///
/// Usage:
/// forge script script/DeployFactory.s.sol:DeployFactory \
///   --rpc-url $RPC_URL --broadcast --private-key $PRIVATE_KEY -vvvv
///
/// Optional env:
/// - ADMIN                          (address) if you want a different TwoStepAdmin than the deployer
/// - DEFAULT_VIEW_*_GAS             (uint) to set template defaults (otherwise safe defaults)
contract DeployFactory is Script {
    function run() external returns (address template, address factory) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address admin = vm.envOr("ADMIN", deployer);

        // Conservative defaults (bounded staticcalls)
        UAgriTypes.ViewGasLimits memory defaultGas = UAgriTypes.ViewGasLimits({
            complianceGas: uint32(vm.envOr("DEFAULT_VIEW_COMPLIANCE_GAS", uint256(100_000))),
            disasterGas:   uint32(vm.envOr("DEFAULT_VIEW_DISASTER_GAS",   uint256(80_000))),
            freezeGas:     uint32(vm.envOr("DEFAULT_VIEW_FREEZE_GAS",     uint256(80_000))),
            custodyGas:    uint32(vm.envOr("DEFAULT_VIEW_CUSTODY_GAS",    uint256(80_000))),
            extraGas:      uint32(vm.envOr("DEFAULT_VIEW_EXTRA_GAS",      uint256(40_000)))
        });

        // Dummy values for implementation deployments (constructor storage irrelevant for clones)
        bytes32 DUMMY_CID  = keccak256("uAgri:IMPL");
        address DUMMY_ERC20;
        ImplShareTokenStub shareStub;

        vm.startBroadcast(pk);

        // Template struct (one pointer in stack; we fill addresses progressively)
        CampaignTemplate.TemplateV1 memory t;

        // RoleManager: constructor REQUIRES initialDefaultAdmin
        address rm = address(new RoleManager(admin));
        t.roleManager = rm;
        console2.log("RoleManager impl:", rm);

        // Some implementation constructors read roleManager/campaignId/treasury from shareToken.
        shareStub = new ImplShareTokenStub(rm, DUMMY_CID, 18);
        address DUMMY_TOKEN = address(shareStub);
        DUMMY_ERC20 = address(new ImplERC20Stub(6));

        t.campaignRegistry = address(new AgriCampaignRegistry(rm));
        console2.log("AgriCampaignRegistry impl:", t.campaignRegistry);

        t.freezeManager = address(new FreezeManager(rm, address(0)));
        console2.log("FreezeManager impl:", t.freezeManager);

        t.forcedTransferController = address(
            new ForcedTransferController(rm, t.freezeManager, address(0), false)
        );
        console2.log("ForcedTransferController impl:", t.forcedTransferController);

        t.disasterModule = address(new DisasterModule(rm));
        console2.log("DisasterModule impl:", t.disasterModule);

        t.identityAttestation = address(new IdentityAttestation(rm));
        console2.log("IdentityAttestation impl:", t.identityAttestation);

        t.complianceModule = address(new ComplianceModuleV1(rm, t.identityAttestation));
        console2.log("ComplianceModuleV1 impl:", t.complianceModule);

        t.snapshotModule = address(new SnapshotModule(rm, DUMMY_TOKEN));
        console2.log("SnapshotModule impl:", t.snapshotModule);

        t.yieldAccumulator = address(new YieldAccumulator(rm, DUMMY_TOKEN, DUMMY_ERC20, false));
        console2.log("YieldAccumulator impl:", t.yieldAccumulator);

        t.insurancePool = address(
            new InsurancePool(rm, DUMMY_CID, DUMMY_ERC20, t.snapshotModule, t.disasterModule)
        );
        console2.log("InsurancePool impl:", t.insurancePool);

        t.traceRegistry = address(new TraceabilityRegistry(rm));
        console2.log("TraceabilityRegistry impl:", t.traceRegistry);

        t.documentRegistry = address(new DocumentRegistry(rm));
        console2.log("DocumentRegistry impl:", t.documentRegistry);

        t.batchMerkleAnchor = address(new BatchMerkleAnchor(rm));
        console2.log("BatchMerkleAnchor impl:", t.batchMerkleAnchor);

        t.treasury = address(
            new CampaignTreasury(rm, DUMMY_CID, DUMMY_TOKEN, DUMMY_ERC20, address(0), false)
        );
        shareStub.setTreasury(t.treasury);
        console2.log("CampaignTreasury impl:", t.treasury);

        t.fundingManager = address(
            new FundingManager(
                rm,
                DUMMY_CID,
                DUMMY_TOKEN,
                t.campaignRegistry,
                address(0),
                0,
                0,
                address(0),
                false,
                false,
                false
            )
        );
        console2.log("FundingManager impl:", t.fundingManager);

        t.settlementQueue = address(new SettlementQueue(rm, DUMMY_CID, t.fundingManager, false));
        console2.log("SettlementQueue impl:", t.settlementQueue);

        // Share token impl requires compliance+disaster+freeze != 0 AND a non-zero forcedTransferController.
        IAgriModulesV1.ModulesV1 memory mods = IAgriModulesV1.ModulesV1({
            compliance: t.complianceModule,
            disaster: t.disasterModule,
            freezeModule: t.freezeManager,
            custody: address(0),

            trace: address(0),
            documentRegistry: address(0),

            settlementQueue: address(0),
            treasury: address(0),
            distribution: address(0),

            bridge: address(0),
            marketplace: address(0),
            delivery: address(0),
            insurance: address(0)
        });

        t.shareToken = address(
            new AgriShareToken(
                rm,
                DUMMY_CID,
                "uAgri ShareToken (impl)",
                "uAGRI-IMPL",
                18,
                mods,
                t.forcedTransferController,
                defaultGas
            )
        );
        console2.log("AgriShareToken impl:", t.shareToken);

        CampaignTemplate tpl = new CampaignTemplate(admin, t, defaultGas);
        template = address(tpl);
        console2.log("CampaignTemplate:", template);

        CampaignFactory fac = new CampaignFactory(admin, template);
        factory = address(fac);
        console2.log("CampaignFactory:", factory);

        vm.stopBroadcast();

        console2.log("DONE. chainid:", block.chainid);
        console2.log("Admin:", admin);
    }
}
