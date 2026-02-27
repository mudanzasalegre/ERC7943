// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;


interface IAgriTreasuryV1 {
    event Paid(address indexed to, uint256 amount, bytes32 purpose);
    event InflowNoted(uint64 indexed epoch, uint256 amount, bytes32 reportHash);

    function settlementAsset() external view returns (address);
    function availableBalance() external view returns (uint256);

    function pay(address to, uint256 amount, bytes32 purpose) external;
    function noteInflow(uint64 epoch, uint256 amount, bytes32 reportHash) external;
}
