// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.6.12;

library Constant {
    uint256 public constant CLOSE_FACTOR_MIN = 5e16;
    uint256 public constant CLOSE_FACTOR_MAX = 9e17;
    uint256 public constant COLLATERAL_FACTOR_MAX = 9e17;
    uint256 public constant LIQUIDATION_THRESHOLD_MAX = 9e17;
    uint256 public constant LIQUIDATION_BONUS_MAX = 5e17;

    enum EcoScorePreviewOption {
        LOCK,
        CLAIM,
        EXTEND,
        LOCK_MORE
    }

    enum LoanState {
        None,
        Active,
        Auction,
        Repaid,
        Defaulted
    }

    struct MarketInfo {
        bool isListed;
        uint256 supplyCap;
        uint256 borrowCap;
        uint256 collateralFactor;
    }

    struct BorrowInfo {
        uint256 borrow;
        uint256 interestIndex;
    }

    struct AccountSnapshot {
        uint256 lTokenBalance;
        uint256 borrowBalance;
        uint256 exchangeRate;
    }

    struct AccrueSnapshot {
        uint256 totalBorrow;
        uint256 totalReserve;
        uint256 accInterestIndex;
    }

    struct AccrueLoanSnapshot {
        uint256 totalBorrow;
        uint256 accInterestIndex;
    }

    struct DistributionInfo {
        uint256 supplySpeed;
        uint256 borrowSpeed;
        uint256 totalBoostedSupply;
        uint256 totalBoostedBorrow;
        uint256 accPerShareSupply;
        uint256 accPerShareBorrow;
        uint256 accruedAt;
    }

    struct DistributionAccountInfo {
        uint256 accuredLAB; // Unclaimed LAB rewards amount
        uint256 boostedSupply; // effective(boosted) supply balance of user  (since last_action)
        uint256 boostedBorrow; // effective(boosted) borrow balance of user  (since last_action)
        uint256 accPerShareSupply; // Last integral value of LAB rewards per share. ∫(LABRate(t) / totalShare(t) dt) from 0 till (last_action)
        uint256 accPerShareBorrow; // Last integral value of LAB rewards per share. ∫(LABRate(t) / totalShare(t) dt) from 0 till (last_action)
    }

    struct DistributionAPY {
        uint256 apySupplyLab;
        uint256 apyBorrowLab;
        uint256 apyAccountSupplyLab;
        uint256 apyAccountBorrowLab;
    }

    struct RebateCheckpoint {
        uint256 timestamp;
        uint256 totalScore;
        uint256 adminFeeRate;
        uint256 weeklyLabSpeed;
        uint256 additionalLabAmount;
        mapping(address => uint256) marketFees;
    }

    struct LockInfo {
        uint256 timestamp;
        uint256 amount;
        uint256 expiry;
    }
}
