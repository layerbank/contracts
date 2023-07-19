// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "../library/Constant.sol";

interface ICore {
    /* ========== Event ========== */
    event MarketSupply(address user, address gToken, uint256 uAmount);
    event MarketRedeem(address user, address gToken, uint256 uAmount);

    event MarketListed(address gToken);
    event MarketEntered(address gToken, address account);
    event MarketExited(address gToken, address account);

    event CloseFactorUpdated(uint256 newCloseFactor);
    event CollateralFactorUpdated(address gToken, uint256 newCollateralFactor);
    event LiquidationIncentiveUpdated(uint256 newLiquidationIncentive);
    event SupplyCapUpdated(address indexed gToken, uint256 newSupplyCap);
    event BorrowCapUpdated(address indexed gToken, uint256 newBorrowCap);
    event KeeperUpdated(address newKeeper);
    event NftCoreUpdated(address newNftCore);
    event ValidatorUpdated(address newValidator);
    event LABDistributorUpdated(address newLABDistributor);
    event RebateDistributorUpdated(address newRebateDistributor);
    event FlashLoan(
        address indexed target,
        address indexed initiator,
        address indexed asset,
        uint256 amount,
        uint256 premium
    );

    function nftCore() external view returns (address);

    function validator() external view returns (address);

    function rebateDistributor() external view returns (address);

    function allMarkets() external view returns (address[] memory);

    function marketListOf(
        address account
    ) external view returns (address[] memory);

    function marketInfoOf(
        address gToken
    ) external view returns (Constant.MarketInfo memory);

    function checkMembership(
        address account,
        address gToken
    ) external view returns (bool);

    function accountLiquidityOf(
        address account
    )
        external
        view
        returns (
            uint256 collateralInUSD,
            uint256 supplyInUSD,
            uint256 borrowInUSD
        );

    function closeFactor() external view returns (uint256);

    function liquidationIncentive() external view returns (uint256);

    function enterMarkets(address[] memory gTokens) external;

    function exitMarket(address gToken) external;

    function supply(
        address gToken,
        uint256 underlyingAmount
    ) external payable returns (uint256);

    function redeemToken(
        address gToken,
        uint256 gTokenAmount
    ) external returns (uint256 redeemed);

    function redeemUnderlying(
        address gToken,
        uint256 underlyingAmount
    ) external returns (uint256 redeemed);

    function borrow(address gToken, uint256 amount) external;

    function nftBorrow(address gToken, address user, uint256 amount) external;

    function repayBorrow(address gToken, uint256 amount) external payable;

    function nftRepayBorrow(
        address gToken,
        address user,
        uint256 amount
    ) external payable;

    function repayBorrowBehalf(
        address gToken,
        address borrower,
        uint256 amount
    ) external payable;

    function liquidateBorrow(
        address gTokenBorrowed,
        address gTokenCollateral,
        address borrower,
        uint256 amount
    ) external payable;

    function claimLab() external;

    function claimLab(address market) external;

    function transferTokens(
        address spender,
        address src,
        address dst,
        uint256 amount
    ) external;

    function compoundLab() external;
}
