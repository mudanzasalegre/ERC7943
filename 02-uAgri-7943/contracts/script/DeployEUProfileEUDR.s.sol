// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "../lib/forge-std/src/Script.sol";
import "../lib/forge-std/src/console2.sol";

import {ComplianceModuleV1} from "../src/compliance/ComplianceModuleV1.sol";
import {EUProfileEUDRCompliance} from "../src/compliance/profiles/EUProfileEUDRCompliance.sol";

import {UAgriHazards} from "../src/interfaces/constants/UAgriHazards.sol";

/// @notice Deploy + configure EUProfileEUDRCompliance and materialize base profiles into ComplianceModuleV1.
/// @dev Env vars required:
///   - PRIVATE_KEY (uint)
///   - ROLE_MANAGER (address)     (only used to deploy the plugin)
///   - COMPLIANCE_MODULE (address) (existing ComplianceModuleV1 to configure)
///
/// Run:
///   forge script script/DeployEUProfileEUDR.s.sol:DeployEUProfileEUDR \
///     --rpc-url $RPC_URL --broadcast -vvvv \
///     --sig "run()" \
///     --env PRIVATE_KEY=$PK ROLE_MANAGER=$RM COMPLIANCE_MODULE=$CM
contract DeployEUProfileEUDR is Script {
    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address roleManager = vm.envAddress("ROLE_MANAGER");
        address cmAddr = vm.envAddress("COMPLIANCE_MODULE");

        address deployer = vm.addr(deployerPk);

        console2.log("Deployer:", deployer);
        console2.log("RoleManager:", roleManager);
        console2.log("ComplianceModuleV1:", cmAddr);

        vm.startBroadcast(deployerPk);

        // 1) Deploy plugin
        EUProfileEUDRCompliance plugin = new EUProfileEUDRCompliance(roleManager);
        console2.log("EUProfileEUDRCompliance deployed at:", address(plugin));

        // 2) Install default hazard preset (rules exist, but ComplianceModuleV1 won't apply hazards automatically yet)
        plugin.installDefaultEUDRHazardPreset();
        console2.log("Installed default EUDR hazard preset");

        // 3) Tier rules (examples)
        //    - tier 1: allow, but cap amount (optional) + keep TTL mild
        //    - tier 2: normal
        //    - tier 3: more “institutional” (higher TTL)
        //
        // NOTE: requiredFlags/forbiddenFlags = 0 by default because we don’t want to brick transfers
        //       until you define your identity flags semantics clearly.
        _setTierRules(plugin);

        // 4) Materialize base profiles into ComplianceModuleV1 for selected jurisdictions
        ComplianceModuleV1 cm = ComplianceModuleV1(cmAddr);

        // Base/no-hazard profile derivation (hazard = bytes32(0))
        bytes32 NO_HAZARD = bytes32(0);

        // Default bucket 0 (usually Non-EU default, unless you toggle it in plugin)
        _deriveAndSet(cm, plugin, 0, 0, NO_HAZARD);

        // ES = 34
        _deriveAndSet(cm, plugin, 34, 0, NO_HAZARD);

        // Puedes activar otros si te interesa “precargar” perfiles por jurisdicción:
        // _deriveAndSet(cm, plugin, 33, 0, NO_HAZARD);   // FR
        // _deriveAndSet(cm, plugin, 49, 0, NO_HAZARD);   // DE
        // _deriveAndSet(cm, plugin, 39, 0, NO_HAZARD);   // IT
        // _deriveAndSet(cm, plugin, 351, 0, NO_HAZARD);  // PT (según tu esquema)
        // _deriveAndSet(cm, plugin, 31, 0, NO_HAZARD);   // NL

        console2.log("Materialization done (base profiles, no hazard).");

        // (Opcional) Si quieres “dejar ES permanentemente en modo incidente”, puedes derivar con hazard:
        // bytes32 H = UAgriHazards.FRAUD_OR_MATERIAL_BREACH;
        // _deriveAndSet(cm, plugin, 34, 0, H);
        // OJO: esto lo haría PERMANENTE en el perfil del módulo (hasta que lo cambies), no dinámico.

        vm.stopBroadcast();
    }

    function _setTierRules(EUProfileEUDRCompliance plugin) internal {
        // Tier 1: más restrictivo de amount (ejemplo), TTL mínimo 0 (delegado al perfil base EU)
        EUProfileEUDRCompliance.TierRule memory t1 = EUProfileEUDRCompliance.TierRule({
            enabled: true,
            minTtlSeconds: 0,
            maxTransfer: 0,        // si quieres cap: por ejemplo 10_000e18 (en unidades del token)
            requiredFlags: 0,
            forbiddenFlags: 0
        });
        plugin.setTierRule(1, t1);
        console2.log("TierRule set: tier 1");

        // Tier 2: normal
        EUProfileEUDRCompliance.TierRule memory t2 = EUProfileEUDRCompliance.TierRule({
            enabled: true,
            minTtlSeconds: 0,
            maxTransfer: 0,
            requiredFlags: 0,
            forbiddenFlags: 0
        });
        plugin.setTierRule(2, t2);
        console2.log("TierRule set: tier 2");

        // Tier 3: “mejor” TTL mínimo (ejemplo)
        EUProfileEUDRCompliance.TierRule memory t3 = EUProfileEUDRCompliance.TierRule({
            enabled: true,
            minTtlSeconds: 60 days, // un poco más “premium”
            maxTransfer: 0,
            requiredFlags: 0,
            forbiddenFlags: 0
        });
        plugin.setTierRule(3, t3);
        console2.log("TierRule set: tier 3");
    }

    function _deriveAndSet(
        ComplianceModuleV1 cm,
        EUProfileEUDRCompliance plugin,
        uint16 jurisdiction,
        uint8 tier,
        bytes32 hazard
    ) internal {
        ComplianceModuleV1.JurisdictionProfile memory p = plugin.deriveProfile(jurisdiction, tier, hazard);

        // “Guardrail” mínimo: asegúrate de no grabar un perfil deshabilitado por accidente.
        // (El plugin por defecto devuelve enabled=true, pero si metes overrides raros…)
        if (!p.enabled) {
            console2.log("WARN: derived profile disabled, skipping jurisdiction:", uint256(jurisdiction));
            return;
        }

        cm.setProfile(jurisdiction, p);
        console2.log("Set cm profile for jurisdiction:", uint256(jurisdiction));

        // Debug rápido: imprime algunos campos clave
        console2.log("  requireIdentity:", p.requireIdentity);
        console2.log("  allowNoExpiry:", p.allowNoExpiry);
        console2.log("  enforceLockup:", p.enforceLockupOnTransfer);
        console2.log("  minTier:", uint256(p.minTier));
        console2.log("  minTtlSeconds:", uint256(p.minTtlSeconds));
        console2.log("  maxTransfer:", uint256(p.maxTransfer));
    }
}
