// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";

import {RoleManager} from "src/access/RoleManager.sol";
import {FreezeManager} from "src/control/FreezeManager.sol";
import {EmergencyPause} from "src/control/EmergencyPause.sol";
import {EUProfileEUDRCompliance} from "src/compliance/profiles/EUProfileEUDRCompliance.sol";
import {ComplianceModuleV1} from "src/compliance/ComplianceModuleV1.sol";

import {UAgriRoles} from "src/interfaces/constants/UAgriRoles.sol";
import {UAgriFlags} from "src/interfaces/constants/UAgriFlags.sol";
import {UAgriHazards} from "src/interfaces/constants/UAgriHazards.sol";

import {ClonesLib} from "src/factory/ClonesLib.sol";

contract CloneDeployer {
    function clone(address implementation) external returns (address) {
        return ClonesLib.clone(implementation);
    }
}

contract RoleManagerTest is Test {
    RoleManager internal rm;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        rm = new RoleManager(address(this));
    }

    function testGrantRevokeRenounceAndEnumeration() public {
        rm.grantRole(UAgriRoles.GOVERNANCE_ROLE, alice);

        assertTrue(rm.hasRole(UAgriRoles.GOVERNANCE_ROLE, alice));
        assertEq(rm.roleMemberCount(UAgriRoles.GOVERNANCE_ROLE), 1);
        assertEq(rm.roleMember(UAgriRoles.GOVERNANCE_ROLE, 0), alice);

        vm.prank(alice);
        rm.renounceRole(UAgriRoles.GOVERNANCE_ROLE);

        assertFalse(rm.hasRole(UAgriRoles.GOVERNANCE_ROLE, alice));
        assertEq(rm.roleMemberCount(UAgriRoles.GOVERNANCE_ROLE), 0);

        vm.expectRevert();
        rm.roleMember(UAgriRoles.GOVERNANCE_ROLE, 0);
    }

    function testPendingGrantAcceptDeclineAndCancel() public {
        rm.setRoleGrantAcceptanceRequired(UAgriRoles.GUARDIAN_ROLE, true);

        rm.grantRole(UAgriRoles.GUARDIAN_ROLE, alice);
        assertTrue(rm.isPendingRoleGrant(UAgriRoles.GUARDIAN_ROLE, alice));

        vm.prank(alice);
        rm.acceptRole(UAgriRoles.GUARDIAN_ROLE);
        assertTrue(rm.hasRole(UAgriRoles.GUARDIAN_ROLE, alice));

        rm.grantRole(UAgriRoles.GUARDIAN_ROLE, bob);
        assertTrue(rm.isPendingRoleGrant(UAgriRoles.GUARDIAN_ROLE, bob));

        vm.prank(bob);
        rm.declineRole(UAgriRoles.GUARDIAN_ROLE);
        assertFalse(rm.isPendingRoleGrant(UAgriRoles.GUARDIAN_ROLE, bob));

        rm.grantRole(UAgriRoles.GUARDIAN_ROLE, bob);
        rm.cancelRoleGrant(UAgriRoles.GUARDIAN_ROLE, bob);

        vm.expectRevert();
        rm.cancelRoleGrant(UAgriRoles.GUARDIAN_ROLE, bob);
    }

    function testDefaultAdminTransferDelayAndCancel() public {
        rm.setDefaultAdminTransferDelay(1 days);
        rm.beginDefaultAdminTransfer(alice);

        vm.prank(bob);
        vm.expectRevert();
        rm.acceptDefaultAdminTransfer();

        vm.prank(alice);
        vm.expectRevert();
        rm.acceptDefaultAdminTransfer();

        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        rm.acceptDefaultAdminTransfer();

        assertTrue(rm.hasRole(UAgriRoles.DEFAULT_ADMIN_ROLE, alice));

        vm.prank(alice);
        rm.beginDefaultAdminTransfer(bob);

        vm.prank(alice);
        rm.cancelDefaultAdminTransfer();
    }

    function testRoleAdminProposalFlow() public {
        rm.proposeRoleAdmin(UAgriRoles.GOVERNANCE_ROLE, UAgriRoles.GUARDIAN_ROLE);
        rm.acceptRoleAdmin(UAgriRoles.GOVERNANCE_ROLE);

        vm.expectRevert();
        rm.grantRole(UAgriRoles.GOVERNANCE_ROLE, alice);

        rm.grantRole(UAgriRoles.GUARDIAN_ROLE, address(this));
        rm.grantRole(UAgriRoles.GOVERNANCE_ROLE, alice);
        assertTrue(rm.hasRole(UAgriRoles.GOVERNANCE_ROLE, alice));

        rm.proposeRoleAdmin(UAgriRoles.ORACLE_UPDATER_ROLE, UAgriRoles.TREASURY_ADMIN_ROLE);
        rm.cancelRoleAdminProposal(UAgriRoles.ORACLE_UPDATER_ROLE);
    }

    function testSingleDefaultAdminEnforcementToggle() public {
        vm.expectRevert();
        rm.grantRole(UAgriRoles.DEFAULT_ADMIN_ROLE, alice);

        rm.setSingleDefaultAdminEnforcement(false);
        rm.grantRole(UAgriRoles.DEFAULT_ADMIN_ROLE, alice);

        assertTrue(rm.hasRole(UAgriRoles.DEFAULT_ADMIN_ROLE, alice));

        rm.revokeRole(UAgriRoles.DEFAULT_ADMIN_ROLE, alice);
        assertFalse(rm.hasRole(UAgriRoles.DEFAULT_ADMIN_ROLE, alice));
    }
}

contract FreezeAndEmergencyTest is Test {
    RoleManager internal rm;
    FreezeManager internal freeze;
    EmergencyPause internal pause;

    bytes32 internal campaignId = keccak256("pause-campaign");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        rm = new RoleManager(address(this));
        freeze = new FreezeManager(address(rm), address(0));
        pause = new EmergencyPause(address(rm), campaignId, UAgriFlags.PAUSE_FUNDING);

        rm.grantRole(UAgriRoles.REGULATOR_ENFORCER_ROLE, alice);
        rm.grantRole(UAgriRoles.GUARDIAN_ROLE, alice);
    }

    function testFreezeAdminAndTokenOnlyEntrypoints() public {
        freeze.setToken(bob);

        vm.prank(alice);
        freeze.setFrozenTokens(alice, 100);
        assertEq(freeze.getFrozenTokens(alice), 100);

        vm.prank(alice);
        freeze.increaseFrozen(alice, 50);
        assertEq(freeze.getFrozenTokens(alice), 150);

        vm.prank(alice);
        freeze.decreaseFrozen(alice, 25);
        assertEq(freeze.getFrozenTokens(alice), 125);

        vm.prank(bob);
        freeze.setFrozenTokensFromToken(alice, 77);
        assertEq(freeze.getFrozenTokens(alice), 77);

        address[] memory accts = new address[](2);
        uint256[] memory amts = new uint256[](2);
        accts[0] = alice;
        accts[1] = bob;
        amts[0] = 1;
        amts[1] = 2;

        vm.prank(bob);
        freeze.setFrozenTokensBatchFromToken(accts, amts);

        vm.prank(makeAddr("not-token"));
        vm.expectRevert();
        freeze.setFrozenTokensFromToken(alice, 1);

        vm.prank(makeAddr("outsider"));
        vm.expectRevert();
        freeze.setFrozenTokens(alice, 1);
    }

    function testFreezeBatchGuardsAndInitGuard() public {
        address[] memory accts = new address[](1);
        uint256[] memory amts = new uint256[](2);
        accts[0] = alice;
        amts[0] = 1;
        amts[1] = 2;

        vm.prank(alice);
        vm.expectRevert();
        freeze.setFrozenTokensBatch(accts, amts);

        vm.expectRevert();
        freeze.initialize(address(rm), address(0));
    }

    function testEmergencyPauseFlagsAndViews() public {
        assertTrue(pause.fundingPaused());
        assertEq(pause.campaignFlags(campaignId), UAgriFlags.PAUSE_FUNDING);

        bytes32 wrongCampaign = keccak256("wrong");
        uint256 all =
            UAgriFlags.PAUSE_TRANSFERS |
            UAgriFlags.PAUSE_FUNDING |
            UAgriFlags.PAUSE_REDEMPTIONS |
            UAgriFlags.PAUSE_CLAIMS |
            UAgriFlags.PAUSE_ORACLES;

        assertEq(pause.campaignFlags(wrongCampaign), all);
        assertTrue(pause.isRestricted(wrongCampaign));
        assertTrue(pause.isHardFrozen(wrongCampaign));

        pause.pauseTransfers(true);
        pause.pauseRedemptions(true);
        pause.pauseClaims(true);
        pause.pauseOracleUpdates(true);

        assertTrue(pause.transfersPaused());
        assertTrue(pause.redemptionsPaused());
        assertTrue(pause.claimsPaused());
        assertTrue(pause.oraclesPaused());

        pause.setPaused(UAgriFlags.PAUSE_TRANSFERS | UAgriFlags.PAUSE_FUNDING, false);
        assertFalse(pause.transfersPaused());
        assertFalse(pause.fundingPaused());

        vm.prank(bob);
        vm.expectRevert();
        pause.setFlags(UAgriFlags.PAUSE_FUNDING);

        vm.expectRevert();
        pause.setFlags(type(uint256).max);
    }

    function testEmergencyPauseCloneInitializeWithCampaign() public {
        EmergencyPause impl = new EmergencyPause(address(rm), bytes32(0), 0);
        CloneDeployer cloneDeployer = new CloneDeployer();

        address cloneAddr = cloneDeployer.clone(address(impl));
        EmergencyPause clone = EmergencyPause(cloneAddr);

        clone.initializeWithCampaign(address(rm), campaignId, UAgriFlags.PAUSE_TRANSFERS);
        assertEq(clone.campaignFlags(campaignId), UAgriFlags.PAUSE_TRANSFERS);

        vm.expectRevert();
        clone.initialize(address(rm), 0);
    }
}

contract EUProfileTest is Test {
    RoleManager internal rm;
    EUProfileEUDRCompliance internal eu;

    address internal bob = makeAddr("bob");

    function setUp() public {
        rm = new RoleManager(address(this));
        eu = new EUProfileEUDRCompliance(address(rm));
    }

    function testInitGuardsAndDefaults() public {
        vm.expectRevert();
        new EUProfileEUDRCompliance(address(0));

        vm.expectRevert();
        eu.initialize(address(rm));

        assertTrue(eu.isEUJurisdiction(34));
        assertTrue(eu.defaultEUProfile().requireIdentity);
        assertEq(eu.defaultEUProfile().minTier, 2);

        assertTrue(eu.defaultNonEUProfile().allowNoExpiry);
        assertEq(eu.defaultNonEUProfile().minTier, 1);
    }

    function testTierHazardOverridesAndDerivation() public {
        EUProfileEUDRCompliance.TierRule memory tr = EUProfileEUDRCompliance.TierRule({
            enabled: true,
            minTtlSeconds: 5 days,
            maxTransfer: 1_000,
            requiredFlags: 4,
            forbiddenFlags: 8
        });
        eu.setTierRule(2, tr);

        EUProfileEUDRCompliance.HazardRule memory hr = EUProfileEUDRCompliance.HazardRule({
            enabled: true,
            minTierFloor: 3,
            requiredFlags: 16,
            forbiddenFlags: 32,
            sameJurisdictionOnly: true,
            enforceLockupOnTransfer: true,
            maxTransferCap: 700
        });
        eu.setHazardRule(UAgriHazards.FRAUD_OR_MATERIAL_BREACH, hr);

        ComplianceModuleV1.JurisdictionProfile memory p = eu.deriveProfile(34, 2, UAgriHazards.FRAUD_OR_MATERIAL_BREACH);
        assertEq(p.minTier, 3);
        assertEq(p.maxTransfer, 700);
        assertTrue(p.sameJurisdictionOnly);
        assertTrue(p.enforceLockupOnTransfer);
        assertEq(p.requiredFlags, 20);
        assertEq(p.forbiddenFlags, 40);
        assertEq(p.minTtlSeconds, 30 days);

        ComplianceModuleV1.JurisdictionProfile memory overrideProfile = ComplianceModuleV1.JurisdictionProfile({
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

        eu.setJurisdictionOverride(999, overrideProfile);
        ComplianceModuleV1.JurisdictionProfile memory derived = eu.deriveProfile(999, 0, bytes32(0));
        assertFalse(derived.requireIdentity);
    }

    function testBatchOpsPresetAndAuthGuards() public {
        uint16[] memory jurisdictions = new uint16[](2);
        jurisdictions[0] = 34;
        jurisdictions[1] = 33;

        ComplianceModuleV1.JurisdictionProfile[] memory profiles = new ComplianceModuleV1.JurisdictionProfile[](2);
        profiles[0] = eu.defaultEUProfile();
        profiles[1] = eu.defaultEUProfile();

        eu.setEUJurisdictions(jurisdictions, false);
        assertFalse(eu.isEUJurisdiction(34));
        assertFalse(eu.isEUJurisdiction(33));

        eu.setJurisdictionOverrideBatch(jurisdictions, profiles);

        vm.prank(bob);
        vm.expectRevert();
        eu.setEUJurisdiction(34, true);

        vm.expectRevert();
        eu.setJurisdictionOverrideBatch(jurisdictions, new ComplianceModuleV1.JurisdictionProfile[](1));

        eu.installDefaultEUDRHazardPreset();

        ComplianceModuleV1.JurisdictionProfile memory preset = eu.deriveProfile(34, 3, UAgriHazards.GOV_ACTION);
        assertTrue(preset.sameJurisdictionOnly);
        assertTrue(preset.enforceLockupOnTransfer);
        assertEq(preset.minTier, 3);
    }
}
