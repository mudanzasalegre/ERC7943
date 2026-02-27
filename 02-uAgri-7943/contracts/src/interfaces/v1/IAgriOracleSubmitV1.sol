// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IAgriOracleBaseV1} from "./IAgriOracleBaseV1.sol";

/// @notice Standard V1 submit interface for EIP-712 attestation oracles.
/// @dev Unifies submission across Harvest/Sales/Custody/DisasterEvidence:
///      domain-specific data is committed by payloadHash.
interface IAgriOracleSubmitV1 is IAgriOracleBaseV1 {
    /// @dev Canonical envelope committed by EIP-712 signature.
    /// payloadHash = keccak256(domain-specific packed data) or merkle root hash, etc.
    struct Attestation {
        bytes32 campaignId;
        uint64  epoch;       // monotonic per campaign
        uint64  asOf;        // report time
        uint64  validUntil;  // freshness window end
        bytes32 reportHash;  // evidence bundle hash
        bytes32 payloadHash; // domain-specific commitment (lotsRoot, proceedsRoot, custodyRoot, etc.)
    }

    event AttestationSubmitted(
        bytes32 indexed campaignId,
        uint64 indexed epoch,
        bytes32 reportHash,
        bytes32 payloadHash,
        address indexed signer
    );

    /// @notice Nonce per signer for anti-replay (implementations MAY also add per-campaign nonces).
    function nonces(address signer) external view returns (uint256);

    /// @notice EIP-712 submit of a standardized envelope.
    function submitAttestation(Attestation calldata att, bytes calldata sig) external;

    /// @notice The EIP-712 typehash used for Attestation in this oracle implementation.
    /// @dev Standard recommended:
    /// keccak256("Attestation(bytes32 campaignId,uint64 epoch,uint64 asOf,uint64 validUntil,bytes32 reportHash,bytes32 payloadHash,uint256 nonce)")
    function attestationTypehash() external pure returns (bytes32);
}
