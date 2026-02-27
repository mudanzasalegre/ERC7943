// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IAgriIdentityAttestationV1} from "../interfaces/v1/IAgriIdentityAttestationV1.sol";

import {UAgriErrors} from "../interfaces/constants/UAgriErrors.sol";
import {UAgriRoles} from "../interfaces/constants/UAgriRoles.sol";

import {RoleManager} from "../access/RoleManager.sol";

import {EIP712} from "../_shared/EIP712.sol";
import {ECDSA} from "../_shared/ECDSA.sol";

/// @dev Minimal IERC1271 for contract-based signers (optional path).
interface IERC1271 {
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4 magicValue);
}

/// @title IdentityAttestation
/// @notice Identity/KYC attestation registry for compliance: providers sign EIP-712 payloads for accounts.
/// @dev - Nonces are tracked per (account, providerId)
///      - Provider allowlist is per (providerId, signer)
///      - Latest payload per account is stored (single “effective” payload)
///      - Optional EIP-1271 path: if msg.sender is an allowlisted contract-signer for providerId,
///        we validate via IERC1271(msg.sender).isValidSignature(digest, signature)
contract IdentityAttestation is IAgriIdentityAttestationV1, EIP712 {
    using ECDSA for bytes32;

    // ------------------------------- Errors ---------------------------------

    error IdentityAttestation__AlreadyInitialized();
    error IdentityAttestation__InvalidRoleManager();
    error IdentityAttestation__InvalidProviderId();
    error IdentityAttestation__InvalidSigner();
    error IdentityAttestation__ProviderNotAllowed();
    error IdentityAttestation__PayloadExpired();

    // ------------------------------ EIP-712 ---------------------------------

    // Flat encoding (no nested struct) to keep offchain signing simple.
    // Register(address account,uint16 jurisdiction,uint8 tier,uint32 flags,uint64 expiry,uint64 lockupUntil,uint32 providerId,uint256 nonce,uint64 deadline)
    bytes32 internal constant REGISTER_TYPEHASH =
        keccak256(
            "Register(address account,uint16 jurisdiction,uint8 tier,uint32 flags,uint64 expiry,uint64 lockupUntil,uint32 providerId,uint256 nonce,uint64 deadline)"
        );

    // ------------------------------ Storage ---------------------------------

    RoleManager public roleManager;

    // providerId => signer => allowed
    mapping(uint32 => mapping(address => bool)) private _provider;

    // account => providerId => nonce
    mapping(address => mapping(uint32 => uint256)) private _nonces;

    // account => latest effective payload
    mapping(address => IAgriIdentityAttestationV1.Payload) private _identity;

    bool private _initialized;

    // ------------------------------ Modifiers -------------------------------

    modifier onlyGovernance() {
        _requireGovernance();
        _;
    }

    // ------------------------------ Init ------------------------------------

    constructor(address roleManager_) EIP712("uAgri Identity Attestation", "1") {
        _init(roleManager_);
    }

    function initialize(address roleManager_) external {
        _init(roleManager_);
    }

    function _init(address roleManager_) internal {
        if (_initialized) revert IdentityAttestation__AlreadyInitialized();
        _initialized = true;

        if (roleManager_ == address(0)) revert IdentityAttestation__InvalidRoleManager();
        roleManager = RoleManager(roleManager_);
    }

    // --------------------------- Interface Views ----------------------------

    function isProvider(uint32 providerId, address signer) external view override returns (bool) {
        return _provider[providerId][signer];
    }

    function nonces(address account, uint32 providerId) external view override returns (uint256) {
        return _nonces[account][providerId];
    }

    function identityOf(address account)
        external
        view
        override
        returns (IAgriIdentityAttestationV1.Payload memory)
    {
        return _identity[account];
    }

    /// @notice Convenience: current EIP-712 domain separator.
    function domainSeparator() external view returns (bytes32) {
        return domainSeparatorV4();
    }

    // --------------------------- Provider Admin -----------------------------

    function setProvider(uint32 providerId, address signer, bool allowed) external override onlyGovernance {
        _setProvider(providerId, signer, allowed);
    }

    /// @notice Batch setter to load provider signers in a single tx.
    function setProviderBatch(uint32 providerId, address[] calldata signers, bool allowed) external onlyGovernance {
        if (providerId == 0) revert IdentityAttestation__InvalidProviderId();

        uint256 n = signers.length;
        for (uint256 i = 0; i < n; i++) {
            address s = signers[i];
            if (s == address(0)) revert IdentityAttestation__InvalidSigner();

            _provider[providerId][s] = allowed;
            emit ProviderSet(providerId, s, allowed);
        }
    }

    function _setProvider(uint32 providerId, address signer, bool allowed) internal {
        if (providerId == 0) revert IdentityAttestation__InvalidProviderId();
        if (signer == address(0)) revert IdentityAttestation__InvalidSigner();

        _provider[providerId][signer] = allowed;
        emit ProviderSet(providerId, signer, allowed);
    }

    // --------------------------- Attestation Flow ---------------------------

    function register(
        address account,
        IAgriIdentityAttestationV1.Payload calldata payload,
        uint64 deadline,
        bytes calldata sig
    ) external override {
        if (account == address(0)) revert UAgriErrors.UAgri__InvalidAddress();
        if (payload.providerId == 0) revert IdentityAttestation__InvalidProviderId();
        if (sig.length == 0) revert UAgriErrors.UAgri__InvalidSignature();

        uint64 nowTs = uint64(block.timestamp);

        // Deadline gating (0 = no deadline)
        if (deadline != 0 && nowTs > deadline) revert UAgriErrors.UAgri__DeadlineExpired();

        // Expiry sanity (0 allowed, but if set must be in the future)
        if (payload.expiry != 0 && payload.expiry <= nowTs) revert IdentityAttestation__PayloadExpired();

        uint32 pid = payload.providerId;
        uint256 nonce = _nonces[account][pid];

        bytes32 structHash = hashRegisterStruct(account, payload, nonce, deadline);
        bytes32 digest = _hashTypedDataV4(structHash);

        // Verification paths:
        // 1) If msg.sender is an allowlisted contract-signer for pid => EIP-1271 check
        // 2) Else => ECDSA recover (EOA) and require recovered is allowlisted for pid
        if (msg.sender.code.length != 0 && _provider[pid][msg.sender]) {
            // Contract-based signer (EIP-1271), must be the caller.
            bytes4 magic = IERC1271(msg.sender).isValidSignature(digest, sig);
            if (magic != 0x1626ba7e) revert UAgriErrors.UAgri__InvalidSignature();
        } else {
            address signer = digest.recover(sig);
            if (!_provider[pid][signer]) revert IdentityAttestation__ProviderNotAllowed();
        }

        // Store latest effective payload for the account
        _identity[account] = payload;

        // Consume nonce (per account/providerId)
        unchecked {
            _nonces[account][pid] = nonce + 1;
        }

        emit Registered(
            account,
            payload.jurisdiction,
            payload.tier,
            payload.flags,
            payload.expiry,
            payload.lockupUntil,
            pid
        );
    }

    // ------------------------------ DX Helpers ------------------------------

    /// @notice Pure struct-hash helper used for EIP-712 signing.
    /// @dev Backend can use this + domainSeparator to build digest, or just call hashRegister().
    function hashRegisterStruct(
        address account,
        IAgriIdentityAttestationV1.Payload calldata payload,
        uint256 nonce,
        uint64 deadline
    ) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                REGISTER_TYPEHASH,
                account,
                payload.jurisdiction,
                payload.tier,
                payload.flags,
                payload.expiry,
                payload.lockupUntil,
                payload.providerId,
                nonce,
                deadline
            )
        );
    }

    /// @notice Returns the EIP-712 digest that must be signed for the current on-chain nonce.
    function hashRegister(
        address account,
        IAgriIdentityAttestationV1.Payload calldata payload,
        uint64 deadline
    ) external view returns (bytes32 digest) {
        uint256 nonce = _nonces[account][payload.providerId];
        bytes32 structHash = hashRegisterStruct(account, payload, nonce, deadline);
        return _hashTypedDataV4(structHash);
    }

    /// @notice Same as hashRegister(), but also returns the nonce used (handy for backend logs).
    function hashRegisterWithNonce(
        address account,
        IAgriIdentityAttestationV1.Payload calldata payload,
        uint64 deadline
    ) external view returns (bytes32 digest, uint256 nonce) {
        nonce = _nonces[account][payload.providerId];
        bytes32 structHash = hashRegisterStruct(account, payload, nonce, deadline);
        digest = _hashTypedDataV4(structHash);
    }

    // ------------------------------ RBAC ------------------------------------

    function _requireGovernance() internal view {
        RoleManager rm = roleManager;
        address caller = msg.sender;

        if (
            rm.hasRole(UAgriRoles.DEFAULT_ADMIN_ROLE, caller) ||
            rm.hasRole(UAgriRoles.GOVERNANCE_ROLE, caller) ||
            rm.hasRole(UAgriRoles.COMPLIANCE_OFFICER_ROLE, caller)
        ) {
            return;
        }

        revert UAgriErrors.UAgri__Unauthorized();
    }
}
