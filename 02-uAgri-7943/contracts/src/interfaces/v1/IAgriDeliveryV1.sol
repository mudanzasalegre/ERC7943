// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;


interface IAgriDeliveryV1 {
    event DeliveryRequested(address indexed account, uint256 sharesBurned, uint256 receiptId, bytes32 lotId, bytes32 termsHash);

    function redeemToReceipt(uint256 shares, uint256 receiptId, bytes32 lotId, bytes32 termsHash) external;
}
