// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

interface IMarketDashboard {
    struct MarketData {
        address lToken;
        uint256 apySupply;
        uint256 apyBorrow;
        uint256 apySupplyLAB;
        uint256 apyBorrowLAB;
        uint256 totalSupply;
        uint256 totalBorrows;
        uint256 totalBoostedSupply;
        uint256 totalBoostedBorrow;
        uint256 cash;
        uint256 reserve;
        uint256 reserveFactor;
        uint256 collateralFactor;
        uint256 exchangeRate;
        uint256 borrowCap;
        uint256 accInterestIndex;
    }

    function marketDataOf(address market) external view returns (MarketData memory);

    function usersMonthlyProfit(
        address account
    )
        external
        view
        returns (
            uint256 supplyBaseProfits,
            uint256 supplyRewardProfits,
            uint256 borrowBaseProfits,
            uint256 borrowRewardProfits
        );
}
