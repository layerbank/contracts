// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.6.12;

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../../interfaces/IRateModel.sol";

contract RateModelSlope is IRateModel, Ownable {
    using SafeMath for uint256;

    uint256 private baseRatePerYear;
    uint256 private slopePerYearFirst;
    uint256 private slopePerYearSecond;
    uint256 private optimal;

    bool public initialized;

    constructor() public {}

    function initialize(
        uint256 _baseRatePerYear,
        uint256 _slopePerYearFirst,
        uint256 _slopePerYearSecond,
        uint256 _optimal
    ) external onlyOwner {
        require(initialized == false, "already initialized");
        baseRatePerYear = _baseRatePerYear;
        slopePerYearFirst = _slopePerYearFirst;
        slopePerYearSecond = _slopePerYearSecond;
        optimal = _optimal;

        initialized = true;
    }

    function utilizationRate(
        uint256 cash,
        uint256 borrows,
        uint256 reserves
    ) public pure returns (uint256) {
        if (reserves >= cash.add(borrows)) return 0;
        return
            Math.min(
                borrows.mul(1e18).div(cash.add(borrows).sub(reserves)),
                1e18
            );
    }

    function getBorrowRate(
        uint256 cash,
        uint256 borrows,
        uint256 reserves
    ) public view override returns (uint256) {
        uint256 utilization = utilizationRate(cash, borrows, reserves);
        if (optimal > 0 && utilization < optimal) {
            return
                baseRatePerYear
                    .add(utilization.mul(slopePerYearFirst).div(optimal))
                    .div(365 days);
        } else {
            uint256 ratio = utilization.sub(optimal).mul(1e18).div(
                uint256(1e18).sub(optimal)
            );
            return
                baseRatePerYear
                    .add(slopePerYearFirst)
                    .add(ratio.mul(slopePerYearSecond).div(1e18))
                    .div(365 days);
        }
    }

    function getSupplyRate(
        uint256 cash,
        uint256 borrows,
        uint256 reserves,
        uint256 reserveFactor
    ) public view override returns (uint256) {
        uint256 oneMinusReserveFactor = uint256(1e18).sub(reserveFactor);
        uint256 borrowRate = getBorrowRate(cash, borrows, reserves);
        uint256 rateToPool = borrowRate.mul(oneMinusReserveFactor).div(1e18);
        return
            utilizationRate(cash, borrows, reserves).mul(rateToPool).div(1e18);
    }
}
