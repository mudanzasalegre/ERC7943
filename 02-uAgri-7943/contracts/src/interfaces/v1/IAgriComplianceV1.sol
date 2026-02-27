// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;


interface IAgriComplianceV1 {
    function canTransact(address account) external view returns (bool ok);
    function canTransfer(address from, address to, uint256 amount) external view returns (bool ok);
    function transferStatus(address from, address to, uint256 amount) external view returns (bool ok, uint8 code);
}
