// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../interfaces/IPriceCalculator.sol";
import "../interfaces/IValidator.sol";
import "../interfaces/ILToken.sol";
import "../interfaces/ICore.sol";
import "../interfaces/IBEP20.sol";
import "../library/Constant.sol";

contract Validator is IValidator, Ownable {
    using SafeMath for uint256;

    /* ========== CONSTANT VARIABLES ========== */

    IPriceCalculator public oracle;
    uint256 private constant labPriceCollateralCap = 75e15;

    /* ========== STATE VARIABLES ========== */

    ICore public core;
    address private LAB;

    bool public initialized;

    /* ========== INITIALIZER ========== */

    constructor() public {}

    function initialize(address _lab) external onlyOwner {
        require(initialized == false, "already initialized");

        LAB = _lab;

        initialized = true;
    }

    function setPriceCalculator(address _priceCalculator) public onlyOwner {
        require(
            _priceCalculator != address(0),
            "Validator: invalid priceCalculator address"
        );
        oracle = IPriceCalculator(_priceCalculator);
    }

    /* ========== VIEWS ========== */

    function getAccountLiquidity(
        address account
    )
        external
        view
        override
        returns (
            uint256 collateralInUSD,
            uint256 supplyInUSD,
            uint256 borrowInUSD
        )
    {
        collateralInUSD = 0;
        supplyInUSD = 0;
        borrowInUSD = 0;

        address[] memory assets = core.marketListOf(account);
        uint256[] memory prices = oracle.getUnderlyingPrices(assets);
        for (uint256 i = 0; i < assets.length; i++) {
            require(prices[i] != 0, "Validator: price error");
            uint256 decimals = _getDecimals(assets[i]);
            Constant.AccountSnapshot memory snapshot = ILToken(
                payable(assets[i])
            ).accountSnapshot(account);

            uint256 priceCollateral;
            if (assets[i] == LAB && prices[i] > labPriceCollateralCap) {
                priceCollateral = labPriceCollateralCap;
            } else {
                priceCollateral = prices[i];
            }

            uint256 collateralFactor = core
                .marketInfoOf(payable(assets[i]))
                .collateralFactor;
            uint256 collateralValuePerShareInUSD = snapshot
                .exchangeRate
                .mul(priceCollateral)
                .mul(collateralFactor)
                .div(1e36);

            collateralInUSD = collateralInUSD.add(
                snapshot
                    .gTokenBalance
                    .mul(10 ** (18 - decimals))
                    .mul(collateralValuePerShareInUSD)
                    .div(1e18)
            );
            supplyInUSD = supplyInUSD.add(
                snapshot
                    .gTokenBalance
                    .mul(snapshot.exchangeRate)
                    .mul(10 ** (18 - decimals))
                    .mul(prices[i])
                    .div(1e36)
            );
            borrowInUSD = borrowInUSD.add(
                snapshot
                    .borrowBalance
                    .mul(10 ** (18 - decimals))
                    .mul(prices[i])
                    .div(1e18)
            );
        }
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function setCore(address _core) external onlyOwner {
        require(_core != address(0), "Validator: invalid core address");
        require(address(core) == address(0), "Validator: core already set");
        core = ICore(_core);
    }

    /* ========== ALLOWED FUNCTIONS ========== */

    function redeemAllowed(
        address gToken,
        address redeemer,
        uint256 redeemAmount
    ) external override returns (bool) {
        (, uint256 shortfall) = _getAccountLiquidityInternal(
            redeemer,
            gToken,
            redeemAmount,
            0
        );
        return shortfall == 0;
    }

    function borrowAllowed(
        address gToken,
        address borrower,
        uint256 borrowAmount
    ) external override returns (bool) {
        require(
            core.checkMembership(borrower, address(gToken)),
            "Validator: enterMarket required"
        );
        require(
            oracle.getUnderlyingPrice(address(gToken)) > 0,
            "Validator: Underlying price error"
        );

        uint256 borrowCap = core.marketInfoOf(gToken).borrowCap;
        if (borrowCap != 0) {
            uint256 totalBorrows = ILToken(payable(gToken))
                .accruedTotalBorrow();
            uint256 nextTotalBorrows = totalBorrows.add(borrowAmount);
            require(
                nextTotalBorrows < borrowCap,
                "Validator: market borrow cap reached"
            );
        }

        (, uint256 shortfall) = _getAccountLiquidityInternal(
            borrower,
            gToken,
            0,
            borrowAmount
        );
        return shortfall == 0;
    }

    function liquidateAllowed(
        address gToken,
        address borrower,
        uint256 liquidateAmount,
        uint256 closeFactor
    ) external override returns (bool) {
        (, uint256 shortfall) = _getAccountLiquidityInternal(
            borrower,
            address(0),
            0,
            0
        );
        require(shortfall != 0, "Validator: Insufficient shortfall");

        uint256 borrowBalance = ILToken(payable(gToken)).accruedBorrowBalanceOf(
            borrower
        );
        uint256 maxClose = closeFactor.mul(borrowBalance).div(1e18);
        return liquidateAmount <= maxClose;
    }

    function gTokenAmountToSeize(
        address gTokenBorrowed,
        address gTokenCollateral,
        uint256 amount
    )
        external
        override
        returns (
            uint256 seizeGAmount,
            uint256 rebateGAmount,
            uint256 liquidatorGAmount
        )
    {
        require(
            oracle.getUnderlyingPrice(gTokenBorrowed) != 0 &&
                oracle.getUnderlyingPrice(gTokenCollateral) != 0,
            "Validator: price error"
        );

        uint256 exchangeRate = ILToken(payable(gTokenCollateral))
            .accruedExchangeRate();
        require(
            exchangeRate != 0,
            "Validator: exchangeRate of gTokenCollateral is zero"
        );

        uint256 borrowedDecimals = _getDecimals(gTokenBorrowed);
        uint256 collateralDecimals = _getDecimals(gTokenCollateral);

        uint256 seizeGTokenAmountBase = amount
            .mul(10 ** (18 - borrowedDecimals))
            .mul(core.liquidationIncentive())
            .mul(oracle.getUnderlyingPrice(gTokenBorrowed))
            .div(oracle.getUnderlyingPrice(gTokenCollateral).mul(exchangeRate));

        seizeGAmount = seizeGTokenAmountBase.div(
            10 ** (18 - collateralDecimals)
        );
        liquidatorGAmount = seizeGAmount;
        rebateGAmount = 0;
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    function _getAccountLiquidityInternal(
        address account,
        address gToken,
        uint256 redeemAmount,
        uint256 borrowAmount
    ) private returns (uint256 liquidity, uint256 shortfall) {
        uint256 accCollateralValueInUSD;
        uint256 accBorrowValueInUSD;

        address[] memory assets = core.marketListOf(account);
        uint256[] memory prices = oracle.getUnderlyingPrices(assets);
        for (uint256 i = 0; i < assets.length; i++) {
            uint256 decimals = _getDecimals(assets[i]);
            require(prices[i] != 0, "Validator: price error");
            Constant.AccountSnapshot memory snapshot = ILToken(
                payable(assets[i])
            ).accruedAccountSnapshot(account);

            uint256 collateralValuePerShareInUSD;
            if (assets[i] == LAB && prices[i] > labPriceCollateralCap) {
                collateralValuePerShareInUSD = snapshot
                    .exchangeRate
                    .mul(labPriceCollateralCap)
                    .mul(core.marketInfoOf(payable(assets[i])).collateralFactor)
                    .div(1e36);
            } else {
                collateralValuePerShareInUSD = snapshot
                    .exchangeRate
                    .mul(prices[i])
                    .mul(core.marketInfoOf(payable(assets[i])).collateralFactor)
                    .div(1e36);
            }

            accCollateralValueInUSD = accCollateralValueInUSD.add(
                snapshot
                    .gTokenBalance
                    .mul(10 ** (18 - decimals))
                    .mul(collateralValuePerShareInUSD)
                    .div(1e18)
            );
            accBorrowValueInUSD = accBorrowValueInUSD.add(
                snapshot
                    .borrowBalance
                    .mul(10 ** (18 - decimals))
                    .mul(prices[i])
                    .div(1e18)
            );

            if (assets[i] == gToken) {
                accBorrowValueInUSD = accBorrowValueInUSD.add(
                    _getAmountForAdditionalBorrowValue(
                        redeemAmount,
                        borrowAmount,
                        collateralValuePerShareInUSD,
                        prices[i],
                        decimals
                    )
                );
            }
        }

        liquidity = accCollateralValueInUSD > accBorrowValueInUSD
            ? accCollateralValueInUSD.sub(accBorrowValueInUSD)
            : 0;
        shortfall = accCollateralValueInUSD > accBorrowValueInUSD
            ? 0
            : accBorrowValueInUSD.sub(accCollateralValueInUSD);
    }

    function _getAmountForAdditionalBorrowValue(
        uint256 redeemAmount,
        uint256 borrowAmount,
        uint256 collateralValuePerShareInUSD,
        uint256 price,
        uint256 decimals
    ) internal pure returns (uint256 additionalBorrowValueInUSD) {
        additionalBorrowValueInUSD = redeemAmount
            .mul(10 ** (18 - decimals))
            .mul(collateralValuePerShareInUSD)
            .div(1e18);
        additionalBorrowValueInUSD = additionalBorrowValueInUSD.add(
            borrowAmount.mul(10 ** (18 - decimals)).mul(price).div(1e18)
        );
    }

    function _getDecimals(
        address gToken
    ) internal view returns (uint256 decimals) {
        address underlying = ILToken(gToken).underlying();
        if (underlying == address(0)) {
            decimals = 18;
        } else {
            decimals = IBEP20(underlying).decimals();
        }
    }
}
