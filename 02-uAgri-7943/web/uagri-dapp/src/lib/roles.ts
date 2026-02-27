import { keccak256, stringToBytes } from "viem";

export type RoleDef = { key: string; label: string; role: `0x${string}`; description: string };
export type RolePresetKey = "org_manager" | "ops" | "admin_governance";

const k = (s: string) => keccak256(stringToBytes(s));

export const roles: RoleDef[] = [
  { key: "DEFAULT_ADMIN_ROLE", label: "Default Admin", role: ("0x" + "00".repeat(32)) as `0x${string}`, description: "Root admin (two-step transfer supported)." },
  { key: "GUARDIAN_ROLE", label: "Guardian", role: k("GUARDIAN_ROLE"), description: "Emergency operations / guardian actions." },
  { key: "TREASURY_ADMIN_ROLE", label: "Treasury Admin", role: k("TREASURY_ADMIN_ROLE"), description: "Can pay and note inflows in treasury." },
  { key: "COMPLIANCE_OFFICER_ROLE", label: "Compliance Officer", role: k("COMPLIANCE_OFFICER_ROLE"), description: "Compliance checks / allowlisting." },
  { key: "DISASTER_ADMIN_ROLE", label: "Disaster Admin", role: k("DISASTER_ADMIN_ROLE"), description: "Declare/confirm/clear disasters (module)." },
  { key: "GOVERNANCE_ROLE", label: "Governance", role: k("GOVERNANCE_ROLE"), description: "Token governance actions (wiring/config)." },
  { key: "REGULATOR_ENFORCER_ROLE", label: "Regulator Enforcer", role: k("REGULATOR_ENFORCER_ROLE"), description: "Forced transfers / freezing (if enabled)." },
  { key: "ORACLE_UPDATER_ROLE", label: "Oracle Updater", role: k("ORACLE_UPDATER_ROLE"), description: "Oracle/report updates for settlements." },
  { key: "CUSTODY_ATTESTER_ROLE", label: "Custody Attester", role: k("CUSTODY_ATTESTER_ROLE"), description: "Custody attestations." },
  { key: "FARM_OPERATOR_ROLE", label: "Farm Operator", role: k("FARM_OPERATOR_ROLE"), description: "Operational updates for campaign lifecycle." },
  { key: "ONRAMP_OPERATOR_ROLE", label: "OnRamp Operator", role: k("ONRAMP_OPERATOR_ROLE"), description: "Can execute sponsored FIAT deposits." },
  { key: "PAYOUT_OPERATOR_ROLE", label: "Payout Operator", role: k("PAYOUT_OPERATOR_ROLE"), description: "Can execute claimToWithSig/confirmPayout flows." },
  { key: "REWARD_NOTIFIER_ROLE", label: "Reward Notifier", role: k("REWARD_NOTIFIER_ROLE"), description: "Can notifyReward (liquidation rewards)." },
  { key: "UPGRADER_ROLE", label: "Upgrader", role: k("UPGRADER_ROLE"), description: "Upgrades (if proxy pattern used)." },
  { key: "BRIDGE_OPERATOR_ROLE", label: "Bridge Operator", role: k("BRIDGE_OPERATOR_ROLE"), description: "Bridge operations." },
  { key: "MARKETPLACE_ADMIN_ROLE", label: "Marketplace Admin", role: k("MARKETPLACE_ADMIN_ROLE"), description: "Marketplace module admin." },
  { key: "DELIVERY_OPERATOR_ROLE", label: "Delivery Operator", role: k("DELIVERY_OPERATOR_ROLE"), description: "Delivery module operator." },
  { key: "INSURANCE_ADMIN_ROLE", label: "Insurance Admin", role: k("INSURANCE_ADMIN_ROLE"), description: "Insurance module admin." }
];

export const roleByKey = Object.fromEntries(roles.map((r) => [r.key, r])) as Record<string, RoleDef>;

export const rolePresets: Record<RolePresetKey, { label: string; description: string; keys: string[] }> = {
  org_manager: {
    label: "Org Manager",
    description: "Operational role set for organization managers.",
    keys: ["FARM_OPERATOR_ROLE", "DELIVERY_OPERATOR_ROLE", "MARKETPLACE_ADMIN_ROLE", "INSURANCE_ADMIN_ROLE"]
  },
  ops: {
    label: "Ops",
    description: "Settlement, treasury, onramp, payout and reward execution roles.",
    keys: [
      "TREASURY_ADMIN_ROLE",
      "ONRAMP_OPERATOR_ROLE",
      "PAYOUT_OPERATOR_ROLE",
      "REWARD_NOTIFIER_ROLE",
      "ORACLE_UPDATER_ROLE",
      "CUSTODY_ATTESTER_ROLE",
      "DISASTER_ADMIN_ROLE"
    ]
  },
  admin_governance: {
    label: "Admin Governance",
    description: "High-privilege governance and admin controls.",
    keys: ["DEFAULT_ADMIN_ROLE", "GOVERNANCE_ROLE", "COMPLIANCE_OFFICER_ROLE", "GUARDIAN_ROLE", "UPGRADER_ROLE"]
  }
};
