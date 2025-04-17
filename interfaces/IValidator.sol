// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

interface IValidator {
    function redeemAllowed(address lToken, address redeemer, uint256 redeemAmount) external returns (bool);

    function borrowAllowed(address lToken, address borrower, uint256 borrowAmount) external returns (bool);

    function liquidateAllowed(
        address lTokenBorrowed,
        address borrower,
        uint256 repayAmount,
        uint256 closeFactor
    ) external returns (bool);

    function lTokenAmountToSeize(
        address lTokenBorrowed,
        address lTokenCollateral,
        uint256 actualRepayAmount
    ) external returns (uint256 seizeLAmount, uint256 rebateLAmount, uint256 liquidatorLAmount);

    function getAccountLiquidity(
        address account
    ) external view returns (uint256 collateralInUSD, uint256 supplyInUSD, uint256 borrowInUSD);
}
