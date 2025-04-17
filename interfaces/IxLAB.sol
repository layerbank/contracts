// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

interface IxLAB {
    struct LockInfo {
        uint48 unlockTime;
        uint256 lockedAmount;
        uint256 veAmount;
    }

    struct BalanceInfo {
        uint256 balance;
        uint256 timestamp;
    }

    struct User {
        LockInfo[] locks;
        BalanceInfo[] balanceHistory;
    }

    function locksOf(address account) external view returns (LockInfo[] memory);

    function balanceHistoryOf(address account) external view returns (BalanceInfo[] memory);

    function calcVeAmount(uint256 amount, uint256 lockDuration) external pure returns (uint256);

    function shareOf(address account) external view returns (uint256);

    function balanceOfAt(address account, uint256 timestamp) external view returns (uint256);

    function lockedBalanceOf(address account) external view returns (uint256);

    function lock(uint256 amount, uint256 lockDuration) external;

    function lockBehalf(address account, uint256 amount, uint256 lockDuration) external;

    function unlock(uint256 slot) external;

    function unlockBehalf(address account, uint256 slot) external;

    function extendLock(uint256 slot, uint256 lockDuration) external;
}
