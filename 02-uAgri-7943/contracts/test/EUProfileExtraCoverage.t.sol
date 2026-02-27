// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";

import {RoleManager} from "src/access/RoleManager.sol";
import {EUProfileEUDRCompliance} from "src/compliance/profiles/EUProfileEUDRCompliance.sol";
import {ComplianceModuleV1} from "src/compliance/ComplianceModuleV1.sol";

import {UAgriErrors} from "src/interfaces/constants/UAgriErrors.sol";
import {UAgriRoles} from "src/interfaces/constants/UAgriRoles.sol";
import {UAgriHazards} from "src/interfaces/constants/UAgriHazards.sol";

contract EUProfileExtraCoverageTest is Test {
    RoleManager internal rm;
    EUProfileEUDRCompliance internal eu;

    address internal officer = makeAddr("officer");
    address internal outsider = makeAddr("outsider");

    function setUp() public {
        rm = new RoleManager(address(this));
        rm.grantRole(UAgriRoles.COMPLIANCE_OFFICER_ROLE, officer);
        eu = new EUProfileEUDRCompliance(address(rm));
    }

    function testGovernanceViaOfficerGettersAndBaseOverridePaths() public {
        ComplianceModuleV1.JurisdictionProfile memory p0 = eu.baseProfile(0);
        assertEq(p0.minTier, 1);

        ComplianceModuleV1.JurisdictionProfile memory euDefault = eu.defaultEUProfile();
        euDefault.minTier = 4;
        euDefault.maxTransfer = 1234;

        ComplianceModuleV1.JurisdictionProfile memory nonEuDefault = eu.defaultNonEUProfile();
        nonEuDefault.minTier = 2;
        nonEuDefault.maxTransfer = 4321;

        vm.startPrank(officer);
        eu.setEUJurisdiction(777, true);
        eu.setDefaultEUProfile(euDefault);
        eu.setDefaultNonEUProfile(nonEuDefault);
        vm.stopPrank();

        ComplianceModuleV1.JurisdictionProfile memory pEu = eu.baseProfile(777);
        assertEq(pEu.minTier, 4);
        assertEq(pEu.maxTransfer, 1234);

        ComplianceModuleV1.JurisdictionProfile memory overrideP = ComplianceModuleV1.JurisdictionProfile({
            enabled: true,
            requireIdentity: false,
            allowNoExpiry: true,
            enforceLockupOnTransfer: false,
            sameJurisdictionOnly: true,
            minTier: 5,
            maxTier: 6,
            requiredFlags: 11,
            forbiddenFlags: 22,
            minTtlSeconds: 10 days,
            maxTransfer: 888
        });

        vm.prank(officer);
        eu.setJurisdictionOverride(777, overrideP);
        ComplianceModuleV1.JurisdictionProfile memory gotOverride = eu.overrideProfileOf(777);
        assertTrue(gotOverride.enabled);
        assertEq(gotOverride.minTier, 5);

        EUProfileEUDRCompliance.TierRule memory tr = EUProfileEUDRCompliance.TierRule({
            enabled: true,
            minTtlSeconds: 45 days,
            maxTransfer: 999,
            requiredFlags: 3,
            forbiddenFlags: 4
        });
        vm.prank(officer);
        eu.setTierRule(9, tr);
        EUProfileEUDRCompliance.TierRule memory gotTr = eu.tierRuleOf(9);
        assertTrue(gotTr.enabled);
        assertEq(gotTr.maxTransfer, 999);

        EUProfileEUDRCompliance.HazardRule memory hr = EUProfileEUDRCompliance.HazardRule({
            enabled: true,
            minTierFloor: 7,
            requiredFlags: 5,
            forbiddenFlags: 6,
            sameJurisdictionOnly: true,
            enforceLockupOnTransfer: true,
            maxTransferCap: 777
        });
        vm.prank(officer);
        eu.setHazardRule(UAgriHazards.FRAUD_OR_MATERIAL_BREACH, hr);
        EUProfileEUDRCompliance.HazardRule memory gotHr = eu.hazardRuleOf(UAgriHazards.FRAUD_OR_MATERIAL_BREACH);
        assertTrue(gotHr.enabled);
        assertEq(gotHr.minTierFloor, 7);

        ComplianceModuleV1.JurisdictionProfile memory derived =
            eu.deriveProfile(777, 9, UAgriHazards.FRAUD_OR_MATERIAL_BREACH);
        assertEq(derived.minTier, 7);
        assertEq(derived.maxTransfer, 777);
        assertTrue(derived.sameJurisdictionOnly);
        assertTrue(derived.enforceLockupOnTransfer);
    }

    function testBatchMismatchUnauthorizedAndBatchSuccess() public {
        vm.prank(outsider);
        vm.expectRevert(UAgriErrors.UAgri__Unauthorized.selector);
        eu.setEUJurisdiction(1, true);

        uint16[] memory jurisdictions = new uint16[](2);
        jurisdictions[0] = 34;
        jurisdictions[1] = 33;

        ComplianceModuleV1.JurisdictionProfile[] memory oneProfile = new ComplianceModuleV1.JurisdictionProfile[](1);
        oneProfile[0] = eu.defaultEUProfile();

        vm.expectRevert(EUProfileEUDRCompliance.EUProfileEUDRCompliance__ArrayLengthMismatch.selector);
        eu.setJurisdictionOverrideBatch(jurisdictions, oneProfile);

        uint8[] memory tiers = new uint8[](2);
        tiers[0] = 1;
        tiers[1] = 2;
        EUProfileEUDRCompliance.TierRule[] memory oneRule = new EUProfileEUDRCompliance.TierRule[](1);
        oneRule[0] = EUProfileEUDRCompliance.TierRule({
            enabled: true,
            minTtlSeconds: 1 days,
            maxTransfer: 10,
            requiredFlags: 1,
            forbiddenFlags: 2
        });
        vm.expectRevert(EUProfileEUDRCompliance.EUProfileEUDRCompliance__ArrayLengthMismatch.selector);
        eu.setTierRuleBatch(tiers, oneRule);

        bytes32[] memory hazards = new bytes32[](2);
        hazards[0] = UAgriHazards.GOV_ACTION;
        hazards[1] = UAgriHazards.SUPPLY_CHAIN_DISRUPTION;
        EUProfileEUDRCompliance.HazardRule[] memory oneHazardRule = new EUProfileEUDRCompliance.HazardRule[](1);
        oneHazardRule[0] = EUProfileEUDRCompliance.HazardRule({
            enabled: true,
            minTierFloor: 3,
            requiredFlags: 0,
            forbiddenFlags: 0,
            sameJurisdictionOnly: false,
            enforceLockupOnTransfer: true,
            maxTransferCap: 0
        });
        vm.expectRevert(EUProfileEUDRCompliance.EUProfileEUDRCompliance__ArrayLengthMismatch.selector);
        eu.setHazardRuleBatch(hazards, oneHazardRule);

        ComplianceModuleV1.JurisdictionProfile[] memory profiles = new ComplianceModuleV1.JurisdictionProfile[](2);
        profiles[0] = eu.defaultEUProfile();
        profiles[1] = eu.defaultNonEUProfile();
        eu.setJurisdictionOverrideBatch(jurisdictions, profiles);

        EUProfileEUDRCompliance.TierRule[] memory tierRules = new EUProfileEUDRCompliance.TierRule[](2);
        tierRules[0] = oneRule[0];
        tierRules[1] = EUProfileEUDRCompliance.TierRule({
            enabled: true,
            minTtlSeconds: 2 days,
            maxTransfer: 20,
            requiredFlags: 3,
            forbiddenFlags: 4
        });
        eu.setTierRuleBatch(tiers, tierRules);

        EUProfileEUDRCompliance.HazardRule[] memory hazardRules = new EUProfileEUDRCompliance.HazardRule[](2);
        hazardRules[0] = oneHazardRule[0];
        hazardRules[1] = EUProfileEUDRCompliance.HazardRule({
            enabled: true,
            minTierFloor: 0,
            requiredFlags: 5,
            forbiddenFlags: 6,
            sameJurisdictionOnly: true,
            enforceLockupOnTransfer: false,
            maxTransferCap: 100
        });
        eu.setHazardRuleBatch(hazards, hazardRules);

        eu.setEUJurisdictions(jurisdictions, false);
        assertFalse(eu.isEUJurisdiction(34));
        assertFalse(eu.isEUJurisdiction(33));

        eu.installDefaultEUDRHazardPreset();
        EUProfileEUDRCompliance.HazardRule memory govAction = eu.hazardRuleOf(UAgriHazards.GOV_ACTION);
        EUProfileEUDRCompliance.HazardRule memory expropriation = eu.hazardRuleOf(UAgriHazards.EXPROPRIATION_OR_ACCESS_LOSS);
        assertTrue(govAction.enabled);
        assertTrue(expropriation.enabled);
    }
}

