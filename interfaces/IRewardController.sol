// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

interface IRewardController {
    struct LockedBalance {
        uint256 amount;
        uint256 unlockTime;
        uint256 duration;
    }

    struct EarnedBalance {
        uint256 amount;
        uint256 unlockTime;
        uint256 penalty;
    }

    struct Balances {
        uint256 total; // sum of earnings and lockings;
        uint256 unlocked; // LAB token
        uint256 earned; // LAB token
    }

    event RewardPaid(address indexed user, uint256 reward);

    function mint(address user, uint256 amount, bool withPenalty) external;
    function withdraw(uint256 amount) external;
    function individualEarlyExit(uint256 unlockTime) external;
    function exit() external;

    function earnedBalances(
        address user
    ) external view returns (uint256 total, uint256 unlocked, EarnedBalance[] memory earningsData);
    function withdrawableBalance(
        address user
    ) external view returns (uint256 amount, uint256 penaltyAmount, uint256 burnAmount);
}
