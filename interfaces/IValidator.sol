// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

interface IValidator {
    function redeemAllowed(
        address gToken,
        address redeemer,
        uint256 redeemAmount
    ) external returns (bool);

    function borrowAllowed(
        address gToken,
        address borrower,
        uint256 borrowAmount
    ) external returns (bool);

    function liquidateAllowed(
        address gTokenBorrowed,
        address borrower,
        uint256 repayAmount,
        uint256 closeFactor
    ) external returns (bool);

    function gTokenAmountToSeize(
        address gTokenBorrowed,
        address gTokenCollateral,
        uint256 actualRepayAmount
    )
        external
        returns (
            uint256 seizeGAmount,
            uint256 rebateGAmount,
            uint256 liquidatorGAmount
        );

    function getAccountLiquidity(
        address account
    )
        external
        view
        returns (
            uint256 collateralInUSD,
            uint256 supplyInUSD,
            uint256 borrowInUSD
        );
}
