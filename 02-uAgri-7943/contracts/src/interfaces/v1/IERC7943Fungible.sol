// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;


interface IERC165 {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

interface IERC7943Fungible is IERC165 {
    function canTransact(address account) external view returns (bool);
    function canTransfer(address from, address to, uint256 amount) external view returns (bool);
    function getFrozenTokens(address account) external view returns (uint256);

    function setFrozenTokens(address account, uint256 amount) external;
    function forcedTransfer(address from, address to, uint256 amount) external;

    event Frozen(address indexed account, uint256 amount);
    event ForcedTransfer(address indexed from, address indexed to, uint256 amount);
}
