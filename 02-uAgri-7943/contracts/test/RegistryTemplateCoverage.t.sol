// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";

import {RoleManager} from "src/access/RoleManager.sol";
import {AgriCampaignRegistry} from "src/campaign/AgriCampaignRegistry.sol";
import {CampaignTemplate} from "src/factory/CampaignTemplate.sol";

import {UAgriTypes} from "src/interfaces/constants/UAgriTypes.sol";
import {UAgriRoles} from "src/interfaces/constants/UAgriRoles.sol";

contract CovTemplateImpl {}

contract AgriCampaignRegistryCoverageTest is Test {
    RoleManager internal rm;
    AgriCampaignRegistry internal registry;

    address internal operator = makeAddr("operator");
    address internal complianceOfficer = makeAddr("compliance-officer");
    address internal outsider = makeAddr("outsider");

    function setUp() public {
        rm = new RoleManager(address(this));
        rm.grantRole(UAgriRoles.FARM_OPERATOR_ROLE, operator);
        rm.grantRole(UAgriRoles.COMPLIANCE_OFFICER_ROLE, complianceOfficer);
        registry = new AgriCampaignRegistry(address(rm));
    }

    function testRegistryCreateViewsRoleManagerAndInitGuards() public {
        vm.expectRevert(AgriCampaignRegistry.AgriCampaignRegistry__AlreadyInitialized.selector);
        registry.initialize(address(rm));

        vm.prank(outsider);
        vm.expectRevert(AgriCampaignRegistry.AgriCampaignRegistry__Unauthorized.selector);
        registry.createCampaign(_campaign(bytes32(uint256(1)), 100, 200));

        vm.expectRevert(AgriCampaignRegistry.AgriCampaignRegistry__InvalidCampaignId.selector);
        registry.createCampaign(_campaign(bytes32(0), 100, 200));

        vm.expectRevert(abi.encodeWithSelector(AgriCampaignRegistry.AgriCampaignRegistry__InvalidTiming.selector, uint64(200), uint64(100)));
        registry.createCampaign(_campaign(bytes32(uint256(2)), 200, 100));

        bytes32 id = keccak256("reg:campaign:1");
        registry.createCampaign(_campaign(id, 100, 200));

        assertTrue(registry.exists(id));
        assertEq(registry.campaignCount(), 1);
        assertEq(registry.campaignIdAt(0), id);
        assertEq(uint256(registry.state(id)), uint256(UAgriTypes.CampaignState.FUNDING));

        UAgriTypes.Campaign memory c = registry.getCampaign(id);
        assertEq(c.campaignId, id);
        assertEq(c.startTs, 100);
        assertEq(c.endTs, 200);

        vm.expectRevert(abi.encodeWithSelector(AgriCampaignRegistry.AgriCampaignRegistry__CampaignExists.selector, id));
        registry.createCampaign(_campaign(id, 100, 200));

        bytes32 unknown = keccak256("reg:missing");
        vm.expectRevert(abi.encodeWithSelector(AgriCampaignRegistry.AgriCampaignRegistry__CampaignNotFound.selector, unknown));
        registry.getCampaign(unknown);
        vm.expectRevert(abi.encodeWithSelector(AgriCampaignRegistry.AgriCampaignRegistry__CampaignNotFound.selector, unknown));
        registry.state(unknown);

        vm.prank(outsider);
        vm.expectRevert(AgriCampaignRegistry.AgriCampaignRegistry__Unauthorized.selector);
        registry.setRoleManager(address(rm));

        vm.expectRevert(AgriCampaignRegistry.AgriCampaignRegistry__InvalidRoleManager.selector);
        registry.setRoleManager(address(0));

        RoleManager rm2 = new RoleManager(address(this));
        registry.setRoleManager(address(rm2));
        assertEq(address(registry.roleManager()), address(rm2));
    }

    function testRegistryEditsLifecycleAndRolePaths() public {
        bytes32 id = keccak256("reg:campaign:2");
        registry.createCampaign(_campaign(id, 10, 20));

        vm.prank(outsider);
        vm.expectRevert(AgriCampaignRegistry.AgriCampaignRegistry__Unauthorized.selector);
        registry.setCampaignState(id, UAgriTypes.CampaignState.ACTIVE);

        vm.prank(outsider);
        vm.expectRevert(AgriCampaignRegistry.AgriCampaignRegistry__Unauthorized.selector);
        registry.setDocsRootHash(id, keccak256("docs"));

        vm.prank(outsider);
        vm.expectRevert(AgriCampaignRegistry.AgriCampaignRegistry__Unauthorized.selector);
        registry.setJurisdictionProfile(id, keccak256("profile"));

        vm.prank(operator);
        registry.setDocsRootHash(id, keccak256("docs-v1"));
        vm.prank(operator);
        registry.setDocsRootHash(id, keccak256("docs-v1")); // idempotent

        vm.prank(complianceOfficer);
        registry.setJurisdictionProfile(id, keccak256("profile-v1"));
        vm.prank(complianceOfficer);
        registry.setJurisdictionProfile(id, keccak256("profile-v1")); // idempotent

        registry.setFundingCap(id, 10_000);
        registry.setFundingCap(id, 10_000); // idempotent

        registry.setTiming(id, 11, 22);
        registry.setTiming(id, 11, 22); // idempotent

        vm.expectRevert(abi.encodeWithSelector(AgriCampaignRegistry.AgriCampaignRegistry__InvalidTiming.selector, uint64(30), uint64(20)));
        registry.setTiming(id, 30, 20);

        registry.setCampaignState(id, UAgriTypes.CampaignState.FUNDING); // idempotent
        registry.setCampaignState(id, UAgriTypes.CampaignState.ACTIVE);

        vm.expectRevert(
            abi.encodeWithSelector(
                AgriCampaignRegistry.AgriCampaignRegistry__OnlyEditableInFunding.selector, UAgriTypes.CampaignState.ACTIVE
            )
        );
        registry.setFundingCap(id, 20_000);

        vm.expectRevert(
            abi.encodeWithSelector(
                AgriCampaignRegistry.AgriCampaignRegistry__OnlyEditableInFunding.selector, UAgriTypes.CampaignState.ACTIVE
            )
        );
        registry.setTiming(id, 40, 50);

        vm.expectRevert(
            abi.encodeWithSelector(
                AgriCampaignRegistry.AgriCampaignRegistry__InvalidStateTransition.selector,
                UAgriTypes.CampaignState.ACTIVE,
                UAgriTypes.CampaignState.FUNDING
            )
        );
        registry.setCampaignState(id, UAgriTypes.CampaignState.FUNDING);

        registry.setCampaignState(id, UAgriTypes.CampaignState.HARVESTED);
        registry.setCampaignState(id, UAgriTypes.CampaignState.SETTLED);
        registry.setCampaignState(id, UAgriTypes.CampaignState.CLOSED);

        vm.expectRevert(
            abi.encodeWithSelector(
                AgriCampaignRegistry.AgriCampaignRegistry__InvalidStateTransition.selector,
                UAgriTypes.CampaignState.CLOSED,
                UAgriTypes.CampaignState.ACTIVE
            )
        );
        registry.setCampaignState(id, UAgriTypes.CampaignState.ACTIVE);
    }

    function _campaign(bytes32 id, uint64 startTs, uint64 endTs) internal pure returns (UAgriTypes.Campaign memory c) {
        c = UAgriTypes.Campaign({
            campaignId: id,
            plotRef: keccak256("plot"),
            subPlotId: keccak256("subplot"),
            areaBps: 10_000,
            startTs: startTs,
            endTs: endTs,
            settlementAsset: address(0xBEEF),
            fundingCap: 1_000_000,
            docsRootHash: bytes32(0),
            jurisdictionProfile: bytes32(0),
            state: UAgriTypes.CampaignState.CLOSED
        });
    }
}

contract CampaignTemplateCoverageTest is Test {
    CampaignTemplate internal template;
    CovTemplateImpl internal impl;

    address internal outsider = makeAddr("outsider");

    function setUp() public {
        impl = new CovTemplateImpl();
        template = new CampaignTemplate(address(this), _template(address(impl), false), UAgriTypes.ViewGasLimits(0, 0, 0, 0, 0));
    }

    function testTemplateViewsAndAdminSettersAndValidation() public {
        CampaignTemplate.TemplateV1 memory t0 = template.getTemplateV1();
        assertEq(t0.roleManager, address(impl));
        assertEq(t0.shareToken, address(impl));

        UAgriTypes.ViewGasLimits memory g0 = template.getDefaultViewGasLimits();
        assertEq(g0.complianceGas, 0);
        assertEq(g0.disasterGas, 0);
        assertEq(g0.freezeGas, 0);

        vm.prank(outsider);
        vm.expectRevert();
        template.setTemplate(_template(address(impl), false));

        vm.prank(outsider);
        vm.expectRevert();
        template.setDefaultViewGasLimits(UAgriTypes.ViewGasLimits(1, 1, 1, 1, 1));

        vm.expectRevert(CampaignTemplate.CampaignTemplate__InvalidViewGas.selector);
        template.setDefaultViewGasLimits(UAgriTypes.ViewGasLimits(0, 1, 1, 1, 1));

        template.setDefaultViewGasLimits(UAgriTypes.ViewGasLimits(10, 20, 30, 0, 0));
        UAgriTypes.ViewGasLimits memory g1 = template.getDefaultViewGasLimits();
        assertEq(g1.complianceGas, 10);
        assertEq(g1.disasterGas, 20);
        assertEq(g1.freezeGas, 30);

        template.setDefaultViewGasLimits(UAgriTypes.ViewGasLimits(0, 0, 0, 0, 0));
        UAgriTypes.ViewGasLimits memory g2 = template.getDefaultViewGasLimits();
        assertEq(g2.complianceGas, 0);
        assertEq(g2.disasterGas, 0);
        assertEq(g2.freezeGas, 0);

        CampaignTemplate.TemplateV1 memory bad = _template(address(impl), false);
        bad.roleManager = address(0);
        vm.expectRevert();
        template.setTemplate(bad);

        CampaignTemplate.TemplateV1 memory full = _template(address(impl), true);
        template.setTemplate(full);
        CampaignTemplate.TemplateV1 memory got = template.getTemplateV1();
        assertEq(got.snapshotModule, address(impl));
        assertEq(got.insurancePool, address(impl));
    }

    function _template(address implAddr, bool includeOptional) internal pure returns (CampaignTemplate.TemplateV1 memory t) {
        t.roleManager = implAddr;
        t.campaignRegistry = implAddr;
        t.shareToken = implAddr;
        t.treasury = implAddr;
        t.fundingManager = implAddr;
        t.settlementQueue = implAddr;
        t.identityAttestation = implAddr;
        t.complianceModule = implAddr;
        t.disasterModule = implAddr;
        t.freezeManager = implAddr;

        if (includeOptional) {
            t.forcedTransferController = implAddr;
            t.traceRegistry = implAddr;
            t.documentRegistry = implAddr;
            t.batchMerkleAnchor = implAddr;
            t.snapshotModule = implAddr;
            t.yieldAccumulator = implAddr;
            t.insurancePool = implAddr;
        }
    }
}
