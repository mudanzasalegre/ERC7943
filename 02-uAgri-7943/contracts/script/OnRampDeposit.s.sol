// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {FundingManager} from "../src/campaign/FundingManager.sol";
import {IAgriModulesV1} from "../src/interfaces/v1/IAgriModulesV1.sol";

interface IERC20Like {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

contract OnRampDeposit is Script {
    function run() external {
        FundingManager fundingManager = FundingManager(vm.envAddress("FUNDING_MANAGER"));
        uint256 payerPk = vm.envUint("PAYER_PK");
        address payer = vm.addr(payerPk);
        address beneficiary = vm.envAddress("BENEFICIARY");
        uint256 assetsIn = vm.envUint("ASSETS_IN");
        uint256 minSharesOut = vm.envOr("MIN_SHARES_OUT", uint256(0));
        uint64 deadline = uint64(vm.envOr("DEADLINE", uint256(0)));
        bytes32 ref = _readRef();

        require(ref != bytes32(0), "REF_REQUIRED");

        address shareToken = fundingManager.shareToken();
        address settlementAsset = fundingManager.settlementAsset();
        address treasury = IAgriModulesV1(shareToken).treasury();

        vm.startBroadcast(payerPk);
        IERC20Like(settlementAsset).approve(address(fundingManager), assetsIn);
        uint256 sharesOut =
            fundingManager.settleDepositExactAssetsFrom(payer, beneficiary, assetsIn, minSharesOut, deadline, ref);
        vm.stopBroadcast();

        console2.log("fundingManager:", address(fundingManager));
        console2.log("payer:", payer);
        console2.log("beneficiary:", beneficiary);
        console2.log("settlementAsset:", settlementAsset);
        console2.log("treasury:", treasury);
        console2.logBytes32(ref);
        console2.log("sharesOut:", sharesOut);
        console2.log("refUsed:", fundingManager.usedSponsoredDepositRef(ref));
        console2.log("payerAsset:", IERC20Like(settlementAsset).balanceOf(payer));
        console2.log("treasuryAsset:", IERC20Like(settlementAsset).balanceOf(treasury));
        console2.log("beneficiaryShares:", IERC20Like(shareToken).balanceOf(beneficiary));
    }

    function _readRef() internal view returns (bytes32 out) {
        try vm.envBytes32("REF") returns (bytes32 v) {
            return v;
        } catch {}

        try vm.envString("REF_STR") returns (string memory s) {
            if (bytes(s).length != 0) return keccak256(bytes(s));
        } catch {}

        return bytes32(0);
    }
}
