// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/// @title IAgriFreezeV1
/// @notice Freeze module boundary for uAgri-7943.
/// @dev V1 includes both the read path (ERC-7943 views) and the write path used by the token/admin.
interface IAgriFreezeV1 {
    // ---------- Introspection / wiring ----------

    /// @notice Current token allowed to call the token-only entrypoints.
    function token() external view returns (address);

    /// @notice RoleManager used for admin authorization inside the module.
    function roleManager() external view returns (address);

    /// @notice Update token wiring (governance/admin restricted inside implementation).
    function setToken(address newToken) external;

    // ---------- ERC-7943 read path ----------

    /// @notice Frozen amount for an account.
    function getFrozenTokens(address account) external view returns (uint256);

    // ---------- Token-only write path ----------

    /// @notice Set frozen amount for an account (callable by token only in implementation).
    function setFrozenTokensFromToken(address account, uint256 frozenAmount) external;

    /// @notice Batch set frozen amounts (callable by token only in implementation).
    function setFrozenTokensBatchFromToken(address[] calldata accounts, uint256[] calldata frozenAmounts) external;

    // ---------- Admin write path (optional but standard in the kit) ----------

    /// @notice Set frozen amount for an account (admin/regulator path).
    function setFrozenTokens(address account, uint256 frozenAmount) external;

    /// @notice Batch set frozen amounts (admin/regulator path).
    function setFrozenTokensBatch(address[] calldata accounts, uint256[] calldata frozenAmounts) external;
}
