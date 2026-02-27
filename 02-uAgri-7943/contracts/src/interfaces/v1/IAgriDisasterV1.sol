// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;


interface IAgriDisasterV1 {
    function campaignFlags(bytes32 campaignId) external view returns (uint256 flags);
    function isRestricted(bytes32 campaignId) external view returns (bool);
    function isHardFrozen(bytes32 campaignId) external view returns (bool);
}
