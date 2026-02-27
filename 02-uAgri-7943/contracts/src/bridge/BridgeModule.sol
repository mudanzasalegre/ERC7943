// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IAgriBridgeV1} from "../interfaces/v1/IAgriBridgeV1.sol";
import {RoleManager} from "../access/RoleManager.sol";
import {UAgriRoles} from "../interfaces/constants/UAgriRoles.sol";
import {UAgriErrors} from "../interfaces/constants/UAgriErrors.sol";

import {AgriShareToken} from "../core/AgriShareToken.sol";
import {ECDSA} from "../_shared/ECDSA.sol";

interface IERC1271 {
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4 magicValue);
}

/// @title BridgeModule
/// @notice Minimal bridge module: burn on source, mint on destination, replay-protected.
/// @dev Proof = EIP-712-ish digest signature (storage-based domain; clone-friendly).
contract BridgeModule is IAgriBridgeV1 {
    using ECDSA for bytes32;

    // --------------------------------- Errors ---------------------------------
    error BridgeModule__AlreadyInitialized();
    error BridgeModule__InvalidAddress();
    error BridgeModule__InvalidCampaign();
    error BridgeModule__InvalidAmount();
    error BridgeModule__InvalidChain();
    error BridgeModule__Unauthorized();
    error BridgeModule__BadProof();

    // ------------------------------ EIP-712-ish -------------------------------
    // keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
    bytes32 private constant _DOMAIN_TYPEHASH =
        0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f;

    // keccak256("BridgeIn(bytes32 campaignId,uint256 amount,uint256 srcChainId,address recipient,uint256 nonce,uint256 dstChainId)")
    bytes32 private constant _BRIDGEIN_TYPEHASH =
        0x58f3c94df3c9c7c44a7c8a2e538c60bd5d28b3b9232a1c76b2e25031e3b0dd2c;

    bytes32 private _HASHED_NAME;
    bytes32 private _HASHED_VERSION;

    // -------------------------------- Storage --------------------------------
    RoleManager public roleManager;
    AgriShareToken public token;
    bytes32 public campaignId;

    uint256 public outboundNonce;

    // replay key = keccak256(campaignId, srcChainId, nonce)
    mapping(bytes32 => bool) public consumedIn;

    bool private _initialized;

    // --------------------------------- Init ----------------------------------
    constructor(address roleManager_, address token_, bytes32 campaignId_) {
        _init(roleManager_, token_, campaignId_);
    }

    function initialize(address roleManager_, address token_, bytes32 campaignId_) external {
        _init(roleManager_, token_, campaignId_);
    }

    function _init(address roleManager_, address token_, bytes32 campaignId_) internal {
        if (_initialized) revert BridgeModule__AlreadyInitialized();
        _initialized = true;

        if (roleManager_ == address(0) || token_ == address(0)) revert BridgeModule__InvalidAddress();
        if (campaignId_ == bytes32(0)) revert BridgeModule__InvalidCampaign();

        roleManager = RoleManager(roleManager_);
        token = AgriShareToken(token_);
        campaignId = campaignId_;

        // clone-friendly domain params
        _HASHED_NAME = keccak256(bytes("uAgri BridgeModule"));
        _HASHED_VERSION = keccak256(bytes("1"));
    }

    // --------------------------------- Views ---------------------------------
    function domainSeparator() public view returns (bytes32) {
        return keccak256(abi.encode(_DOMAIN_TYPEHASH, _HASHED_NAME, _HASHED_VERSION, block.chainid, address(this)));
    }

    function hashBridgeIn(
        bytes32 campaignId_,
        uint256 amount,
        uint256 srcChainId,
        address recipient,
        uint256 nonce
    ) external view returns (bytes32 digest) {
        digest = _bridgeInDigest(campaignId_, amount, srcChainId, recipient, nonce);
    }

    // --------------------------------- Bridge --------------------------------
    function bridgeOut(
        bytes32 campaignId_,
        uint256 amount,
        uint256 dstChainId,
        address recipient
    ) external returns (uint256 nonce) {
        if (campaignId_ != campaignId) revert BridgeModule__InvalidCampaign();
        if (recipient == address(0)) revert BridgeModule__InvalidAddress();
        if (amount == 0) revert BridgeModule__InvalidAmount();
        if (dstChainId == 0 || dstChainId == block.chainid) revert BridgeModule__InvalidChain();

        // nonce is global to this module instance
        unchecked {
            nonce = ++outboundNonce;
        }

        // burn caller shares (module must be authorized in RoleManager for token burn)
        token.burn(msg.sender, amount);

        emit BridgeOut(msg.sender, campaignId_, amount, dstChainId, recipient, nonce);
    }

    function bridgeIn(
        bytes32 campaignId_,
        uint256 amount,
        uint256 srcChainId,
        address recipient,
        uint256 nonce,
        bytes calldata proof
    ) external {
        if (campaignId_ != campaignId) revert BridgeModule__InvalidCampaign();
        if (recipient == address(0)) revert BridgeModule__InvalidAddress();
        if (amount == 0) revert BridgeModule__InvalidAmount();
        if (srcChainId == 0) revert BridgeModule__InvalidChain();

        _authorizeBridgeIn(
            _replayKey(campaignId_, srcChainId, nonce),
            _bridgeInDigest(campaignId_, amount, srcChainId, recipient, nonce),
            proof
        );

        // mint to recipient (module must be authorized in RoleManager for token mint)
        token.mint(recipient, amount);

        emit BridgeIn(campaignId_, amount, srcChainId, recipient, nonce);
    }

    // -------------------------------- Internals ------------------------------
    function _verifyProof(bytes32 digest, bytes calldata proof) internal view returns (address signer) {
        // mode A: raw ECDSA signature => signer = recover(sig)
        if (proof.length == 64 || proof.length == 65) {
            signer = digest.recover(proof);
            if (signer == address(0)) revert BridgeModule__BadProof();
            return signer;
        }

        // mode B: (20 bytes signer) || signature
        if (proof.length <= 20) revert UAgriErrors.UAgri__InvalidSignature();

        signer = address(bytes20(proof[:20]));

        bytes calldata sig = proof[20:];

        if (signer.code.length != 0) {
            bytes4 magic = IERC1271(signer).isValidSignature(digest, sig);
            if (magic != 0x1626ba7e) revert UAgriErrors.UAgri__InvalidSignature();
        } else {
            address rec = digest.recover(sig);
            if (rec != signer) revert UAgriErrors.UAgri__InvalidSignature();
        }
    }

    function _authorizeBridgeIn(bytes32 replayKey, bytes32 digest, bytes calldata proof) internal {
        if (consumedIn[replayKey]) revert UAgriErrors.UAgri__Replay();

        address signer = _verifyProof(digest, proof);
        _requireBridgeSigner(signer);
        consumedIn[replayKey] = true;
    }

    function _replayKey(bytes32 campaignId_, uint256 srcChainId, uint256 nonce) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(campaignId_, srcChainId, nonce));
    }

    function _bridgeInDigest(
        bytes32 campaignId_,
        uint256 amount,
        uint256 srcChainId,
        address recipient,
        uint256 nonce
    ) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator(), _bridgeInStructHash(campaignId_, amount, srcChainId, recipient, nonce)));
    }

    function _bridgeInStructHash(
        bytes32 campaignId_,
        uint256 amount,
        uint256 srcChainId,
        address recipient,
        uint256 nonce
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encode(_BRIDGEIN_TYPEHASH, campaignId_, amount, srcChainId, recipient, nonce, block.chainid)
        );
    }

    function _requireBridgeSigner(address signer) internal view {
        RoleManager rm = roleManager;

        if (
            rm.hasRole(UAgriRoles.BRIDGE_OPERATOR_ROLE, signer) ||
            rm.hasRole(UAgriRoles.GOVERNANCE_ROLE, signer) ||
            rm.hasRole(UAgriRoles.DEFAULT_ADMIN_ROLE, signer)
        ) return;

        revert BridgeModule__Unauthorized();
    }
}
