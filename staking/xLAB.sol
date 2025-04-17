// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

import "./UntransferableERC20.sol";
import "../interfaces/IxLAB.sol";
import "../interfaces/ILABDistributor.sol";
import "../library/SafeToken.sol";

contract xLAB is IxLAB, Ownable, ReentrancyGuard, Pausable, UntransferableERC20 {
    using SafeMath for uint256;
    using SafeToken for address;

    /* ========== CONSTANTS ============= */

    uint256 public constant MAX_LOCK_DURATION = 2 * 365 days;
    uint256 public constant MIN_LOCK_DURATION = 7 days;
    uint256 public constant MAX_LOCK_COUNT = 100000;

    /* ========== STATE VARIABLES ========== */

    bool public initialized;
    address public LAB;
    ILABDistributor public labDistributor;
    mapping(address => User) private users;

    /* ========== EVENTS ========== */

    event Lock(address account, uint256 unlockTime, uint256 lockAmount, uint256 veAmount);
    event Unlock(address account, uint256 unlockTime, uint256 lockAmount, uint256 veAmount);
    event ExtendLock(
        address account,
        uint256 slot,
        uint256 unlockTime,
        uint256 lockedAmount,
        uint256 originalVeAmount,
        uint256 newVeAmount
    );

    /* ========== INITIALIZER ========== */

    constructor() public {
        __UntransferableERC20_init("xULAB", "xULAB");
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function initialize(address _lab, address _labDistributor) external onlyOwner {
        require(initialized == false, "xLAB: already initialized");
        require(_lab != address(0), "xLAB: invalid lab address");
        require(_labDistributor != address(0), "xLAB: invalid labDistributor address");

        LAB = _lab;
        labDistributor = ILABDistributor(_labDistributor);

        initialized = true;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /* ========== VIEWS ========== */

    function locksOf(address account) external view override returns (LockInfo[] memory) {
        return users[account].locks;
    }

    function balanceHistoryOf(address account) external view override returns (BalanceInfo[] memory) {
        return users[account].balanceHistory;
    }

    function calcVeAmount(uint256 amount, uint256 lockDuration) public pure override returns (uint256) {
        if (amount == 0 || lockDuration == 0) return uint256(0);
        return amount.mul(lockDuration).div(365 days);
    }

    function shareOf(address account) public view override returns (uint256) {
        uint256 total = totalSupply();
        uint256 balance = balanceOf(account);

        if (total == 0 || balance == 0) return uint256(0);
        return balance.mul(1e18).div(total);
    }

    function balanceOfAt(address account, uint256 timestamp) external view override returns (uint256) {
        uint256 count = users[account].balanceHistory.length;
        if (count == 0) return uint256(0);

        for (uint256 i = count - 1; i < uint256(-1); i--) {
            BalanceInfo memory history = users[account].balanceHistory[i];

            if (history.timestamp <= timestamp) {
                return history.balance;
            }
        }

        return uint256(0);
    }

    function lockedBalanceOf(address account) external view override returns (uint256 total) {
        LockInfo[] memory locks = users[account].locks;

        for (uint256 i = 0; i < locks.length; i++) {
            total = total.add(locks[i].lockedAmount);
        }
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function lock(uint256 amount, uint256 lockDuration) external override {
        _lock(msg.sender, amount, lockDuration);
    }

    function lockBehalf(address account, uint256 amount, uint256 lockDuration) external override {
        _lock(account, amount, lockDuration);
    }

    function unlock(uint256 slot) external override {
        _unlock(msg.sender, slot);
    }

    function unlockBehalf(address account, uint256 slot) external override {
        _unlock(account, slot);
    }

    function extendLock(uint256 slot, uint256 lockDuration) external override {
        _extendLock(msg.sender, slot, lockDuration);
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    function _lock(address account, uint256 amount, uint256 lockDuration) private nonReentrant whenNotPaused {
        require(amount > 0, "amount should greater than zero");
        require(lockDuration >= MIN_LOCK_DURATION && lockDuration <= MAX_LOCK_DURATION, "lockDuration is out of range");
        require(users[account].locks.length < MAX_LOCK_COUNT, "user lock count has reached full");

        uint256 unlockTime = block.timestamp + lockDuration;
        uint256 veAmount = calcVeAmount(amount, lockDuration);

        users[account].locks.push(LockInfo(uint48(unlockTime), amount, veAmount));

        LAB.safeTransferFrom(msg.sender, address(this), amount);

        _mint(account, veAmount);
        _updateUserBalanceHistory(account);
        _updateLABDistributorBoostedInfo(account);

        emit Lock(account, unlockTime, amount, veAmount);
    }

    function _unlock(address account, uint256 slot) private nonReentrant whenNotPaused {
        uint256 lockCount = users[account].locks.length;
        require(lockCount > 0, "no locks to unlock");
        require(slot < lockCount, "invalid slot");

        LockInfo memory lockInfo = users[account].locks[slot];
        require(uint256(lockInfo.unlockTime) <= block.timestamp, "unlock time is not over");

        if (slot != lockCount - 1) {
            users[account].locks[slot] = users[account].locks[lockCount - 1];
        }
        users[account].locks.pop();

        LAB.safeTransfer(account, lockInfo.lockedAmount);

        _burn(account, lockInfo.veAmount);
        _updateUserBalanceHistory(account);
        _updateLABDistributorBoostedInfo(account);

        emit Unlock(account, lockInfo.unlockTime, lockInfo.lockedAmount, lockInfo.veAmount);
    }

    function _extendLock(address account, uint256 slot, uint256 lockDuration) private nonReentrant whenNotPaused {
        require(lockDuration >= MIN_LOCK_DURATION && lockDuration <= MAX_LOCK_DURATION, "lockDuration is out of range");

        uint256 lockCount = users[account].locks.length;
        require(slot < lockCount, "invalid slot");

        uint256 originalUnlockTime = uint256(users[account].locks[slot].unlockTime);
        uint256 lockedAmount = uint256(users[account].locks[slot].lockedAmount);
        uint256 originalVeAmount = uint256(users[account].locks[slot].veAmount);
        uint256 newUnlockTime = block.timestamp + lockDuration;
        uint256 newVeAmount = calcVeAmount(lockedAmount, lockDuration);

        require(originalUnlockTime < newUnlockTime && originalVeAmount < newVeAmount, "invalid lockDuration");

        users[account].locks[slot].unlockTime = uint48(newUnlockTime);
        users[account].locks[slot].veAmount = newVeAmount;

        _mint(account, newVeAmount.sub(originalVeAmount));
        _updateUserBalanceHistory(account);
        _updateLABDistributorBoostedInfo(account);

        emit ExtendLock(account, slot, newUnlockTime, lockedAmount, originalVeAmount, newVeAmount);
    }

    function _updateUserBalanceHistory(address account) private {
        uint256 balance = balanceOf(account);
        users[account].balanceHistory.push(BalanceInfo(balance, block.timestamp));
    }

    function _updateLABDistributorBoostedInfo(address account) private {
        labDistributor.updateAccountBoostedInfo(account);
    }
}
