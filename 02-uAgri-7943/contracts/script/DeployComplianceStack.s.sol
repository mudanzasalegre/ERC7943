// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "../lib/forge-std/src/Script.sol";
import "../lib/forge-std/src/console2.sol";

import {IAgriModulesV1} from "../src/interfaces/v1/IAgriModulesV1.sol";
import {IdentityAttestation} from "../src/compliance/IdentityAttestation.sol";
import {ComplianceModuleV1} from "../src/compliance/ComplianceModuleV1.sol";

interface IAgriShareTokenGovernance {
    function setModulesV1(IAgriModulesV1.ModulesV1 calldata modules_) external;
}

contract DeployComplianceStack is Script {
    function run() external {
        // ---- Required env ----
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address roleManager = vm.envAddress("ROLE_MANAGER");
        address shareToken = vm.envAddress("SHARE_TOKEN");

        address deployer = vm.addr(deployerPk);

        // ---- Optional env ----
        uint32 providerId = uint32(vm.envOr("PROVIDER_ID", uint256(1))); // default 1
        uint16 J_DEFAULT = uint16(vm.envOr("JURIS_DEFAULT", uint256(0))); // default 0
        uint16 J_ES = uint16(vm.envOr("JURIS_ES", uint256(34))); // default 34

        console2.log("Deployer:", deployer);
        console2.log("RoleManager:", roleManager);
        console2.log("ShareToken:", shareToken);
        console2.log("providerId:", uint256(providerId));
        console2.log("J_DEFAULT:", uint256(J_DEFAULT));
        console2.log("J_ES:", uint256(J_ES));

        vm.startBroadcast(deployerPk);

        // 1) Deploy IdentityAttestation
        IdentityAttestation ia = new IdentityAttestation(roleManager);
        console2.log("IdentityAttestation:", address(ia));

        // 2) Deploy ComplianceModuleV1 (wired to IdentityAttestation)
        ComplianceModuleV1 cm = new ComplianceModuleV1(roleManager, address(ia));
        console2.log("ComplianceModuleV1:", address(cm));

        // 3) Profiles: default (0) and ES (34)
        // Default profile (fallback)
        ComplianceModuleV1.JurisdictionProfile memory p0 = ComplianceModuleV1.JurisdictionProfile({
            enabled: true,
            requireIdentity: true,
            allowNoExpiry: true,
            enforceLockupOnTransfer: true,
            sameJurisdictionOnly: false,
            minTier: 1,
            maxTier: 0,
            requiredFlags: 0,
            forbiddenFlags: 0,
            minTtlSeconds: 0,
            maxTransfer: 0
        });
        cm.setProfile(J_DEFAULT, p0);

        // ES profile example (a bit stricter)
        ComplianceModuleV1.JurisdictionProfile memory pES = ComplianceModuleV1.JurisdictionProfile({
            enabled: true,
            requireIdentity: true,
            allowNoExpiry: false,
            enforceLockupOnTransfer: true,
            sameJurisdictionOnly: false,
            minTier: 2,
            maxTier: 0,
            requiredFlags: 0,
            forbiddenFlags: 0,
            minTtlSeconds: 0,
            maxTransfer: 0
        });
        cm.setProfile(J_ES, pES);

        // 4) Providers batch (env-driven)
        // PROVIDER_SIGNER_0..PROVIDER_SIGNER_9 (si no existe, envOr devuelve address(0) y se ignora)
        address[] memory providerSigners = _collectAddresses("PROVIDER_SIGNER_", 10, deployer);
        // si no seteas ninguna env, por defecto mete deployer como signer (te sirve para tests)
        ia.setProviderBatch(providerId, providerSigners, true);
        console2.log("Providers loaded:", providerSigners.length);

        // 5) Denylist demo (env-driven)
        // DENY_0..DENY_9 (si no existe, se ignora)
        address[] memory deny = _collectAddresses("DENY_", 10, address(0));
        if (deny.length != 0) {
            cm.setDenylistedBatch(deny, true);
            console2.log("Denylisted loaded:", deny.length);
        }

        // 6) (Opcional “fino”): eximir módulos internos del token si existen
        _exemptIfSet(cm, IAgriModulesV1(shareToken).treasury());
        _exemptIfSet(cm, IAgriModulesV1(shareToken).settlementQueue());
        _exemptIfSet(cm, IAgriModulesV1(shareToken).custodyModule());
        _exemptIfSet(cm, IAgriModulesV1(shareToken).bridgeModule());
        _exemptIfSet(cm, IAgriModulesV1(shareToken).marketplaceModule());
        _exemptIfSet(cm, IAgriModulesV1(shareToken).deliveryModule());
        _exemptIfSet(cm, IAgriModulesV1(shareToken).insuranceModule());
        _exemptIfSet(cm, IAgriModulesV1(shareToken).distribution());

        // 7) Wiring: ModulesV1.compliance -> new ComplianceModuleV1
        IAgriModulesV1 token = IAgriModulesV1(shareToken);

        IAgriModulesV1.ModulesV1 memory mods = IAgriModulesV1.ModulesV1({
            compliance: address(cm),
            disaster: token.disasterModule(),
            freezeModule: token.freezeModule(),
            custody: token.custodyModule(),

            trace: token.traceModule(),
            documentRegistry: token.documentRegistry(),

            settlementQueue: token.settlementQueue(),
            treasury: token.treasury(),
            distribution: token.distribution(),

            bridge: token.bridgeModule(),
            marketplace: token.marketplaceModule(),
            delivery: token.deliveryModule(),
            insurance: token.insuranceModule()
        });

        IAgriShareTokenGovernance(shareToken).setModulesV1(mods);
        console2.log("Wired token.compliance ->", address(cm));

        vm.stopBroadcast();
    }

    function _exemptIfSet(ComplianceModuleV1 cm, address a) internal {
        if (a == address(0)) return;
        cm.setExempt(a, true);
        console2.log("Exempt:", a);
    }

    /// @dev Collect env addresses with keys like PREFIX_0..PREFIX_(max-1).
    ///      - If `fallbackFirst != address(0)` and no env is set, returns [fallbackFirst].
    function _collectAddresses(string memory prefix, uint256 max, address fallbackFirst)
        internal
        view
        returns (address[] memory out)
    {
        address[] memory tmp = new address[](max);
        uint256 n;

        for (uint256 i = 0; i < max; i++) {
            // build key: prefix + i
            string memory key = string.concat(prefix, vm.toString(i));
            address a = vm.envOr(key, address(0));
            if (a != address(0)) {
                tmp[n] = a;
                n++;
            }
        }

        if (n == 0 && fallbackFirst != address(0)) {
            out = new address[](1);
            out[0] = fallbackFirst;
            return out;
        }

        out = new address[](n);
        for (uint256 j = 0; j < n; j++) {
            out[j] = tmp[j];
        }
    }
}
