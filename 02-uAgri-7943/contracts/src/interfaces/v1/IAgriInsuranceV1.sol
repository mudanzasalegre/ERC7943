// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;


interface IAgriInsuranceV1 {
    event CompensationNotified(uint256 amount, uint64 epoch, bytes32 reasonHash);
    event CompensationClaimed(address indexed account, uint256 amount);

    function notifyCompensation(uint256 amount, uint64 epoch, bytes32 reasonHash) external;
    function claimCompensation() external returns (uint256 paid);
}
