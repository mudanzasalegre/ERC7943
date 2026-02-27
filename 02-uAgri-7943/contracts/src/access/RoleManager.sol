// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/// @notice uAgri-7943 RBAC (own implementation, “standard-grade”).
/// @dev Features:
/// - Per-role admin (grant/revoke authority)
/// - Enumerable members per role (pagination via index)
/// - Two-step DEFAULT_ADMIN transfer with configurable delay (single-admin enforced by default)
/// - Optional “acceptance-required” role grants (two-step grants) for critical roles
/// - Two-step role-admin changes (propose/accept/cancel)
contract RoleManager {
    // ------------------------------- Errors ---------------------------------

    error RoleManager__InvalidAddress();
    error RoleManager__MissingRole(bytes32 role, address account);
    error RoleManager__NotRoleAdmin(bytes32 role, bytes32 adminRole, address caller);
    error RoleManager__RoleAlreadyGranted(bytes32 role, address account);
    error RoleManager__RoleNotGranted(bytes32 role, address account);
    error RoleManager__PendingGrantNotFound(bytes32 role, address account);
    error RoleManager__PendingGrantExists(bytes32 role, address account);
    error RoleManager__DefaultAdminEnforcedSingle();
    error RoleManager__DefaultAdminTransferNotPending();
    error RoleManager__DefaultAdminTransferTooEarly(uint64 notBefore);
    error RoleManager__DefaultAdminTransferWrongCaller(address expected);
    error RoleManager__RoleAdminChangeNotPending(bytes32 role);
    error RoleManager__IndexOutOfBounds();

    // ------------------------------- Events ---------------------------------

    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRenounced(bytes32 indexed role, address indexed account);

    event RoleAdminProposed(bytes32 indexed role, bytes32 indexed previousAdminRole, bytes32 indexed newAdminRole);
    event RoleAdminChanged(bytes32 indexed role, bytes32 indexed previousAdminRole, bytes32 indexed newAdminRole);
    event RoleAdminProposalCancelled(bytes32 indexed role, bytes32 indexed previousAdminRole, bytes32 indexed proposedAdminRole);

    event RoleGrantAcceptanceRequired(bytes32 indexed role, bool required);

    event RoleGrantProposed(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleGrantCancelled(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleGrantAccepted(bytes32 indexed role, address indexed account);
    event RoleGrantDeclined(bytes32 indexed role, address indexed account);

    event DefaultAdminTransferDelaySet(uint64 oldDelay, uint64 newDelay);
    event DefaultAdminTransferStarted(address indexed oldAdmin, address indexed newAdmin, uint64 notBefore);
    event DefaultAdminTransferCancelled(address indexed oldAdmin, address indexed pendingAdmin);
    event DefaultAdminTransferAccepted(address indexed oldAdmin, address indexed newAdmin);

    event SingleDefaultAdminEnforcementSet(bool enforced);

    // ------------------------------ Constants -------------------------------

    /// @dev Matches OZ: DEFAULT_ADMIN_ROLE == 0x00
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    // ------------------------------- Storage --------------------------------

    // role => account => granted
    mapping(bytes32 => mapping(address => bool)) private _hasRole;

    // role => adminRole
    mapping(bytes32 => bytes32) private _roleAdmin;

    // role enumeration
    mapping(bytes32 => address[]) private _roleMembers;
    mapping(bytes32 => mapping(address => uint256)) private _roleMemberIndexPlus1;

    // role => require acceptance on grants
    mapping(bytes32 => bool) private _grantRequiresAcceptance;

    // role => account => pendingGrant
    mapping(bytes32 => mapping(address => bool)) private _pendingGrant;

    // role admin change proposals (two-step)
    mapping(bytes32 => bytes32) private _pendingRoleAdmin;
    mapping(bytes32 => bool) private _hasPendingRoleAdmin;

    // Default admin (single-admin enforcement)
    bool private _enforceSingleDefaultAdmin = true;
    address private _defaultAdmin;

    // Two-step default admin transfer with delay
    address private _pendingDefaultAdmin;
    uint64 private _defaultAdminTransferNotBefore; // unix seconds
    uint64 private _defaultAdminTransferDelay;     // seconds

    // Initialization guard (useful if you later wrap via proxy/clones)
    bool private _initialized;

    // ------------------------------ Modifiers -------------------------------

    modifier onlyRole(bytes32 role) {
        _checkRole(role, msg.sender);
        _;
    }

    // --------------------------- Initialization -----------------------------

    constructor(address initialDefaultAdmin) {
        _init(initialDefaultAdmin);
    }

    /// @notice Optional initializer (for proxy/clones). Safe to call once.
    function initialize(address initialDefaultAdmin) external {
        if (_initialized) revert RoleManager__BadInit();
        _init(initialDefaultAdmin);
    }

    error RoleManager__BadInit();

    function _init(address initialDefaultAdmin) internal {
        if (_initialized) revert RoleManager__BadInit();
        _initialized = true;

        if (initialDefaultAdmin == address(0)) revert RoleManager__InvalidAddress();

        // Default admin is its own admin
        _roleAdmin[DEFAULT_ADMIN_ROLE] = DEFAULT_ADMIN_ROLE;

        _defaultAdmin = initialDefaultAdmin;
        _grantRoleImmediate(DEFAULT_ADMIN_ROLE, initialDefaultAdmin, address(0));

        // default delay = 0 (profiles may set >0)
        _defaultAdminTransferDelay = 0;
    }

    // ------------------------------ Views -----------------------------------

    function hasRole(bytes32 role, address account) public view returns (bool) {
        return _hasRole[role][account];
    }

    function getRoleAdmin(bytes32 role) public view returns (bytes32) {
        bytes32 adminRole = _roleAdmin[role];
        // If unset, default admin is the admin (safe default)
        return adminRole == bytes32(0) ? DEFAULT_ADMIN_ROLE : adminRole;
    }

    function defaultAdmin() external view returns (address) {
        return _defaultAdmin;
    }

    function pendingDefaultAdmin() external view returns (address) {
        return _pendingDefaultAdmin;
    }

    function defaultAdminTransferNotBefore() external view returns (uint64) {
        return _defaultAdminTransferNotBefore;
    }

    function defaultAdminTransferDelay() external view returns (uint64) {
        return _defaultAdminTransferDelay;
    }

    function singleDefaultAdminEnforced() external view returns (bool) {
        return _enforceSingleDefaultAdmin;
    }

    function roleGrantRequiresAcceptance(bytes32 role) external view returns (bool) {
        return _grantRequiresAcceptance[role];
    }

    function isPendingRoleGrant(bytes32 role, address account) external view returns (bool) {
        return _pendingGrant[role][account];
    }

    function roleMemberCount(bytes32 role) external view returns (uint256) {
        return _roleMembers[role].length;
    }

    function roleMember(bytes32 role, uint256 index) external view returns (address) {
        address[] storage m = _roleMembers[role];
        if (index >= m.length) revert RoleManager__IndexOutOfBounds();
        return m[index];
    }

    function pendingRoleAdmin(bytes32 role) external view returns (bytes32 proposed, bool pending) {
        return (_pendingRoleAdmin[role], _hasPendingRoleAdmin[role]);
    }

    // ------------------------- Admin configuration --------------------------

    /// @notice Enforce single DEFAULT_ADMIN member (recommended). Only default admin.
    function setSingleDefaultAdminEnforcement(bool enforced) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _enforceSingleDefaultAdmin = enforced;
        emit SingleDefaultAdminEnforcementSet(enforced);
    }

    /// @notice Set delay for two-step default admin transfer. Only default admin.
    function setDefaultAdminTransferDelay(uint64 newDelaySeconds) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint64 old = _defaultAdminTransferDelay;
        _defaultAdminTransferDelay = newDelaySeconds;
        emit DefaultAdminTransferDelaySet(old, newDelaySeconds);
    }

    /// @notice Require acceptance for grants of `role` (recommended for critical roles).
    function setRoleGrantAcceptanceRequired(bytes32 role, bool required) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRequiresAcceptance[role] = required;
        emit RoleGrantAcceptanceRequired(role, required);
    }

    // --------------------------- Default admin transfer ----------------------

    /// @notice Starts two-step default admin transfer. Only current default admin.
    function beginDefaultAdminTransfer(address newAdmin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newAdmin == address(0)) revert RoleManager__InvalidAddress();
        if (_enforceSingleDefaultAdmin) {
            // do not allow multi-admin via grant; must transfer
            // (transfer can still target same admin, harmless)
        }
        _pendingDefaultAdmin = newAdmin;

        uint64 notBefore = uint64(block.timestamp) + _defaultAdminTransferDelay;
        _defaultAdminTransferNotBefore = notBefore;

        emit DefaultAdminTransferStarted(_defaultAdmin, newAdmin, notBefore);
    }

    /// @notice Cancels a pending default admin transfer. Only current default admin.
    function cancelDefaultAdminTransfer() external onlyRole(DEFAULT_ADMIN_ROLE) {
        address pending = _pendingDefaultAdmin;
        if (pending == address(0)) revert RoleManager__DefaultAdminTransferNotPending();

        emit DefaultAdminTransferCancelled(_defaultAdmin, pending);

        _pendingDefaultAdmin = address(0);
        _defaultAdminTransferNotBefore = 0;
    }

    /// @notice Accepts default admin transfer. Only pending admin, and after delay.
    function acceptDefaultAdminTransfer() external {
        address pending = _pendingDefaultAdmin;
        if (pending == address(0)) revert RoleManager__DefaultAdminTransferNotPending();
        if (msg.sender != pending) revert RoleManager__DefaultAdminTransferWrongCaller(pending);

        uint64 notBefore = _defaultAdminTransferNotBefore;
        if (uint64(block.timestamp) < notBefore) revert RoleManager__DefaultAdminTransferTooEarly(notBefore);

        address old = _defaultAdmin;

        // update tracked default admin first (state)
        _defaultAdmin = pending;

        // clear pending
        _pendingDefaultAdmin = address(0);
        _defaultAdminTransferNotBefore = 0;

        // swap roles: revoke from old, grant to new
        _revokeRoleImmediate(DEFAULT_ADMIN_ROLE, old, msg.sender);
        _grantRoleImmediate(DEFAULT_ADMIN_ROLE, pending, msg.sender);

        emit DefaultAdminTransferAccepted(old, pending);
    }

    // ------------------------------- Role admin ------------------------------

    /// @notice Propose a new admin role for `role`. Caller must be current admin of `role`.
    /// @dev Acceptance is restricted to DEFAULT_ADMIN_ROLE for safety.
    function proposeRoleAdmin(bytes32 role, bytes32 newAdminRole) external {
        bytes32 adminRole = getRoleAdmin(role);
        if (!hasRole(adminRole, msg.sender)) revert RoleManager__NotRoleAdmin(role, adminRole, msg.sender);

        bytes32 prev = adminRole;
        _pendingRoleAdmin[role] = newAdminRole;
        _hasPendingRoleAdmin[role] = true;

        emit RoleAdminProposed(role, prev, newAdminRole);
    }

    /// @notice Accept admin-role change for `role`. Only DEFAULT_ADMIN_ROLE.
    function acceptRoleAdmin(bytes32 role) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!_hasPendingRoleAdmin[role]) revert RoleManager__RoleAdminChangeNotPending(role);

        bytes32 prev = getRoleAdmin(role);
        bytes32 next = _pendingRoleAdmin[role];

        _roleAdmin[role] = next;
        _hasPendingRoleAdmin[role] = false;
        _pendingRoleAdmin[role] = bytes32(0);

        emit RoleAdminChanged(role, prev, next);
    }

    /// @notice Cancel a pending admin-role change. Only DEFAULT_ADMIN_ROLE.
    function cancelRoleAdminProposal(bytes32 role) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!_hasPendingRoleAdmin[role]) revert RoleManager__RoleAdminChangeNotPending(role);

        bytes32 prev = getRoleAdmin(role);
        bytes32 proposed = _pendingRoleAdmin[role];

        _hasPendingRoleAdmin[role] = false;
        _pendingRoleAdmin[role] = bytes32(0);

        emit RoleAdminProposalCancelled(role, prev, proposed);
    }

    // ------------------------------ Grant / Revoke ---------------------------

    function grantRole(bytes32 role, address account) external {
        if (account == address(0)) revert RoleManager__InvalidAddress();

        // Enforce single default admin: never grant directly if already different
        if (role == DEFAULT_ADMIN_ROLE && _enforceSingleDefaultAdmin) {
            // Only allow "grant" to current default admin (idempotent); otherwise must transfer
            if (account != _defaultAdmin) revert RoleManager__DefaultAdminEnforcedSingle();
        }

        bytes32 adminRole = getRoleAdmin(role);
        if (!hasRole(adminRole, msg.sender)) revert RoleManager__NotRoleAdmin(role, adminRole, msg.sender);

        if (_hasRole[role][account]) revert RoleManager__RoleAlreadyGranted(role, account);

        if (_grantRequiresAcceptance[role]) {
            if (_pendingGrant[role][account]) revert RoleManager__PendingGrantExists(role, account);
            _pendingGrant[role][account] = true;
            emit RoleGrantProposed(role, account, msg.sender);
            return;
        }

        _grantRoleImmediate(role, account, msg.sender);
    }

    function revokeRole(bytes32 role, address account) external {
        if (account == address(0)) revert RoleManager__InvalidAddress();

        bytes32 adminRole = getRoleAdmin(role);
        if (!hasRole(adminRole, msg.sender)) revert RoleManager__NotRoleAdmin(role, adminRole, msg.sender);

        // If pending grant exists, cancel that instead of requiring it to be granted first.
        if (_pendingGrant[role][account]) {
            _pendingGrant[role][account] = false;
            emit RoleGrantCancelled(role, account, msg.sender);
            return;
        }

        if (!_hasRole[role][account]) revert RoleManager__RoleNotGranted(role, account);

        // Prevent revoking default admin if enforced single and it's the active default admin;
        // must transfer first.
        if (role == DEFAULT_ADMIN_ROLE && _enforceSingleDefaultAdmin && account == _defaultAdmin) {
            revert RoleManager__DefaultAdminEnforcedSingle();
        }

        _revokeRoleImmediate(role, account, msg.sender);
    }

    /// @notice Renounce a granted role.
    function renounceRole(bytes32 role) external {
        address account = msg.sender;

        // If it was only pending, allow clearing pending.
        if (_pendingGrant[role][account]) {
            _pendingGrant[role][account] = false;
            emit RoleGrantDeclined(role, account);
            return;
        }

        if (!_hasRole[role][account]) revert RoleManager__RoleNotGranted(role, account);

        // Prevent renouncing the active default admin when single enforced.
        if (role == DEFAULT_ADMIN_ROLE && _enforceSingleDefaultAdmin && account == _defaultAdmin) {
            revert RoleManager__DefaultAdminEnforcedSingle();
        }

        _revokeRoleImmediate(role, account, account);
        emit RoleRenounced(role, account);
    }

    // ------------------------- Two-step grant acceptance ---------------------

    function acceptRole(bytes32 role) external {
        address account = msg.sender;
        if (!_grantRequiresAcceptance[role]) {
            // If acceptance isn't required, treat as no-op error to avoid confusion.
            revert RoleManager__PendingGrantNotFound(role, account);
        }
        if (!_pendingGrant[role][account]) revert RoleManager__PendingGrantNotFound(role, account);

        _pendingGrant[role][account] = false;
        _grantRoleImmediate(role, account, account);
        emit RoleGrantAccepted(role, account);
    }

    function declineRole(bytes32 role) external {
        address account = msg.sender;
        if (!_pendingGrant[role][account]) revert RoleManager__PendingGrantNotFound(role, account);
        _pendingGrant[role][account] = false;
        emit RoleGrantDeclined(role, account);
    }

    function cancelRoleGrant(bytes32 role, address account) external {
        if (account == address(0)) revert RoleManager__InvalidAddress();

        bytes32 adminRole = getRoleAdmin(role);
        if (!hasRole(adminRole, msg.sender)) revert RoleManager__NotRoleAdmin(role, adminRole, msg.sender);

        if (!_pendingGrant[role][account]) revert RoleManager__PendingGrantNotFound(role, account);
        _pendingGrant[role][account] = false;
        emit RoleGrantCancelled(role, account, msg.sender);
    }

    // ------------------------------ Internals --------------------------------

    function _checkRole(bytes32 role, address account) internal view {
        if (!_hasRole[role][account]) revert RoleManager__MissingRole(role, account);
    }

    function _grantRoleImmediate(bytes32 role, address account, address sender) internal {
        _hasRole[role][account] = true;
        _addMember(role, account);
        emit RoleGranted(role, account, sender);
    }

    function _revokeRoleImmediate(bytes32 role, address account, address sender) internal {
        _hasRole[role][account] = false;
        _removeMember(role, account);
        emit RoleRevoked(role, account, sender);
    }

    function _addMember(bytes32 role, address account) internal {
        // idempotent safety (should already be checked)
        if (_roleMemberIndexPlus1[role][account] != 0) return;

        _roleMembers[role].push(account);
        _roleMemberIndexPlus1[role][account] = _roleMembers[role].length; // index + 1
    }

    function _removeMember(bytes32 role, address account) internal {
        uint256 idxPlus1 = _roleMemberIndexPlus1[role][account];
        if (idxPlus1 == 0) return;

        uint256 idx = idxPlus1 - 1;
        address[] storage arr = _roleMembers[role];
        uint256 last = arr.length - 1;

        if (idx != last) {
            address swap = arr[last];
            arr[idx] = swap;
            _roleMemberIndexPlus1[role][swap] = idx + 1;
        }

        arr.pop();
        _roleMemberIndexPlus1[role][account] = 0;
    }
}
