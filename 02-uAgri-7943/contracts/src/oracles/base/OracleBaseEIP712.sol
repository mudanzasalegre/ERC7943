// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IAgriOracleSubmitV1} from "../../interfaces/v1/IAgriOracleSubmitV1.sol";
import {RoleManager} from "../../access/RoleManager.sol";
import {UAgriRoles} from "../../interfaces/constants/UAgriRoles.sol";
import {UAgriErrors} from "../../interfaces/constants/UAgriErrors.sol";

import {EIP712} from "../../_shared/EIP712.sol";
import {ECDSA} from "../../_shared/ECDSA.sol";

/// @dev Minimal IERC1271 for contract-based signers (multisig / smart accounts).
interface IERC1271 {
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4 magicValue);
}

/// @title OracleBaseEIP712
/// @notice Base for uAgri oracles: EIP-712 attestation verification + submitter RBAC + anti-replay + monotonic epochs.
/// @dev Design constraint from IAgriOracleSubmitV1: nonce is per signer but not present in Attestation struct,
///      so we require msg.sender to be the signer (EOA via ECDSA recover == msg.sender, or contract via IERC1271(msg.sender)).
abstract contract OracleBaseEIP712 is IAgriOracleSubmitV1, EIP712 {
    using ECDSA for bytes32;

    // --------------------------------- Errors ---------------------------------

    error OracleBaseEIP712__AlreadyInitialized();
    error OracleBaseEIP712__InvalidRoleManager();
    error OracleBaseEIP712__Unauthorized();
    error OracleBaseEIP712__InvalidCampaignId();
    error OracleBaseEIP712__InvalidEpoch();
    error OracleBaseEIP712__InvalidHash();
    error OracleBaseEIP712__InvalidTimeWindow();
    error OracleBaseEIP712__EpochNotMonotonic(uint64 expected, uint64 got);
    error OracleBaseEIP712__SubmitterRoleZero();

    // --------------------------------- Events ---------------------------------

    event RoleManagerUpdated(address indexed oldRoleManager, address indexed newRoleManager);
    event SubmitterRoleUpdated(bytes32 indexed oldRole, bytes32 indexed newRole);

    // ------------------------------ EIP-712 -----------------------------------

    // keccak256("Attestation(bytes32 campaignId,uint64 epoch,uint64 asOf,uint64 validUntil,bytes32 reportHash,bytes32 payloadHash,uint256 nonce)")
    bytes32 internal constant ATTESTATION_TYPEHASH =
        0x9e7b72b87c7e1e9d1d7a6c5c6bff90b2daae4e8a3e9fe8e2d2f25f6e6cbb0cc3;

    // -------------------------------- Storage --------------------------------

    RoleManager public roleManager;
    bytes32 public submitterRole;

    mapping(address => uint256) public override nonces;

    mapping(bytes32 => uint64) internal _latestEpoch; // campaignId => latest epoch
    mapping(bytes32 => mapping(uint64 => bytes32)) internal _reportHash; // campaignId => epoch => reportHash
    mapping(bytes32 => mapping(uint64 => bytes32)) internal _payloadHash; // campaignId => epoch => payloadHash
    mapping(bytes32 => mapping(uint64 => uint64)) internal _asOf; // campaignId => epoch => asOf
    mapping(bytes32 => mapping(uint64 => uint64)) internal _validUntil; // campaignId => epoch => validUntil

    bool private _initialized;

    // ----------------------------- Init / Config ------------------------------

    constructor(
        string memory name_,
        string memory version_,
        address roleManager_,
        bytes32 submitterRole_
    ) EIP712(name_, version_) {
        _init(roleManager_, submitterRole_);
    }

    function _init(address roleManager_, bytes32 submitterRole_) internal {
        if (_initialized) revert OracleBaseEIP712__AlreadyInitialized();
        _initialized = true;

        if (roleManager_ == address(0)) revert OracleBaseEIP712__InvalidRoleManager();
        if (submitterRole_ == bytes32(0)) revert OracleBaseEIP712__SubmitterRoleZero();

        roleManager = RoleManager(roleManager_);
        submitterRole = submitterRole_;

        emit RoleManagerUpdated(address(0), roleManager_);
        emit SubmitterRoleUpdated(bytes32(0), submitterRole_);
    }

    function setRoleManager(address newRoleManager) external {
        _requireGovernance();
        if (newRoleManager == address(0)) revert OracleBaseEIP712__InvalidRoleManager();
        address old = address(roleManager);
        roleManager = RoleManager(newRoleManager);
        emit RoleManagerUpdated(old, newRoleManager);
    }

    function setSubmitterRole(bytes32 newRole) external {
        _requireGovernance();
        if (newRole == bytes32(0)) revert OracleBaseEIP712__SubmitterRoleZero();
        bytes32 old = submitterRole;
        submitterRole = newRole;
        emit SubmitterRoleUpdated(old, newRole);
    }

    // --------------------------------- Views ---------------------------------

    function latestEpoch(bytes32 campaignId) external view override returns (uint64) {
        return _latestEpoch[campaignId];
    }

    function reportHash(bytes32 campaignId, uint64 epoch) external view override returns (bytes32) {
        return _reportHash[campaignId][epoch];
    }

    function payloadHash(bytes32 campaignId, uint64 epoch) external view returns (bytes32) {
        return _payloadHash[campaignId][epoch];
    }

    function reportWindow(bytes32 campaignId, uint64 epoch) external view returns (uint64 asOf_, uint64 validUntil_) {
        asOf_ = uint64(_asOf[campaignId][epoch]);
        validUntil_ = uint64(_validUntil[campaignId][epoch]);
    }

    /// @notice True iff report exists and is currently within its freshness window.
    function isReportValid(bytes32 campaignId, uint64 epoch) external view override returns (bool) {
        bytes32 rh = _reportHash[campaignId][epoch];
        if (rh == bytes32(0)) return false;

        uint64 nowTs = uint64(block.timestamp);
        uint64 asOf_ = uint64(_asOf[campaignId][epoch]);
        uint64 vu = uint64(_validUntil[campaignId][epoch]);

        if (asOf_ != 0 && nowTs < asOf_) return false;
        if (vu == 0) return true; // 0 = no-expiry profile
        return nowTs <= vu;
    }

    function attestationTypehash() external pure override returns (bytes32) {
        return ATTESTATION_TYPEHASH;
    }

    function domainSeparator() external view returns (bytes32) {
        return domainSeparatorV4();
    }

    // --------------------------- EIP-712 Helpers ------------------------------

    function hashAttestationStruct(Attestation calldata att, uint256 nonce) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ATTESTATION_TYPEHASH,
                att.campaignId,
                att.epoch,
                att.asOf,
                att.validUntil,
                att.reportHash,
                att.payloadHash,
                nonce
            )
        );
    }

    function hashAttestation(Attestation calldata att) external view returns (bytes32 digest) {
        uint256 nonce = nonces[msg.sender];
        bytes32 structHash = hashAttestationStruct(att, nonce);
        digest = _hashTypedDataV4(structHash);
    }

    function hashAttestationWithNonce(Attestation calldata att)
        external
        view
        returns (bytes32 digest, uint256 nonce)
    {
        nonce = nonces[msg.sender];
        bytes32 structHash = hashAttestationStruct(att, nonce);
        digest = _hashTypedDataV4(structHash);
    }

    // ------------------------------- Submit -----------------------------------

    function submitAttestation(Attestation calldata att, bytes calldata sig) external override {
        _requireSubmitter();

        if (sig.length == 0) revert UAgriErrors.UAgri__InvalidSignature();
        if (att.campaignId == bytes32(0)) revert OracleBaseEIP712__InvalidCampaignId();
        if (att.epoch == 0) revert OracleBaseEIP712__InvalidEpoch();
        if (att.reportHash == bytes32(0) || att.payloadHash == bytes32(0)) revert OracleBaseEIP712__InvalidHash();

        uint64 nowTs = uint64(block.timestamp);

        // Freshness window rules:
        // - asOf MUST not be in the future
        // - validUntil MAY be 0 (no expiry). If nonzero: must be >= asOf and must not be already expired.
        if (att.asOf == 0 || att.asOf > nowTs) revert OracleBaseEIP712__InvalidTimeWindow();
        if (att.validUntil != 0) {
            if (att.validUntil < att.asOf) revert OracleBaseEIP712__InvalidTimeWindow();
            if (nowTs > att.validUntil) revert UAgriErrors.UAgri__OracleStale();
        }

        uint64 expected = _latestEpoch[att.campaignId] + 1;
        if (att.epoch != expected) revert OracleBaseEIP712__EpochNotMonotonic(expected, att.epoch);

        uint256 nonce = nonces[msg.sender];

        bytes32 structHash = hashAttestationStruct(att, nonce);
        bytes32 digest = _hashTypedDataV4(structHash);

        // Verification:
        // - If caller is a contract => IERC1271(caller)
        // - Else => ECDSA recover must equal msg.sender
        if (msg.sender.code.length != 0) {
            bytes4 magic = IERC1271(msg.sender).isValidSignature(digest, sig);
            if (magic != 0x1626ba7e) revert UAgriErrors.UAgri__InvalidSignature();
        } else {
            address signer = digest.recover(sig);
            if (signer != msg.sender) revert UAgriErrors.UAgri__InvalidSignature();
        }

        // Consume nonce (anti-replay)
        unchecked {
            nonces[msg.sender] = nonce + 1;
        }

        // Store immutable history
        _latestEpoch[att.campaignId] = att.epoch;
        _reportHash[att.campaignId][att.epoch] = att.reportHash;
        _payloadHash[att.campaignId][att.epoch] = att.payloadHash;
        _asOf[att.campaignId][att.epoch] = att.asOf;
        _validUntil[att.campaignId][att.epoch] = att.validUntil;

        emit OracleReportSubmitted(att.campaignId, att.epoch, att.reportHash, att.asOf, att.validUntil);
        emit AttestationSubmitted(att.campaignId, att.epoch, att.reportHash, att.payloadHash, msg.sender);
    }

    // --------------------------------- RBAC ----------------------------------

    function _requireGovernance() internal view {
        RoleManager rm = roleManager;
        address caller = msg.sender;

        if (
            rm.hasRole(UAgriRoles.DEFAULT_ADMIN_ROLE, caller) ||
            rm.hasRole(UAgriRoles.GOVERNANCE_ROLE, caller) ||
            rm.hasRole(UAgriRoles.COMPLIANCE_OFFICER_ROLE, caller)
        ) return;

        revert OracleBaseEIP712__Unauthorized();
    }

    function _requireSubmitter() internal view {
        RoleManager rm = roleManager;
        address caller = msg.sender;

        if (
            rm.hasRole(UAgriRoles.DEFAULT_ADMIN_ROLE, caller) ||
            rm.hasRole(UAgriRoles.GOVERNANCE_ROLE, caller) ||
            rm.hasRole(submitterRole, caller)
        ) return;

        revert OracleBaseEIP712__Unauthorized();
    }
}
