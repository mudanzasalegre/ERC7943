// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;


interface IAgriDistributionV1 {
    event RewardNotified(uint256 amount, uint64 liquidationId, bytes32 reportHash);
    event Claimed(address indexed account, uint256 amount);
    event PayoutRequested(
        bytes32 indexed ref,
        address indexed account,
        address indexed to,
        uint256 amount,
        bytes32 payoutRailHash,
        uint256 liquidationIdAtRequest
    );
    event PayoutConfirmed(bytes32 indexed ref, bytes32 indexed receiptHash);

    function rewardToken() external view returns (address);
    function shareToken() external view returns (address);

    function notifyReward(uint256 amount, uint64 liquidationId, bytes32 reportHash) external;

    function claim() external returns (uint256 paid);
    function claimFor(address account) external returns (uint256 paid);
    function claimToWithSig(
        address account,
        address to,
        uint256 maxAmount,
        uint64 deadline,
        bytes32 ref,
        bytes32 payoutRailHash,
        bytes calldata signature
    ) external returns (uint256 paid);
    function confirmPayout(bytes32 ref, bytes32 receiptHash) external;
    function pending(address account) external view returns (uint256);
}
