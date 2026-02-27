// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/// @notice Standard V1 interface for identity/KYC attestations (EIP-712).
/// @dev PII MUST remain off-chain. On-chain stores only typed fields and signatures/allowlist logic.
interface IAgriIdentityAttestationV1 {
    struct Payload {
        uint16 jurisdiction;   // ISO / internal code
        uint8  tier;           // investor tier
        uint32 flags;          // sanctions/accredited/etc.
        uint64 expiry;         // unix ts, 0 = no expiry (discouraged)
        uint64 lockupUntil;    // unix ts, 0 = none
        uint32 providerId;     // attestation provider identifier
    }

    /// @dev Optional: provider allowlist (providerId + signer) for multi-signer providers.
    event ProviderSet(uint32 indexed providerId, address indexed signer, bool allowed);

    /// @dev Emitted when an account is onboarded/updated by a valid provider signature.
    event Registered(
        address indexed account,
        uint16 jurisdiction,
        uint8 tier,
        uint32 flags,
        uint64 expiry,
        uint64 lockupUntil,
        uint32 indexed providerId
    );

    /// @notice Returns the latest effective identity payload for account.
    function identityOf(address account) external view returns (Payload memory);

    /// @notice Anti-replay nonce per (account, providerId).
    function nonces(address account, uint32 providerId) external view returns (uint256);

    /// @notice Registers/updates identity for account using an EIP-712 provider signature.
    /// @param deadline unix ts; 0 MAY mean "no deadline" (profile dependent).
    function register(
        address account,
        Payload calldata payload,
        uint64 deadline,
        bytes calldata sig
    ) external;

    /// @notice Provider allowlist management (admin/governance in implementations).
    function setProvider(uint32 providerId, address signer, bool allowed) external;

    /// @notice Returns whether signer is allowed for providerId.
    function isProvider(uint32 providerId, address signer) external view returns (bool);
}
