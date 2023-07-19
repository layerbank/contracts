// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/SafeMath.sol";

import "../interfaces/ISaleLabDashboard.sol";
import "../interfaces/ISaleLabOverflowFarm.sol";

contract SaleLabDashboard is ISaleLabDashboard {
    using SafeMath for uint256;

    ISaleLabOverflowFarm public saleLabOverflowFarm;

    constructor(address _saleLabOverflowFarm) public {
        saleLabOverflowFarm = ISaleLabOverflowFarm(_saleLabOverflowFarm);
    }

    function getOverflowFarmUserInfo(
        address user
    ) external view override returns (OverflowFarmUserInfo memory) {
        address _user = user;

        (uint256 _totalPurchasedETH, bool _claimed, ) = saleLabOverflowFarm
            .userInfo(_user);

        uint256 _refundETH = saleLabOverflowFarm.getRefundingAmount(_user);
        bool _isWhitelist = saleLabOverflowFarm.whitelist(_user);

        uint256 _purchasedLAB = saleLabOverflowFarm.getOfferingAmount(_user);
        uint256 _farmingRewardAmount = saleLabOverflowFarm.pendingReward(_user);

        OverflowFarmUserInfo memory overflowFarmInfo = OverflowFarmUserInfo({
            totalPurchasedETH: _totalPurchasedETH,
            refundETH: _refundETH,
            purchasedLAB: _purchasedLAB,
            farmingRewardAmount: _farmingRewardAmount,
            isWhitelist: _isWhitelist,
            claimed: _claimed
        });

        return overflowFarmInfo;
    }

    function getOverflowFarmInfo()
        external
        view
        override
        returns (OverflowFarmInfo memory)
    {
        uint256 _offeringAmount = saleLabOverflowFarm.offeringAmount();
        uint256 _raisingAmount = saleLabOverflowFarm.raisingAmount();

        uint256 _labPriceInETH = 0;
        if (_raisingAmount == 0) {
            _labPriceInETH = uint256(1e17).mul(1e18).div(_offeringAmount);
        } else {
            _labPriceInETH = _raisingAmount.mul(1e18).div(_offeringAmount);
        }

        uint256 _rewardPerSecond = saleLabOverflowFarm.rewardPerSecond();
        uint256 _dayReward = _rewardPerSecond.mul(86400);
        uint256 _totalSupply = saleLabOverflowFarm.totalAmount();

        if (_totalSupply == 0) {
            _totalSupply = 1e18;
        }

        uint256 _ethPriceInUSD = 1850e18;
        uint256 _labPriceInUSD = 1e17;

        uint256 _rewardValueInUSD = _labPriceInUSD.mul(_dayReward).div(1e18);
        uint256 _stakedValueInUSD = _ethPriceInUSD.mul(_totalSupply).div(1e18);

        uint256 _dayProfit = _rewardValueInUSD.mul(1e18).div(_stakedValueInUSD);
        uint256 _apr = _dayProfit.mul(365);

        OverflowFarmInfo memory overflowFarmInfo = OverflowFarmInfo({
            raisingAmount: _raisingAmount,
            totalAmount: saleLabOverflowFarm.totalAmount(),
            labPriceInETH: _labPriceInETH,
            startTime: saleLabOverflowFarm.startTime(),
            endTime: saleLabOverflowFarm.endTime(),
            farmingRewardAPR: _apr,
            harvestTime: saleLabOverflowFarm.harvestTime()
        });
        return overflowFarmInfo;
    }
}
