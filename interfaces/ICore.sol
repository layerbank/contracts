// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "../library/Constant.sol";

interface ICore {
    /* ========== Event ========== */
    event MarketSupply(address user, address lToken, uint256 uAmount);
    event MarketRedeem(address user, address lToken, uint256 uAmount);

    event MarketListed(address lToken);
    event MarketEntered(address lToken, address account);
    event MarketExited(address lToken, address account);

    event CloseFactorUpdated(uint256 newCloseFactor);
    event CollateralFactorUpdated(address lToken, uint256 newCollateralFactor);
    event LiquidationIncentiveUpdated(uint256 newLiquidationIncentive);
    event SupplyCapUpdated(address indexed lToken, uint256 newSupplyCap);
    event BorrowCapUpdated(address indexed lToken, uint256 newBorrowCap);
    event KeeperUpdated(address newKeeper);
    event ValidatorUpdated(address newValidator);
    event LABDistributorUpdated(address newLABDistributor);
    event RebateDistributorUpdated(address newRebateDistributor);
    event LeveragerUpdated(address newLeverager);
    event FlashLoan(
        address indexed target,
        address indexed initiator,
        address indexed asset,
        uint256 amount,
        uint256 premium
    );

    function validator() external view returns (address);

    function rebateDistributor() external view returns (address);

    function allMarkets() external view returns (address[] memory);

    function marketListOf(address account) external view returns (address[] memory);

    function marketInfoOf(address lToken) external view returns (Constant.MarketInfo memory);

    function checkMembership(address account, address lToken) external view returns (bool);

    function accountLiquidityOf(
        address account
    ) external view returns (uint256 collateralInUSD, uint256 supplyInUSD, uint256 borrowInUSD);

    function closeFactor() external view returns (uint256);

    function liquidationIncentive() external view returns (uint256);

    function enterMarkets(address[] memory lTokens) external;

    function exitMarket(address lToken) external;

    function supply(address lToken, uint256 underlyingAmount) external payable returns (uint256);

    function supplyBehalf(address account, address lToken, uint256 underlyingAmount) external payable returns (uint256);

    function redeemToken(address lToken, uint256 lTokenAmount) external returns (uint256 redeemed);

    function redeemUnderlying(address lToken, uint256 underlyingAmount) external returns (uint256 redeemed);

    function borrow(address lToken, uint256 amount) external;

    function borrowBehalf(address borrower, address lToken, uint256 amount) external;

    function repayBorrow(address lToken, uint256 amount) external payable;

    function liquidateBorrow(
        address lTokenBorrowed,
        address lTokenCollateral,
        address borrower,
        uint256 amount
    ) external payable;

    function claimLab() external;

    function claimLab(address market) external;

    function transferTokens(address spender, address src, address dst, uint256 amount) external;

    function compoundLab(uint256 lockDuration) external;
}
