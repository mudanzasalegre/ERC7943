export type ComplianceTone = "default" | "good" | "warn" | "bad";

export type ComplianceReason = {
  code: number;
  key: string;
  label: string;
  description: string;
  tone: ComplianceTone;
};

const REASONS: Record<number, ComplianceReason> = {
  0: {
    code: 0,
    key: "OK",
    label: "Allowed",
    description: "Compliance check passed.",
    tone: "good"
  },
  1: {
    code: 1,
    key: "PAUSED",
    label: "Compliance Paused",
    description: "Compliance module is paused.",
    tone: "bad"
  },
  10: {
    code: 10,
    key: "FROM_DENY_OR_SANCTION",
    label: "Source Denied/Sanctioned",
    description: "Source account is denylisted or sanctioned.",
    tone: "bad"
  },
  11: {
    code: 11,
    key: "TO_DENY_OR_SANCTION",
    label: "Destination Denied/Sanctioned",
    description: "Destination account is denylisted or sanctioned.",
    tone: "bad"
  },
  20: {
    code: 20,
    key: "PROFILE_DISABLED",
    label: "Profile Disabled",
    description: "Jurisdiction profile is disabled or unavailable.",
    tone: "bad"
  },
  30: {
    code: 30,
    key: "IDENTITY_MISSING_OR_INVALID",
    label: "Identity Missing",
    description: "Identity attestation is missing or invalid.",
    tone: "warn"
  },
  31: {
    code: 31,
    key: "IDENTITY_EXPIRED",
    label: "Identity Expired",
    description: "Identity attestation is expired.",
    tone: "warn"
  },
  32: {
    code: 32,
    key: "IDENTITY_TTL_TOO_LOW",
    label: "Identity Near Expiry",
    description: "Identity TTL is below policy minimum.",
    tone: "warn"
  },
  33: {
    code: 33,
    key: "TIER_OUT_OF_RANGE",
    label: "Tier Out Of Range",
    description: "Identity tier does not match profile limits.",
    tone: "warn"
  },
  34: {
    code: 34,
    key: "FLAGS_MISMATCH",
    label: "Flags Mismatch",
    description: "Required/forbidden identity flags do not match policy.",
    tone: "warn"
  },
  35: {
    code: 35,
    key: "NO_EXPIRY_NOT_ALLOWED",
    label: "Expiry Required",
    description: "Profile requires identity expiry.",
    tone: "warn"
  },
  40: {
    code: 40,
    key: "LOCKED",
    label: "Lockup Active",
    description: "Account is under lockup for outgoing transfer.",
    tone: "warn"
  },
  41: {
    code: 41,
    key: "PAIR_BLOCKED",
    label: "Jurisdiction Pair Blocked",
    description: "Transfer between these jurisdictions is blocked.",
    tone: "bad"
  },
  42: {
    code: 42,
    key: "AMOUNT_TOO_LARGE",
    label: "Amount Too Large",
    description: "Transfer amount exceeds policy limit.",
    tone: "warn"
  },
  255: {
    code: 255,
    key: "FAIL_CLOSED",
    label: "Fail Closed",
    description: "Compliance call failed or input is invalid.",
    tone: "bad"
  }
};

export function complianceReason(code?: number): ComplianceReason {
  const c = Number(code ?? 255);
  return (
    REASONS[c] ?? {
      code: c,
      key: `UNKNOWN_${c}`,
      label: `Unknown code ${c}`,
      description: "Code not mapped in current UI.",
      tone: "warn"
    }
  );
}

export function needsOnboarding(code?: number): boolean {
  const c = Number(code ?? -1);
  return c === 30 || c === 31 || c === 32 || c === 33 || c === 34 || c === 35;
}
