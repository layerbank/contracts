// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

interface ISaleLabDashboard {
    struct OverflowFarmUserInfo {
        uint256 totalPurchasedETH;
        uint256 refundETH;
        uint256 purchasedLAB;
        uint256 farmingRewardAmount;
        bool isWhitelist;
        bool claimed;
    }

    struct OverflowFarmInfo {
        uint256 raisingAmount; // target raising amount
        uint256 totalAmount; // total raised amount
        uint256 labPriceInETH;
        uint256 startTime;
        uint256 endTime;
        uint256 farmingRewardAPR;
        uint256 harvestTime;
    }

    function getOverflowFarmUserInfo(address user) external view returns (OverflowFarmUserInfo memory);
    function getOverflowFarmInfo() external view returns (OverflowFarmInfo memory);
}
