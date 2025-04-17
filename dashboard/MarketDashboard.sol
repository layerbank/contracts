// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../interfaces/IMarketDashboard.sol";
import "../interfaces/ILABDistributor.sol";
import "../interfaces/IMarketView.sol";
import "../interfaces/ILToken.sol";
import "../interfaces/ICore.sol";
import "../interfaces/IBEP20.sol";
import "../interfaces/IPriceCalculator.sol";

contract MarketDashboard is IMarketDashboard, Ownable {
    using SafeMath for uint256;

    /* ========== STATE VARIABLES ========== */

    ILABDistributor public labDistributor;
    IMarketView public marketView;
    ICore public core;
    IPriceCalculator public priceCalculator;

    // initializer
    bool public initialized;

    /* ========== INITIALIZER ========== */

    constructor() public {}

    function initialize(
        address _core,
        address _labDistributor,
        address _marketView,
        address _priceCalculator
    ) external onlyOwner {
        require(initialized == false, "already initialized");
        require(_labDistributor != address(0), "MarketDashboard: labDistributor address can't be zero");
        require(_marketView != address(0), "MarketDashboard: MarketView address can't be zero");
        require(_core != address(0), "MarketDashboard: core address can't be zero");
        require(_priceCalculator != address(0), "MarketDashboard: priceCalculator address can't be zero");

        core = ICore(_core);
        labDistributor = ILABDistributor(_labDistributor);
        marketView = IMarketView(_marketView);
        priceCalculator = IPriceCalculator(_priceCalculator);

        initialized = true;
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function setDistributor(address _labDistributor) external onlyOwner {
        require(_labDistributor != address(0), "MarketDashboard: invalid labDistributor address");
        labDistributor = ILABDistributor(_labDistributor);
    }

    function setMarketView(address _marketView) external onlyOwner {
        require(_marketView != address(0), "MarketDashboard: invalid MarketView address");
        marketView = IMarketView(_marketView);
    }

    function setPriceCalculator(address _priceCalculator) external onlyOwner {
        require(_priceCalculator != address(0), "MarketDashboard: invalid priceCalculator address");
        priceCalculator = IPriceCalculator(_priceCalculator);
    }

    /* ========== VIEWS ========== */

    function marketDataOf(address market) external view override returns (MarketData memory) {
        MarketData memory marketData;
        Constant.DistributionAPY memory apyDistribution = labDistributor.apyDistributionOf(market, address(0));
        Constant.DistributionInfo memory distributionInfo = labDistributor.distributionInfoOf(market);
        ILToken lToken = ILToken(market);

        marketData.lToken = market;

        marketData.apySupply = marketView.supplyRatePerSec(market).mul(365 days);
        marketData.apyBorrow = marketView.borrowRatePerSec(market).mul(365 days);
        marketData.apySupplyLAB = apyDistribution.apySupplyLab;
        marketData.apyBorrowLAB = apyDistribution.apyBorrowLab;

        marketData.totalSupply = lToken.totalSupply().mul(lToken.exchangeRate()).div(1e18);
        marketData.totalBorrows = lToken.totalBorrow();
        marketData.totalBoostedSupply = distributionInfo.totalBoostedSupply;
        marketData.totalBoostedBorrow = distributionInfo.totalBoostedBorrow;

        marketData.cash = lToken.getCash();
        marketData.reserve = lToken.totalReserve();
        marketData.reserveFactor = lToken.reserveFactor();
        marketData.collateralFactor = core.marketInfoOf(market).collateralFactor;
        marketData.exchangeRate = lToken.exchangeRate();
        marketData.borrowCap = core.marketInfoOf(market).borrowCap;
        marketData.accInterestIndex = lToken.getAccInterestIndex();
        return marketData;
    }

    function usersMonthlyProfit(
        address account
    )
        external
        view
        override
        returns (
            uint256 supplyBaseProfits,
            uint256 supplyRewardProfits,
            uint256 borrowBaseProfits,
            uint256 borrowRewardProfits
        )
    {
        address[] memory markets = core.allMarkets();
        uint[] memory prices = priceCalculator.getUnderlyingPrices(markets);
        supplyBaseProfits = 0;
        supplyRewardProfits = 0;
        borrowBaseProfits = 0;
        borrowRewardProfits = 0;

        for (uint256 i = 0; i < markets.length; i++) {
            Constant.DistributionAPY memory apyDistribution = labDistributor.apyDistributionOf(markets[i], account);
            uint256 decimals = _getDecimals(markets[i]);
            {
                uint256 supplyBalance = ILToken(markets[i]).underlyingBalanceOf(account);
                uint256 supplyAPY = marketView.supplyRatePerSec(markets[i]).mul(365 days);
                uint256 supplyInUSD = supplyBalance.mul(10 ** (18 - decimals)).mul(prices[i]).div(1e18);
                uint256 supplyMonthlyProfit = supplyInUSD.mul(supplyAPY).div(12).div(1e18);
                uint256 supplyLABMonthlyProfit = supplyInUSD.mul(apyDistribution.apyAccountSupplyLab).div(12).div(1e18);

                supplyBaseProfits = supplyBaseProfits.add(supplyMonthlyProfit);
                supplyRewardProfits = supplyRewardProfits.add(supplyLABMonthlyProfit);
            }
            {
                uint256 borrowBalance = ILToken(markets[i]).borrowBalanceOf(account);
                uint256 borrowAPY = marketView.borrowRatePerSec(markets[i]).mul(365 days);
                uint256 borrowInUSD = borrowBalance.mul(10 ** (18 - decimals)).mul(prices[i]).div(1e18);
                uint256 borrowMonthlyProfit = borrowInUSD.mul(borrowAPY).div(12).div(1e18);
                uint256 borrowLABMonthlyProfit = borrowInUSD.mul(apyDistribution.apyAccountBorrowLab).div(12).div(1e18);

                borrowBaseProfits = borrowBaseProfits.add(borrowMonthlyProfit);
                borrowRewardProfits = borrowRewardProfits.add(borrowLABMonthlyProfit);
            }
        }
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    function _getDecimals(address lToken) internal view returns (uint256 decimals) {
        address underlying = ILToken(lToken).underlying();
        if (underlying == address(0)) {
            decimals = 18; // ETH
        } else {
            decimals = IBEP20(underlying).decimals();
        }
    }
}
