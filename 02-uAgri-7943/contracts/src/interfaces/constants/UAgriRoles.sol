// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;


library UAgriRoles {
    bytes32 internal constant DEFAULT_ADMIN_ROLE      = 0x00;

    bytes32 internal constant GUARDIAN_ROLE           = keccak256("GUARDIAN_ROLE");
    bytes32 internal constant TREASURY_ADMIN_ROLE     = keccak256("TREASURY_ADMIN_ROLE");

    bytes32 internal constant COMPLIANCE_OFFICER_ROLE = keccak256("COMPLIANCE_OFFICER_ROLE");
    bytes32 internal constant DISASTER_ADMIN_ROLE     = keccak256("DISASTER_ADMIN_ROLE");
    bytes32 internal constant GOVERNANCE_ROLE         = keccak256("GOVERNANCE_ROLE");

    bytes32 internal constant REGULATOR_ENFORCER_ROLE = keccak256("REGULATOR_ENFORCER_ROLE");

    bytes32 internal constant ORACLE_UPDATER_ROLE     = keccak256("ORACLE_UPDATER_ROLE");
    bytes32 internal constant CUSTODY_ATTESTER_ROLE   = keccak256("CUSTODY_ATTESTER_ROLE");

    bytes32 internal constant FARM_OPERATOR_ROLE      = keccak256("FARM_OPERATOR_ROLE");

    bytes32 internal constant ONRAMP_OPERATOR_ROLE    = keccak256("ONRAMP_OPERATOR_ROLE");
    bytes32 internal constant PAYOUT_OPERATOR_ROLE    = keccak256("PAYOUT_OPERATOR_ROLE");
    bytes32 internal constant REWARD_NOTIFIER_ROLE    = keccak256("REWARD_NOTIFIER_ROLE");

    bytes32 internal constant UPGRADER_ROLE           = keccak256("UPGRADER_ROLE");
    bytes32 internal constant BRIDGE_OPERATOR_ROLE    = keccak256("BRIDGE_OPERATOR_ROLE");

    bytes32 internal constant MARKETPLACE_ADMIN_ROLE  = keccak256("MARKETPLACE_ADMIN_ROLE");
    bytes32 internal constant DELIVERY_OPERATOR_ROLE  = keccak256("DELIVERY_OPERATOR_ROLE");
    bytes32 internal constant INSURANCE_ADMIN_ROLE    = keccak256("INSURANCE_ADMIN_ROLE");
}
