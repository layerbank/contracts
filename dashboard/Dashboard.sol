// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../interfaces/ILToken.sol";
import "../interfaces/ICore.sol";
import "../interfaces/IxLAB.sol";
import "../interfaces/ILABDistributor.sol";
import "../interfaces/IBEP20.sol";
import "../interfaces/IRebateDistributor.sol";
import "../interfaces/IPriceCalculator.sol";
import "../interfaces/IMarketView.sol";

contract Dashboard is Ownable {
    using SafeMath for uint256;

    struct BoostedAprDetails {
        address market;
        uint256 supplyAPR;
        uint256 borrowAPR;
        uint256 supplyRatio;
        uint256 borrowRatio;
        uint256 maxAPR;
        uint256 maxRatio;
    }

    /* ========== STATE VARIABLES ========== */

    ICore public core;
    IxLAB public xLAB;
    ILABDistributor public labDistributor;
    IRebateDistributor public rebateDistributor;
    IPriceCalculator public priceCalculator;
    IMarketView public marketView;

    uint public constant BOOST_MAX = 300;
    uint public constant BOOST_PORTION = 150;

    /* ========== INITIALIZER ========== */

    constructor(
        address _core,
        address _xlab,
        address _labDistributor,
        address _rebateDistributor,
        address _priceCalculator,
        address _marketView
    ) public {
        require(_core != address(0), "Dashboard: invalid core address");
        require(_xlab != address(0), "Dashboard: invalid xlab address");
        require(_labDistributor != address(0), "Dashboard: invalid labDistributor address");
        require(_rebateDistributor != address(0), "Dashboard: invalid rebateDistributor address");
        require(_priceCalculator != address(0), "Dashboard: invalid priceCalculator address");
        require(_marketView != address(0), "Dashboard: invalid marketView address");

        core = ICore(_core);
        xLAB = IxLAB(_xlab);
        labDistributor = ILABDistributor(_labDistributor);
        rebateDistributor = IRebateDistributor(_rebateDistributor);
        priceCalculator = IPriceCalculator(_priceCalculator);
        marketView = IMarketView(_marketView);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function userBalanceInfo(address account) public view returns (uint256 share, uint256 veBalance, uint256 total) {
        share = xLAB.shareOf(account);
        veBalance = IBEP20(address(xLAB)).balanceOf(account);
        total = IBEP20(address(xLAB)).totalSupply();
    }

    function userNextBalanceInfo(
        address account,
        uint256 additionalVeAmount
    ) public view returns (uint256 share, uint256 veBalance, uint total) {
        (, uint256 oldVeBalance, uint256 oldTotal) = userBalanceInfo(account);

        total = oldTotal.add(additionalVeAmount);
        veBalance = oldVeBalance.add(additionalVeAmount);
        share = veBalance.mul(1e18).div(total);
    }

    function getNextMaxBoostedApr(
        address account,
        uint256 additionalVeAmount
    ) external view returns (BoostedAprDetails memory) {
        (, uint256 nextVeAmount, uint256 nextToal) = userNextBalanceInfo(account, additionalVeAmount);
        return getMaxBoostedApr(account, nextVeAmount, nextToal);
    }

    function getMaxBoostedApr(
        address account,
        uint256 score,
        uint256 totalScore
    ) public view returns (BoostedAprDetails memory) {
        address[] memory markets = core.allMarkets();
        BoostedAprDetails memory maxAPRInfo;
        for (uint256 i = 0; i < markets.length; i++) {
            BoostedAprDetails memory aprDetailInfo = _calculateBoostedAprInfo(account, markets[i], score, totalScore);
            if (maxAPRInfo.maxAPR < aprDetailInfo.supplyAPR) {
                maxAPRInfo.maxAPR = aprDetailInfo.supplyAPR;
                maxAPRInfo.maxRatio = aprDetailInfo.supplyRatio;
            }
            if (maxAPRInfo.maxAPR < aprDetailInfo.borrowAPR) {
                maxAPRInfo.maxAPR = aprDetailInfo.borrowAPR;
                maxAPRInfo.maxRatio = aprDetailInfo.borrowRatio;
            }
        }
        return maxAPRInfo;
    }

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
                uint256 supplyGRVMonthlyProfit = supplyInUSD.mul(apyDistribution.apyAccountSupplyLab).div(12).div(1e18);

                supplyBaseProfits = supplyBaseProfits.add(supplyMonthlyProfit);
                supplyRewardProfits = supplyRewardProfits.add(supplyGRVMonthlyProfit);
            }
            {
                uint256 borrowBalance = ILToken(markets[i]).borrowBalanceOf(account);
                uint256 borrowAPY = marketView.borrowRatePerSec(markets[i]).mul(365 days);
                uint256 borrowInUSD = borrowBalance.mul(10 ** (18 - decimals)).mul(prices[i]).div(1e18);
                uint256 borrowMonthlyProfit = borrowInUSD.mul(borrowAPY).div(12).div(1e18);
                uint256 borrowGRVMonthlyProfit = borrowInUSD.mul(apyDistribution.apyAccountBorrowLab).div(12).div(1e18);

                borrowBaseProfits = borrowBaseProfits.add(borrowMonthlyProfit);
                borrowRewardProfits = borrowRewardProfits.add(borrowGRVMonthlyProfit);
            }
        }
    }

    function lockAPRInfo(
        uint256 amount
    )
        external
        view
        returns (
            uint256 lockAPR1Month,
            uint256 lockAPR3Month,
            uint256 lockAPR6Month,
            uint256 lockAPR9Month,
            uint256 lockAPR12Month,
            uint256 lockAPR24Month
        )
    {
        lockAPR1Month = rebateDistributor.indicativeAPROf(amount, 30 days);
        lockAPR3Month = rebateDistributor.indicativeAPROf(amount, 90 days);
        lockAPR6Month = rebateDistributor.indicativeAPROf(amount, 180 days);
        lockAPR9Month = rebateDistributor.indicativeAPROf(amount, 270 days);
        lockAPR12Month = rebateDistributor.indicativeAPROf(amount, 365 days);
        lockAPR24Month = rebateDistributor.indicativeAPROf(amount, 730 days);
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    function _calculatePreBoostedSupply(
        address market,
        address user,
        uint256 userScore,
        uint256 totalScore
    ) private view returns (uint) {
        uint defaultSupply = ILToken(market).balanceOf(user);
        uint boostedSupply = defaultSupply;

        if (userScore > 0 && totalScore > 0) {
            uint scoreBoosted = ILToken(market).totalSupply().mul(userScore).div(totalScore).mul(BOOST_PORTION).div(
                100
            );
            boostedSupply = boostedSupply.add(scoreBoosted);
        }
        return Math.min(boostedSupply, defaultSupply.mul(BOOST_MAX).div(100));
    }

    function _calculatePreBoostedBorrow(
        address market,
        address user,
        uint256 userScore,
        uint256 totalScore
    ) private view returns (uint) {
        uint accInterestIndex = ILToken(market).getAccInterestIndex();
        uint defaultBorrow = ILToken(market).borrowBalanceOf(user).mul(1e18).div(accInterestIndex);
        uint boostedBorrow = defaultBorrow;

        if (userScore > 0 && totalScore > 0) {
            uint totalBorrow = ILToken(market).totalBorrow().mul(1e18).div(accInterestIndex);
            uint scoreBoosted = totalBorrow.mul(userScore).div(totalScore).mul(BOOST_PORTION).div(100);
            boostedBorrow = boostedBorrow.add(scoreBoosted);
        }
        return Math.min(boostedBorrow, defaultBorrow.mul(BOOST_MAX).div(100));
    }

    function _getBoostedInfo(
        address market,
        address user,
        uint256 userScore,
        uint256 totalScore
    ) private view returns (uint256 boostedSupply, uint256 boostedBorrow) {
        boostedSupply = _calculatePreBoostedSupply(market, user, userScore, totalScore);
        boostedBorrow = _calculatePreBoostedBorrow(market, user, userScore, totalScore);
    }

    function _calculateBoostedAprInfo(
        address account,
        address market,
        uint256 score,
        uint256 totalScore
    ) private view returns (BoostedAprDetails memory) {
        BoostedAprDetails memory aprDetailInfo;
        aprDetailInfo.market = market;
        Constant.DistributionAPY memory apyDistribution = labDistributor.apyDistributionOf(market, account);
        {
            uint256 accountSupply = ILToken(market).balanceOf(account);
            uint256 accountBorrow = ILToken(market).borrowBalanceOf(account).mul(1e18).div(
                ILToken(market).getAccInterestIndex()
            );

            (uint256 preBoostedSupply, uint256 preBoostedBorrow) = _getBoostedInfo(market, account, score, totalScore);
            uint256 expectedApyAccountSupplyGRV = accountSupply > 0
                ? apyDistribution.apySupplyLab.mul(preBoostedSupply).div(accountSupply)
                : 0;

            uint256 expectedApyAccountBorrowGRV = accountBorrow > 0
                ? apyDistribution.apyBorrowLab.mul(preBoostedBorrow).div(accountBorrow)
                : 0;

            uint256 boostedSupplyRatio = accountSupply > 0 ? preBoostedSupply.mul(1e18).div(accountSupply) : 0;
            uint256 boostedBorrowRatio = accountBorrow > 0 ? preBoostedBorrow.mul(1e18).div(accountBorrow) : 0;
            aprDetailInfo.supplyAPR = expectedApyAccountSupplyGRV;
            aprDetailInfo.borrowAPR = expectedApyAccountBorrowGRV;
            aprDetailInfo.supplyRatio = boostedSupplyRatio;
            aprDetailInfo.borrowRatio = boostedBorrowRatio;
        }
        return aprDetailInfo;
    }

    function _getDecimals(address lToken) private view returns (uint256 decimals) {
        address underlying = ILToken(lToken).underlying();
        if (underlying == address(0)) {
            decimals = 18;
        } else {
            decimals = IBEP20(underlying).decimals();
        }
    }
}
