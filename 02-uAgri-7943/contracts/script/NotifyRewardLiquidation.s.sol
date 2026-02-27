// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

interface IYieldAccumulatorOps {
    function rewardToken() external view returns (address);
    function lastLiquidationId() external view returns (uint256);
    function nextLiquidationId() external view returns (uint256);
    function notifyReward(uint256 amount, uint64 liquidationId, bytes32 reportHash) external;
}

interface IERC20Balance {
    function balanceOf(address account) external view returns (uint256);
}

contract NotifyRewardLiquidation is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address caller = vm.addr(pk);

        IYieldAccumulatorOps yieldAcc = IYieldAccumulatorOps(vm.envAddress("YIELD_ACC"));
        uint256 amount = vm.envUint("AMOUNT");
        bytes32 reportHash = _readReportHash();
        uint256 liquidationId = _resolveLiquidationId(yieldAcc);

        require(reportHash != bytes32(0), "REPORT_HASH_REQUIRED");
        require(liquidationId != 0, "LIQUIDATION_ID_ZERO");
        require(liquidationId <= type(uint64).max, "LIQUIDATION_ID_TOO_LARGE");

        address rewardToken = yieldAcc.rewardToken();
        uint256 contractBalBefore = IERC20Balance(rewardToken).balanceOf(address(yieldAcc));

        vm.startBroadcast(pk);
        yieldAcc.notifyReward(amount, uint64(liquidationId), reportHash);
        vm.stopBroadcast();

        uint256 contractBalAfter = IERC20Balance(rewardToken).balanceOf(address(yieldAcc));

        console2.log("caller:", caller);
        console2.log("yieldAcc:", address(yieldAcc));
        console2.log("rewardToken:", rewardToken);
        console2.log("amount:", amount);
        console2.log("liquidationId:", liquidationId);
        console2.logBytes32(reportHash);
        console2.log("lastLiquidationId:", yieldAcc.lastLiquidationId());
        console2.log("contractBalBefore:", contractBalBefore);
        console2.log("contractBalAfter:", contractBalAfter);
    }

    function _resolveLiquidationId(IYieldAccumulatorOps yieldAcc) internal view returns (uint256 liquidationId) {
        try vm.envUint("LIQUIDATION_ID") returns (uint256 provided) {
            return provided;
        } catch {}
        return yieldAcc.nextLiquidationId();
    }

    function _readReportHash() internal view returns (bytes32 out) {
        try vm.envBytes32("REPORT_HASH") returns (bytes32 v) {
            if (v != bytes32(0)) return v;
        } catch {}
        try vm.envString("REPORT_HASH_STR") returns (string memory s) {
            if (bytes(s).length != 0) return keccak256(bytes(s));
        } catch {}
        return bytes32(0);
    }
}
