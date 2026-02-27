// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {CampaignFactory} from "../src/factory/CampaignFactory.sol";
import {RoleManager} from "../src/access/RoleManager.sol";
import {IdentityAttestation} from "../src/compliance/IdentityAttestation.sol";
import {ComplianceModuleV1} from "../src/compliance/ComplianceModuleV1.sol";

contract PostDeployCampaign is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address caller = vm.addr(pk);

        address factoryAddr = vm.envAddress("FACTORY");
        CampaignFactory factory = CampaignFactory(factoryAddr);

        bytes32 campaignId = _readBytes32("CAMPAIGN_ID", "CAMPAIGN_ID_STR", "uAgri:DEMO:CAMPAIGN");

        // ✅ FIX: mapping getter returns 18 values (not a CampaignStack struct)
        CampaignFactory.CampaignStack memory s = factory.stacks(campaignId);

        require(s.shareToken != address(0), "UNKNOWN_CAMPAIGN");

        console2.log("==== PostDeployCampaign ====");
        console2.logBytes32(campaignId);
        console2.log("caller:", caller);
        console2.log("roleManager:", s.roleManager);
        console2.log("treasury:", s.treasury);
        console2.log("distribution:", s.distribution);
        console2.log("identityAttestation:", s.identityAttestation);
        console2.log("compliance:", s.compliance);

        vm.startBroadcast(pk);

        if (vm.envOr("ACCEPT_ROLEMANAGER_ADMIN_HANDOFF", false)) {
            RoleManager rm = RoleManager(s.roleManager);
            address pending = rm.pendingDefaultAdmin();
            uint64 notBefore = rm.defaultAdminTransferNotBefore();
            if (pending == caller && block.timestamp >= notBefore) {
                rm.acceptDefaultAdminTransfer();
                console2.log("RoleManager DEFAULT_ADMIN accepted by caller.");
            } else {
                console2.log("No pending admin transfer for caller / too early.");
            }
        }

        if (vm.envOr("WIRE_YIELD_NOTIFIERS", true) && s.distribution != address(0)) {
            console2.log("notifyReward ACL is role-based (REWARD_NOTIFIER_ROLE/admin/gov).");
        }

        if (vm.envOr("OPEN_DEFAULT_PROFILE", false)) {
            ComplianceModuleV1 cm = ComplianceModuleV1(s.compliance);
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
            console2.log("Compliance opened for dev (jurisdiction 0).");
        }

        if (vm.envOr("KYC_ENABLED", false)) {
            uint32 providerId = uint32(vm.envOr("KYC_PROVIDER_ID", uint256(1)));
            address signer = vm.envOr("KYC_SIGNER", caller);
            bool enabled = vm.envOr("KYC_SIGNER_ENABLED", true);
            IdentityAttestation(s.identityAttestation).setProvider(providerId, signer, enabled);
            console2.log("Identity provider configured. providerId:", providerId, " signer:", signer);
        }

        vm.stopBroadcast();
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
