// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

import "../library/SafeToken.sol";
import "../interfaces/IBEP20.sol";
import "../interfaces/ILABDistributor.sol";
import "../interfaces/IxLAB.sol";
import "../interfaces/ILToken.sol";
import "../interfaces/ICore.sol";
import "../interfaces/IPriceCalculator.sol";
import "../interfaces/IRewardController.sol";

contract LABDistributor is ILABDistributor, Ownable, ReentrancyGuard, Pausable {
    using SafeMath for uint256;
    using SafeToken for address;

    /* ========== CONSTANT VARIABLES ========== */

    uint public constant BOOST_PORTION = 150;
    uint public constant BOOST_MAX = 300;
    uint private constant LAUNCH_TIMESTAMP = 1698624000;
    uint256 private constant XLAB_MIN_LOCK_DURATION = 7 days;

    /* ========== STATE VARIABLES ========== */

    address public LAB;
    ICore public core;
    IxLAB public xLAB;
    IPriceCalculator public priceCalculator;
    IRewardController public rewardController;

    bool public initialized;
    uint256 public compoundMinLockDuration;

    mapping(address => Constant.DistributionInfo) public distributions;
    mapping(address => mapping(address => Constant.DistributionAccountInfo)) public accountDistributions;

    /* ========== MODIFIERS ========== */

    modifier updateDistributionOf(address market) {
        Constant.DistributionInfo storage dist = distributions[market];
        if (dist.accruedAt == 0) {
            dist.accruedAt = block.timestamp;
        }

        uint timeElapsed = block.timestamp > dist.accruedAt ? block.timestamp.sub(dist.accruedAt) : 0;
        if (timeElapsed > 0) {
            if (dist.totalBoostedSupply > 0) {
                dist.accPerShareSupply = dist.accPerShareSupply.add(
                    dist.supplySpeed.mul(timeElapsed).mul(1e18).div(dist.totalBoostedSupply)
                );
            }

            if (dist.totalBoostedBorrow > 0) {
                dist.accPerShareBorrow = dist.accPerShareBorrow.add(
                    dist.borrowSpeed.mul(timeElapsed).mul(1e18).div(dist.totalBoostedBorrow)
                );
            }
        }
        dist.accruedAt = block.timestamp;
        _;
    }

    modifier onlyCore() {
        require(msg.sender == address(core), "LABDistributor: caller is not Core");
        _;
    }

    /* ========== EVENTS ========== */

    constructor() public {}

    function initialize(address _lab, address _core, address _xlab, address _priceCalculator) external onlyOwner {
        require(initialized == false, "already initialized");
        require(_lab != address(0), "LABDistributor: lab address can't be zero");
        require(_core != address(0), "LABDistributor: core address can't be zero");
        require(_xlab != address(0), "LABDistributor: xlab address can't be zero");
        require(_priceCalculator != address(0), "LABDistributor: priceCalculator address can't be zero");
        require(address(xLAB) == address(0), "LABDistributor: xlab already set");
        require(address(core) == address(0), "LABDistributor: core already set");

        LAB = _lab;
        core = ICore(_core);
        xLAB = IxLAB(_xlab);
        priceCalculator = IPriceCalculator(_priceCalculator);
        compoundMinLockDuration = 90 days;
        initialized = true;
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function setDistributionSpeed(
        address qToken,
        uint supplySpeed,
        uint borrowSpeed
    ) external onlyOwner updateDistributionOf(qToken) {
        Constant.DistributionInfo storage dist = distributions[qToken];
        dist.supplySpeed = supplySpeed;
        dist.borrowSpeed = borrowSpeed;
        emit DistributionSpeedUpdated(qToken, supplySpeed, borrowSpeed);
    }

    function setCompoundMinLockDuration(uint256 newMinLockDuration) external onlyOwner {
        require(newMinLockDuration >= XLAB_MIN_LOCK_DURATION, "LABDistributor: invalid newMinLockDuration");
        compoundMinLockDuration = newMinLockDuration;
    }

    function setPriceCalculator(address _priceCalculator) external onlyOwner {
        priceCalculator = IPriceCalculator(_priceCalculator);
    }

    function setXLAB(address _xlab) external onlyOwner {
        xLAB = IxLAB(_xlab);
    }

    function setRewardController(address _rewardController) external onlyOwner {
        rewardController = IRewardController(_rewardController);
    }

    // For reward distribution to different network (such as Klaytn)
    function withdrawReward(address receiver, uint amount) external onlyOwner {
        LAB.safeTransfer(receiver, amount);
    }

    function pause() external override onlyOwner {
        _pause();
    }

    function unpause() external override onlyOwner {
        _unpause();
    }

    function approve(address _spender, uint256 amount) external override onlyOwner returns (bool) {
        LAB.safeApprove(_spender, amount);
        return true;
    }

    /* ========== VIEWS ========== */

    function accuredLAB(address[] calldata markets, address account) external view override returns (uint) {
        uint amount = 0;
        for (uint i = 0; i < markets.length; i++) {
            amount = amount.add(_accruedLAB(markets[i], account));
        }
        return amount;
    }

    function distributionInfoOf(address market) external view override returns (Constant.DistributionInfo memory) {
        return distributions[market];
    }

    function accountDistributionInfoOf(
        address market,
        address account
    ) external view override returns (Constant.DistributionAccountInfo memory) {
        return accountDistributions[market][account];
    }

    function apyDistributionOf(
        address market,
        address account
    ) external view override returns (Constant.DistributionAPY memory) {
        (uint apySupplyLAB, uint apyBorrowLAB) = _calculateMarketDistributionAPY(market);
        (uint apyAccountSupplyLAB, uint apyAccountBorrowLAB) = _calculateAccountDistributionAPY(market, account);
        return Constant.DistributionAPY(apySupplyLAB, apyBorrowLAB, apyAccountSupplyLAB, apyAccountBorrowLAB);
    }

    function boostedRatioOf(
        address market,
        address account
    ) external view override returns (uint boostedSupplyRatio, uint boostedBorrowRatio) {
        uint accountSupply = ILToken(market).balanceOf(account);
        uint accountBorrow = ILToken(market).borrowBalanceOf(account).mul(1e18).div(
            ILToken(market).getAccInterestIndex()
        );

        boostedSupplyRatio = accountSupply > 0
            ? accountDistributions[market][account].boostedSupply.mul(1e18).div(accountSupply)
            : 0;
        boostedBorrowRatio = accountBorrow > 0
            ? accountDistributions[market][account].boostedBorrow.mul(1e18).div(accountBorrow)
            : 0;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function notifySupplyUpdated(
        address market,
        address user
    ) external override nonReentrant onlyCore updateDistributionOf(market) {
        if (block.timestamp < LAUNCH_TIMESTAMP) return;

        Constant.DistributionInfo storage dist = distributions[market];
        Constant.DistributionAccountInfo storage userInfo = accountDistributions[market][user];

        if (userInfo.boostedSupply > 0) {
            uint accLabPerShare = dist.accPerShareSupply.sub(userInfo.accPerShareSupply);
            userInfo.accuredLAB = userInfo.accuredLAB.add(accLabPerShare.mul(userInfo.boostedSupply).div(1e18));
        }
        userInfo.accPerShareSupply = dist.accPerShareSupply;

        uint boostedSupply = _calculateBoostedSupply(market, user);
        dist.totalBoostedSupply = dist.totalBoostedSupply.add(boostedSupply).sub(userInfo.boostedSupply);
        userInfo.boostedSupply = boostedSupply;
    }

    function notifyBorrowUpdated(
        address market,
        address user
    ) external override nonReentrant onlyCore updateDistributionOf(market) {
        if (block.timestamp < LAUNCH_TIMESTAMP) return;

        Constant.DistributionInfo storage dist = distributions[market];
        Constant.DistributionAccountInfo storage userInfo = accountDistributions[market][user];

        if (userInfo.boostedBorrow > 0) {
            uint accLabPerShare = dist.accPerShareBorrow.sub(userInfo.accPerShareBorrow);
            userInfo.accuredLAB = userInfo.accuredLAB.add(accLabPerShare.mul(userInfo.boostedBorrow).div(1e18));
        }
        userInfo.accPerShareBorrow = dist.accPerShareBorrow;

        uint boostedBorrow = _calculateBoostedBorrow(market, user);
        dist.totalBoostedBorrow = dist.totalBoostedBorrow.add(boostedBorrow).sub(userInfo.boostedBorrow);
        userInfo.boostedBorrow = boostedBorrow;
    }

    function notifyTransferred(
        address qToken,
        address sender,
        address receiver
    ) external override nonReentrant onlyCore updateDistributionOf(qToken) {
        if (block.timestamp < LAUNCH_TIMESTAMP) return;

        require(sender != receiver, "QDistributor: invalid transfer");
        Constant.DistributionInfo storage dist = distributions[qToken];
        Constant.DistributionAccountInfo storage senderInfo = accountDistributions[qToken][sender];
        Constant.DistributionAccountInfo storage receiverInfo = accountDistributions[qToken][receiver];

        if (senderInfo.boostedSupply > 0) {
            uint accLabPerShare = dist.accPerShareSupply.sub(senderInfo.accPerShareSupply);
            senderInfo.accuredLAB = senderInfo.accuredLAB.add(accLabPerShare.mul(senderInfo.boostedSupply).div(1e18));
        }
        senderInfo.accPerShareSupply = dist.accPerShareSupply;

        if (receiverInfo.boostedSupply > 0) {
            uint accLabPerShare = dist.accPerShareSupply.sub(receiverInfo.accPerShareSupply);
            receiverInfo.accuredLAB = receiverInfo.accuredLAB.add(
                accLabPerShare.mul(receiverInfo.boostedSupply).div(1e18)
            );
        }
        receiverInfo.accPerShareSupply = dist.accPerShareSupply;

        uint boostedSenderSupply = _calculateBoostedSupply(qToken, sender);
        uint boostedReceiverSupply = _calculateBoostedSupply(qToken, receiver);
        dist.totalBoostedSupply = dist
            .totalBoostedSupply
            .add(boostedSenderSupply)
            .add(boostedReceiverSupply)
            .sub(senderInfo.boostedSupply)
            .sub(receiverInfo.boostedSupply);
        senderInfo.boostedSupply = boostedSenderSupply;
        receiverInfo.boostedSupply = boostedReceiverSupply;
    }

    function claim(address[] calldata markets, address account) external override onlyCore whenNotPaused {
        uint256 amount = 0;
        uint256 userScore = IBEP20(address(xLAB)).balanceOf(account);
        uint256 totalScore = IBEP20(address(xLAB)).totalSupply();

        for (uint256 i = 0; i < markets.length; i++) {
            amount = amount.add(_claimLab(markets[i], account, userScore, totalScore));
        }

        amount = Math.min(amount, IBEP20(LAB).balanceOf(address(this)));
        LAB.safeTransfer(address(rewardController), amount);
        rewardController.mint(account, amount, true);
        emit Claimed(account, amount);
    }

    function claimBehalf(
        address[] calldata markets,
        address[] calldata accounts
    ) external override onlyCore whenNotPaused {
        for (uint256 i = 0; i < accounts.length; i++) {
            uint256 amount = 0;
            uint256 userScore = IBEP20(address(xLAB)).balanceOf(accounts[i]);
            uint256 totalScore = IBEP20(address(xLAB)).totalSupply();

            for (uint256 j = 0; j < markets.length; j++) {
                amount = amount.add(_claimLab(markets[j], accounts[i], userScore, totalScore));
            }

            amount = Math.min(amount, IBEP20(LAB).balanceOf(address(this)));
            LAB.safeTransfer(address(rewardController), amount);
            rewardController.mint(accounts[i], amount, true);
            emit Claimed(accounts[i], amount);
        }
    }

    function updateAccountBoostedInfo(address user) external override {
        require(user != address(0), "LABDistributor: User account can't be zero address");
        _updateAccountBoostedInfo(user);
    }

    function compound(address[] calldata markets, address account, uint256 lockDuration) external override onlyCore {
        require(account != address(0), "LABDistributor: compound: User account can't be zero address");
        require(lockDuration >= compoundMinLockDuration, "LABDistributor: compound: Lock duration is too short.");

        _compound(markets, account, lockDuration);
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    function _accruedLAB(address market, address user) private view returns (uint) {
        Constant.DistributionInfo memory dist = distributions[market];
        Constant.DistributionAccountInfo memory userInfo = accountDistributions[market][user];

        uint amount = userInfo.accuredLAB;
        uint accPerShareSupply = dist.accPerShareSupply;
        uint accPerShareBorrow = dist.accPerShareBorrow;

        uint timeElapsed = block.timestamp > dist.accruedAt ? block.timestamp.sub(dist.accruedAt) : 0;
        if (
            timeElapsed > 0 ||
            (accPerShareSupply != userInfo.accPerShareSupply) ||
            (accPerShareBorrow != userInfo.accPerShareBorrow)
        ) {
            if (dist.totalBoostedSupply > 0) {
                accPerShareSupply = accPerShareSupply.add(
                    dist.supplySpeed.mul(timeElapsed).mul(1e18).div(dist.totalBoostedSupply)
                );

                uint pendingLab = userInfo.boostedSupply.mul(accPerShareSupply.sub(userInfo.accPerShareSupply)).div(
                    1e18
                );
                amount = amount.add(pendingLab);
            }

            if (dist.totalBoostedBorrow > 0) {
                accPerShareBorrow = accPerShareBorrow.add(
                    dist.borrowSpeed.mul(timeElapsed).mul(1e18).div(dist.totalBoostedBorrow)
                );

                uint pendingLab = userInfo.boostedBorrow.mul(accPerShareBorrow.sub(userInfo.accPerShareBorrow)).div(
                    1e18
                );
                amount = amount.add(pendingLab);
            }
        }
        return amount;
    }

    function _claimLab(address market, address user, uint userScore, uint totalScore) private returns (uint amount) {
        Constant.DistributionAccountInfo storage userInfo = accountDistributions[market][user];

        if (userInfo.boostedSupply > 0) _updateSupplyOf(market, user, userScore, totalScore);
        if (userInfo.boostedBorrow > 0) _updateBorrowOf(market, user, userScore, totalScore);

        amount = amount.add(userInfo.accuredLAB);
        userInfo.accuredLAB = 0;

        return amount;
    }

    function _calculateMarketDistributionAPY(
        address market
    ) private view returns (uint apySupplyLAB, uint apyBorrowLAB) {
        uint256 decimals = _getDecimals(market);
        // base supply LAB APY == average supply LAB APY * (Total balance / total Boosted balance)
        // base supply LAB APY == (LabRate * 365 days * price Of Lab) / (Total balance * exchangeRate * price of asset) * (Total balance / Total Boosted balance)
        // base supply LAB APY == (LabRate * 365 days * price Of Lab) / (Total boosted balance * exchangeRate * price of asset)
        {
            uint numerSupply = distributions[market].supplySpeed.mul(365 days).mul(priceCalculator.priceOf(LAB));
            uint denomSupply = distributions[market]
                .totalBoostedSupply
                .mul(10 ** (18 - decimals))
                .mul(ILToken(market).exchangeRate())
                .mul(priceCalculator.getUnderlyingPrice(market))
                .div(1e36);
            apySupplyLAB = denomSupply > 0 ? numerSupply.div(denomSupply) : 0;
        }

        // base borrow LAB APY == average borrow LAB APY * (Total balance / total Boosted balance)
        // base borrow LAB APY == (LabRate * 365 days * price Of Lab) / (Total balance * exchangeRate * price of asset) * (Total balance / Total Boosted balance)
        // base borrow LAB APY == (LabRate * 365 days * price Of Lab) / (Total boosted balance * exchangeRate * price of asset)
        {
            uint numerBorrow = distributions[market].borrowSpeed.mul(365 days).mul(priceCalculator.priceOf(LAB));
            uint denomBorrow = distributions[market]
                .totalBoostedBorrow
                .mul(10 ** (18 - decimals))
                .mul(priceCalculator.getUnderlyingPrice(market))
                .div(ILToken(market).getAccInterestIndex());
            apyBorrowLAB = denomBorrow > 0 ? numerBorrow.div(denomBorrow) : 0;
        }
    }

    function _calculateAccountDistributionAPY(
        address market,
        address account
    ) private view returns (uint apyAccountSupplyLAB, uint apyAccountBorrowLAB) {
        if (account == address(0)) return (0, 0);
        (uint apySupplyLAB, uint apyBorrowLAB) = _calculateMarketDistributionAPY(market);

        // user supply LAB APY == ((LabRate * 365 days * price Of Lab) / (Total boosted balance * exchangeRate * price of asset) ) * my boosted balance  / my balance
        uint accountSupply = ILToken(market).balanceOf(account);
        apyAccountSupplyLAB = accountSupply > 0
            ? apySupplyLAB.mul(accountDistributions[market][account].boostedSupply).div(accountSupply)
            : 0;

        // user borrow LAB APY == (LabRate * 365 days * price Of Lab) / (Total boosted balance * interestIndex * price of asset) * my boosted balance  / my balance
        uint accountBorrow = ILToken(market).borrowBalanceOf(account).mul(1e18).div(
            ILToken(market).getAccInterestIndex()
        );
        apyAccountBorrowLAB = accountBorrow > 0
            ? apyBorrowLAB.mul(accountDistributions[market][account].boostedBorrow).div(accountBorrow)
            : 0;
    }

    function _calculateBoostedSupply(address market, address user) private view returns (uint) {
        uint defaultSupply = ILToken(market).balanceOf(user);
        uint boostedSupply = defaultSupply;

        uint userScore = IBEP20(address(xLAB)).balanceOf(user);
        uint totalScore = IBEP20(address(xLAB)).totalSupply();
        if (userScore > 0 && totalScore > 0) {
            uint scoreBoosted = ILToken(market).totalSupply().mul(userScore).div(totalScore).mul(BOOST_PORTION).div(
                100
            );
            boostedSupply = boostedSupply.add(scoreBoosted);
        }
        return Math.min(boostedSupply, defaultSupply.mul(BOOST_MAX).div(100));
    }

    function _calculateBoostedBorrow(address market, address user) private view returns (uint) {
        uint accInterestIndex = ILToken(market).getAccInterestIndex();
        uint defaultBorrow = ILToken(market).borrowBalanceOf(user).mul(1e18).div(accInterestIndex);
        uint boostedBorrow = defaultBorrow;

        uint userScore = IBEP20(address(xLAB)).balanceOf(user);
        uint totalScore = IBEP20(address(xLAB)).totalSupply();
        if (userScore > 0 && totalScore > 0) {
            uint totalBorrow = ILToken(market).totalBorrow().mul(1e18).div(accInterestIndex);
            uint scoreBoosted = totalBorrow.mul(userScore).div(totalScore).mul(BOOST_PORTION).div(100);
            boostedBorrow = boostedBorrow.add(scoreBoosted);
        }
        return Math.min(boostedBorrow, defaultBorrow.mul(BOOST_MAX).div(100));
    }

    function _calculateBoostedSupply(
        address market,
        address user,
        uint userScore,
        uint totalScore
    ) private view returns (uint) {
        uint defaultSupply = ILToken(market).balanceOf(user);
        uint boostedSupply = defaultSupply;

        if (userScore > 0 && totalScore > 0) {
            uint scoreBoosted = ILToken(market).totalSupply().mul(userScore).div(totalScore).mul(BOOST_PORTION).div(
                100
            );
            boostedSupply = boostedSupply.add(scoreBoosted);
        }
        return Math.min(boostedSupply, defaultSupply.mul(BOOST_MAX).div(100));
    }

    function _calculateBoostedBorrow(
        address market,
        address user,
        uint userScore,
        uint totalScore
    ) private view returns (uint) {
        uint accInterestIndex = ILToken(market).getAccInterestIndex();
        uint defaultBorrow = ILToken(market).borrowBalanceOf(user).mul(1e18).div(accInterestIndex);
        uint boostedBorrow = defaultBorrow;

        if (userScore > 0 && totalScore > 0) {
            uint totalBorrow = ILToken(market).totalBorrow().mul(1e18).div(accInterestIndex);
            uint scoreBoosted = totalBorrow.mul(userScore).div(totalScore).mul(BOOST_PORTION).div(100);
            boostedBorrow = boostedBorrow.add(scoreBoosted);
        }
        return Math.min(boostedBorrow, defaultBorrow.mul(BOOST_MAX).div(100));
    }

    function _updateSupplyOf(
        address market,
        address user,
        uint userScore,
        uint totalScore
    ) private updateDistributionOf(market) {
        Constant.DistributionInfo storage dist = distributions[market];
        Constant.DistributionAccountInfo storage userInfo = accountDistributions[market][user];

        if (userInfo.boostedSupply > 0) {
            uint accLabPerShare = dist.accPerShareSupply.sub(userInfo.accPerShareSupply);
            userInfo.accuredLAB = userInfo.accuredLAB.add(accLabPerShare.mul(userInfo.boostedSupply).div(1e18));
        }
        userInfo.accPerShareSupply = dist.accPerShareSupply;

        uint boostedSupply = _calculateBoostedSupply(market, user, userScore, totalScore);
        dist.totalBoostedSupply = dist.totalBoostedSupply.add(boostedSupply).sub(userInfo.boostedSupply);
        userInfo.boostedSupply = boostedSupply;
    }

    function _updateBorrowOf(
        address market,
        address user,
        uint userScore,
        uint totalScore
    ) private updateDistributionOf(market) {
        Constant.DistributionInfo storage dist = distributions[market];
        Constant.DistributionAccountInfo storage userInfo = accountDistributions[market][user];

        if (userInfo.boostedBorrow > 0) {
            uint accLabPerShare = dist.accPerShareBorrow.sub(userInfo.accPerShareBorrow);
            userInfo.accuredLAB = userInfo.accuredLAB.add(accLabPerShare.mul(userInfo.boostedBorrow).div(1e18));
        }
        userInfo.accPerShareBorrow = dist.accPerShareBorrow;

        uint boostedBorrow = _calculateBoostedBorrow(market, user, userScore, totalScore);
        dist.totalBoostedBorrow = dist.totalBoostedBorrow.add(boostedBorrow).sub(userInfo.boostedBorrow);
        userInfo.boostedBorrow = boostedBorrow;
    }

    function _updateAccountBoostedInfo(address user) private {
        if (block.timestamp < LAUNCH_TIMESTAMP) return;

        uint userScore = IBEP20(address(xLAB)).balanceOf(user);
        uint totalScore = IBEP20(address(xLAB)).totalSupply();

        address[] memory markets = core.allMarkets();
        for (uint256 i = 0; i < markets.length; i++) {
            address market = markets[i];
            Constant.DistributionAccountInfo memory userInfo = accountDistributions[market][user];
            if (userInfo.boostedSupply > 0) _updateSupplyOf(market, user, userScore, totalScore);
            if (userInfo.boostedBorrow > 0) _updateBorrowOf(market, user, userScore, totalScore);
        }
    }

    function _getDecimals(address lToken) internal view returns (uint256 decimals) {
        address underlying = ILToken(lToken).underlying();
        if (underlying == address(0)) {
            decimals = 18;
        } else {
            decimals = IBEP20(underlying).decimals();
        }
    }

    function _compound(address[] calldata markets, address account, uint256 lockDuration) private {
        uint256 amount = 0;
        uint userScore = IBEP20(address(xLAB)).balanceOf(account);
        uint totalScore = IBEP20(address(xLAB)).totalSupply();

        for (uint256 i = 0; i < markets.length; i++) {
            amount = amount.add(_claimLab(markets[i], account, userScore, totalScore));
        }
        amount = Math.min(amount, IBEP20(LAB).balanceOf(address(this)));
        xLAB.lockBehalf(account, amount, lockDuration);
        emit Compound(account, amount);
    }
}
