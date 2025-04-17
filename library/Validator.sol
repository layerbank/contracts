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
    uint256 private constant DUST = 1000;

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

    /// @notice priceCalculator address 를 설정
    /// @dev ZERO ADDRESS 로 설정할 수 없음
    /// @param _priceCalculator priceCalculator contract address
    function setPriceCalculator(address _priceCalculator) public onlyOwner {
        require(_priceCalculator != address(0), "Validator: invalid priceCalculator address");
        oracle = IPriceCalculator(_priceCalculator);
    }

    /* ========== VIEWS ========== */

    /// @notice View collateral, supply, borrow value in USD of account
    /// @param account account address
    /// @return collateralInUSD Total collateral value in USD
    /// @return supplyInUSD Total supply value in USD
    /// @return borrowInUSD Total borrow value in USD
    function getAccountLiquidity(
        address account
    ) external view override returns (uint256 collateralInUSD, uint256 supplyInUSD, uint256 borrowInUSD) {
        collateralInUSD = 0;
        supplyInUSD = 0;
        borrowInUSD = 0;

        address[] memory assets = core.marketListOf(account);
        uint256[] memory prices = oracle.getUnderlyingPrices(assets);
        for (uint256 i = 0; i < assets.length; i++) {
            require(prices[i] != 0, "Validator: price error");
            uint256 decimals = _getDecimals(assets[i]);
            Constant.AccountSnapshot memory snapshot = ILToken(payable(assets[i])).accountSnapshot(account);

            uint256 priceCollateral;
            if (assets[i] == LAB && prices[i] > labPriceCollateralCap) {
                priceCollateral = labPriceCollateralCap;
            } else {
                priceCollateral = prices[i];
            }

            uint256 collateralFactor = core.marketInfoOf(payable(assets[i])).collateralFactor;
            uint256 collateralValuePerShareInUSD = snapshot.exchangeRate.mul(priceCollateral).mul(collateralFactor).div(
                1e36
            );

            collateralInUSD = collateralInUSD.add(
                snapshot.lTokenBalance.mul(10 ** (18 - decimals)).mul(collateralValuePerShareInUSD).div(1e18)
            );
            supplyInUSD = supplyInUSD.add(
                snapshot.lTokenBalance.mul(snapshot.exchangeRate).mul(10 ** (18 - decimals)).mul(prices[i]).div(1e36)
            );
            borrowInUSD = borrowInUSD.add(snapshot.borrowBalance.mul(10 ** (18 - decimals)).mul(prices[i]).div(1e18));
        }
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function setCore(address _core) external onlyOwner {
        require(_core != address(0), "Validator: invalid core address");
        require(address(core) == address(0), "Validator: core already set");
        core = ICore(_core);
    }

    /* ========== ALLOWED FUNCTIONS ========== */

    function redeemAllowed(address lToken, address redeemer, uint256 redeemAmount) external override returns (bool) {
        (, uint256 shortfall) = _getAccountLiquidityInternal(redeemer, lToken, redeemAmount, 0);
        return shortfall == 0;
    }

    function borrowAllowed(address lToken, address borrower, uint256 borrowAmount) external override returns (bool) {
        require(borrowAmount > DUST, "Validator: too small borrow amount");
        require(core.checkMembership(borrower, address(lToken)), "Validator: enterMarket required");
        require(oracle.getUnderlyingPrice(address(lToken)) > 0, "Validator: Underlying price error");

        // Borrow cap of 0 corresponds to unlimited borrowing
        uint256 borrowCap = core.marketInfoOf(lToken).borrowCap;
        if (borrowCap != 0) {
            uint256 totalBorrows = ILToken(payable(lToken)).accruedTotalBorrow();
            uint256 nextTotalBorrows = totalBorrows.add(borrowAmount);
            require(nextTotalBorrows < borrowCap, "Validator: market borrow cap reached");
        }

        (, uint256 shortfall) = _getAccountLiquidityInternal(borrower, lToken, 0, borrowAmount);
        return shortfall == 0;
    }

    function liquidateAllowed(
        address lToken,
        address borrower,
        uint256 liquidateAmount,
        uint256 closeFactor
    ) external override returns (bool) {
        // The borrower must have shortfall in order to be liquidate
        (, uint256 shortfall) = _getAccountLiquidityInternal(borrower, address(0), 0, 0);
        require(shortfall != 0, "Validator: Insufficient shortfall");

        // The liquidator may not repay more than what is allowed by the closeFactor
        uint256 borrowBalance = ILToken(payable(lToken)).accruedBorrowBalanceOf(borrower);
        uint256 maxClose = closeFactor.mul(borrowBalance).div(1e18);
        return liquidateAmount <= maxClose;
    }

    function lTokenAmountToSeize(
        address lTokenBorrowed,
        address lTokenCollateral,
        uint256 amount
    ) external override returns (uint256 seizeLAmount, uint256 rebateLAmount, uint256 liquidatorLAmount) {
        require(
            oracle.getUnderlyingPrice(lTokenBorrowed) != 0 && oracle.getUnderlyingPrice(lTokenCollateral) != 0,
            "Validator: price error"
        );

        uint256 exchangeRate = ILToken(payable(lTokenCollateral)).accruedExchangeRate();
        require(exchangeRate != 0, "Validator: exchangeRate of lTokenCollateral is zero");

        uint256 borrowedDecimals = _getDecimals(lTokenBorrowed);
        uint256 collateralDecimals = _getDecimals(lTokenCollateral);

        uint256 seizeLTokenAmountBase = amount
            .mul(10 ** (18 - borrowedDecimals))
            .mul(core.liquidationIncentive())
            .mul(oracle.getUnderlyingPrice(lTokenBorrowed))
            .div(oracle.getUnderlyingPrice(lTokenCollateral).mul(exchangeRate));

        seizeLAmount = seizeLTokenAmountBase.div(10 ** (18 - collateralDecimals));
        liquidatorLAmount = seizeLAmount;
        rebateLAmount = 0;
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    function _getAccountLiquidityInternal(
        address account,
        address lToken,
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
            Constant.AccountSnapshot memory snapshot = ILToken(payable(assets[i])).accruedAccountSnapshot(account);

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
                snapshot.lTokenBalance.mul(10 ** (18 - decimals)).mul(collateralValuePerShareInUSD).div(1e18)
            );
            accBorrowValueInUSD = accBorrowValueInUSD.add(
                snapshot.borrowBalance.mul(10 ** (18 - decimals)).mul(prices[i]).div(1e18)
            );

            if (assets[i] == lToken) {
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
        additionalBorrowValueInUSD = redeemAmount.mul(10 ** (18 - decimals)).mul(collateralValuePerShareInUSD).div(
            1e18
        );
        additionalBorrowValueInUSD = additionalBorrowValueInUSD.add(
            borrowAmount.mul(10 ** (18 - decimals)).mul(price).div(1e18)
        );
    }

    function _getDecimals(address lToken) internal view returns (uint256 decimals) {
        address underlying = ILToken(lToken).underlying();
        if (underlying == address(0)) {
            decimals = 18; // ETH
        } else {
            decimals = IBEP20(underlying).decimals();
        }
    }
}
