// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

import "../library/SafeToken.sol";
import "../library/Constant.sol";

import "../interfaces/IRebateDistributor.sol";
import "../interfaces/IPriceCalculator.sol";
import "../interfaces/ICore.sol";
import "../interfaces/ILToken.sol";
import "../interfaces/IxLAB.sol";
import "../interfaces/IBEP20.sol";

contract RebateDistributor is IRebateDistributor, Ownable, ReentrancyGuard, Pausable {
    using SafeMath for uint256;
    using SafeToken for address;

    /* ========== CONSTANT VARIABLES ========== */

    uint256 public constant MAX_ADMIN_FEE_RATE = 5e17;
    uint256 public constant REBATE_CYCLE = 1 weeks;
    address internal constant ETH = 0x0000000000000000000000000000000000000000;

    /* ========== STATE VARIABLES ========== */

    ICore public core;
    IxLAB public xLAB;
    IPriceCalculator public priceCalc;
    address public LAB;

    Constant.RebateCheckpoint[] public rebateCheckpoints;
    address public keeper;
    uint256 public adminFeeRate;
    uint256 public weeklyLabSpeed;

    mapping(address => uint256) private userCheckpoint;
    uint256 private adminCheckpoint;

    // initializer
    bool public initialized;

    /* ========== MODIFIERS ========== */

    /// @dev msg.sender 가 core address 인지 검증
    modifier onlyCore() {
        require(msg.sender == address(core), "RebateDistributor: only core contract");
        _;
    }

    modifier onlyKeeper() {
        require(msg.sender == keeper || msg.sender == owner(), "RebateDistributor: caller is not the owner or keeper");
        _;
    }

    /* ========== EVENTS ========== */

    event RebateClaimed(address indexed user, uint256[] marketFees, uint256 totalLabAmount);
    event AdminFeeRateUpdated(uint256 newAdminFeeRate);
    event AdminRebateTreasuryUpdated(address newTreasury);
    event KeeperUpdated(address newKeeper);
    event WeeklyLabSpeedUpdated(uint256 newWeeklyLabSpeed);

    /* ========== SPECIAL FUNCTIONS ========== */

    receive() external payable {}

    /* ========== INITIALIZER ========== */

    constructor() public {}

    function initialize(
        address _core,
        address _xlab,
        address _priceCalc,
        address _lab,
        uint256 _weeklyLabSpeed
    ) external onlyOwner {
        require(initialized == false, "RebateDistributor: already initialized");
        require(_core != address(0), "RebateDistributor: invalid core address");
        require(_xlab != address(0), "RebateDistributor: invalid xlab address");
        require(_priceCalc != address(0), "RebateDistributor: invalid priceCalc address");

        core = ICore(_core);
        xLAB = IxLAB(_xlab);
        priceCalc = IPriceCalculator(_priceCalc);
        LAB = _lab;

        adminCheckpoint = block.timestamp;
        adminFeeRate = 0;
        weeklyLabSpeed = _weeklyLabSpeed;

        if (rebateCheckpoints.length == 0) {
            rebateCheckpoints.push(
                Constant.RebateCheckpoint({
                    timestamp: _truncateTimestamp(block.timestamp),
                    totalScore: IBEP20(address(xLAB)).totalSupply(),
                    adminFeeRate: adminFeeRate,
                    weeklyLabSpeed: _weeklyLabSpeed,
                    additionalLabAmount: 0
                })
            );
        }

        initialized = true;
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function pause() external override onlyOwner {
        _pause();
    }

    function unpause() external override onlyOwner {
        _unpause();
    }

    function setPriceCalculator(address _priceCalculator) external onlyOwner {
        require(_priceCalculator != address(0), "RebateDistributor: invalid priceCalculator address");
        priceCalc = IPriceCalculator(_priceCalculator);
    }

    function setXLAB(address _xlab) external onlyOwner {
        require(_xlab != address(0), "RebateDistributor: invalid xLAB address");
        xLAB = IxLAB(_xlab);
    }

    /// @notice set keeper address
    /// @param _keeper new keeper address
    function setKeeper(address _keeper) external override onlyKeeper {
        require(_keeper != address(0), "RebateDistributor: invalid keeper address");
        keeper = _keeper;
        emit KeeperUpdated(_keeper);
    }

    function updateAdminFeeRate(uint256 newAdminFeeRate) external override onlyKeeper {
        require(newAdminFeeRate <= MAX_ADMIN_FEE_RATE, "RebateDisbtirubor: Invalid fee rate");
        adminFeeRate = newAdminFeeRate;
        emit AdminFeeRateUpdated(newAdminFeeRate);
    }

    function updateWeeklyLabSpeed(uint256 newWeeklyLabSpeed) external onlyKeeper {
        weeklyLabSpeed = newWeeklyLabSpeed;
        emit WeeklyLabSpeedUpdated(newWeeklyLabSpeed);
    }

    /// @notice Claim accured admin rebates
    function claimAdminRebates()
        external
        override
        nonReentrant
        onlyKeeper
        returns (uint256 addtionalLabAmount, uint256[] memory marketFees)
    {
        (addtionalLabAmount, marketFees) = accruedAdminRebate();
        Constant.RebateCheckpoint memory lastCheckpoint = rebateCheckpoints[rebateCheckpoints.length - 1];
        adminCheckpoint = _truncateTimestamp(lastCheckpoint.timestamp.sub(REBATE_CYCLE));

        address(LAB).safeTransfer(msg.sender, addtionalLabAmount);
    }

    function withdrawReward(address receiver, uint amount) external onlyOwner {
        LAB.safeTransfer(receiver, amount);
    }

    /* ========== VIEWS ========== */

    /// @notice Accured rebate amount of account
    /// @param account account address
    function accruedRebates(
        address account
    ) public view override returns (uint256 labAmount, uint256 additionalLabAmount, uint256[] memory marketFees) {
        Constant.RebateCheckpoint memory lastCheckpoint = rebateCheckpoints[rebateCheckpoints.length - 1];
        address[] memory markets = core.allMarkets();
        marketFees = new uint256[](markets.length);

        if (xLAB.balanceHistoryOf(account).length == 0) return (labAmount, additionalLabAmount, marketFees);

        for (
            uint256 nextTimestamp = _truncateTimestamp(
                userCheckpoint[account] != 0 ? userCheckpoint[account] : xLAB.balanceHistoryOf(account)[0].timestamp
            ).add(REBATE_CYCLE);
            nextTimestamp <= lastCheckpoint.timestamp.sub(REBATE_CYCLE);
            nextTimestamp = nextTimestamp.add(REBATE_CYCLE)
        ) {
            uint256 votingPower = _getUserVPAt(account, nextTimestamp);
            if (votingPower == 0) continue;

            Constant.RebateCheckpoint storage currentCheckpoint = rebateCheckpoints[_getCheckpointIdxAt(nextTimestamp)];
            labAmount = labAmount.add(currentCheckpoint.weeklyLabSpeed.mul(votingPower).div(1e18));
            additionalLabAmount = additionalLabAmount.add(
                currentCheckpoint
                    .additionalLabAmount
                    .mul(uint256(1e18).sub(currentCheckpoint.adminFeeRate).mul(votingPower))
                    .div(1e36)
            );

            for (uint256 i = 0; i < markets.length; i++) {
                if (currentCheckpoint.marketFees[markets[i]] > 0) {
                    uint256 marketFee = currentCheckpoint
                        .marketFees[markets[i]]
                        .mul(uint256(1e18).sub(currentCheckpoint.adminFeeRate).mul(votingPower))
                        .div(1e36);
                    marketFees[i] = marketFees[i].add(marketFee);
                }
            }
        }
    }

    /// @notice Accrued rebate amount of admin
    function accruedAdminRebate() public view returns (uint256 additionalLabAmount, uint256[] memory marketFees) {
        Constant.RebateCheckpoint memory lastCheckpoint = rebateCheckpoints[rebateCheckpoints.length - 1];
        address[] memory markets = core.allMarkets();
        marketFees = new uint256[](markets.length);

        for (
            uint256 nextTimestamp = _truncateTimestamp(adminCheckpoint).add(REBATE_CYCLE);
            nextTimestamp <= lastCheckpoint.timestamp.sub(REBATE_CYCLE);
            nextTimestamp = nextTimestamp.add(REBATE_CYCLE)
        ) {
            uint256 checkpointIdx = _getCheckpointIdxAt(nextTimestamp);
            Constant.RebateCheckpoint storage currentCheckpoint = rebateCheckpoints[checkpointIdx];
            additionalLabAmount = additionalLabAmount.add(
                currentCheckpoint.additionalLabAmount.mul(currentCheckpoint.adminFeeRate).div(1e18)
            );

            for (uint256 i = 0; i < markets.length; i++) {
                if (currentCheckpoint.marketFees[markets[i]] > 0) {
                    marketFees[i] = marketFees[i].add(
                        currentCheckpoint.marketFees[markets[i]].mul(currentCheckpoint.adminFeeRate).div(1e18)
                    );
                }
            }
        }
    }

    function totalAccruedRevenue() public view returns (uint256[] memory marketFees, address[] memory markets) {
        Constant.RebateCheckpoint memory lastCheckpoint = rebateCheckpoints[rebateCheckpoints.length - 1];
        markets = core.allMarkets();
        marketFees = new uint256[](markets.length);

        for (
            uint256 nextTimestamp = _truncateTimestamp(rebateCheckpoints[0].timestamp);
            nextTimestamp <= lastCheckpoint.timestamp.sub(REBATE_CYCLE);
            nextTimestamp = nextTimestamp.add(REBATE_CYCLE)
        ) {
            uint256 checkpointIdx = _getCheckpointIdxAt(nextTimestamp);
            Constant.RebateCheckpoint storage currentCheckpoint = rebateCheckpoints[checkpointIdx];
            for (uint256 i = 0; i < markets.length; i++) {
                if (currentCheckpoint.marketFees[markets[i]] > 0) {
                    marketFees[i] = marketFees[i].add(currentCheckpoint.marketFees[markets[i]]);
                }
            }
        }
    }

    function weeklyRebatePool() public view override returns (uint256 labAmount) {
        Constant.RebateCheckpoint storage lastCheckpoint = rebateCheckpoints[rebateCheckpoints.length - 1];
        labAmount = labAmount.add(lastCheckpoint.weeklyLabSpeed).add(
            lastCheckpoint.additionalLabAmount.mul(uint256(1e18).sub(lastCheckpoint.adminFeeRate)).div(1e18)
        );
    }

    function weeklyProfitOfVP(uint256 vp) public view override returns (uint256 labAmount) {
        require(vp >= 0 && vp <= 1e18, "RebateDistributor: Invalid VP");
        uint256 weeklyLabAmount = weeklyRebatePool();
        labAmount = weeklyLabAmount.mul(vp).div(1e18);
    }

    function weeklyProfitOf(address account) external view override returns (uint256) {
        uint256 vp = _getUserVPAt(account, block.timestamp.add(REBATE_CYCLE));
        return weeklyProfitOfVP(vp);
    }

    function indicativeAPR() external view override returns (uint256) {
        uint256 totalScore = IBEP20(address(xLAB)).totalSupply();
        if (totalScore == 0) {
            return 0;
        }

        uint256 preScore = xLAB.calcVeAmount(1e18, 365 days);
        uint256 vp = preScore.mul(1e18).div(totalScore);
        uint256 weeklyProfit = weeklyProfitOfVP(vp >= 1e18 ? 1e18 : vp);

        return weeklyProfit.mul(52);
    }

    function indicativeAPROf(uint256 amount, uint256 lockDuration) external view override returns (uint256) {
        uint256 totalScore = IBEP20(address(xLAB)).totalSupply();
        if (totalScore == 0) {
            return 0;
        }

        uint256 preScore = xLAB.calcVeAmount(amount, lockDuration);
        uint256 vp = preScore.mul(1e18).div(totalScore.add(preScore));
        uint256 weeklyProfit = weeklyProfitOfVP(vp >= 1e18 ? 1e18 : vp);

        return weeklyProfit.mul(52).mul(1e18).div(amount);
    }

    function indicativeAPROfUser(address account) external view override returns (uint256) {
        uint256 vp = _getUserVP(account);
        uint256 weeklyProfit = weeklyProfitOfVP(vp >= 1e18 ? 1e18 : vp);
        uint256 lockedBalance = xLAB.lockedBalanceOf(account);

        if (vp == 0 || lockedBalance == 0) return 0;

        return weeklyProfit.mul(1e18).mul(52).div(lockedBalance);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    /// @notice Add checkpoint if needed and supply supluses
    function checkpoint() external override onlyKeeper nonReentrant {
        Constant.RebateCheckpoint memory lastRebateScore = rebateCheckpoints[rebateCheckpoints.length - 1];
        address[] memory markets = core.allMarkets();

        uint256 nextTimestamp = lastRebateScore.timestamp.add(REBATE_CYCLE);
        while (block.timestamp >= nextTimestamp) {
            rebateCheckpoints.push(
                Constant.RebateCheckpoint({
                    totalScore: IBEP20(address(xLAB)).totalSupply(),
                    timestamp: nextTimestamp,
                    adminFeeRate: adminFeeRate,
                    weeklyLabSpeed: weeklyLabSpeed,
                    additionalLabAmount: 0
                })
            );
            nextTimestamp = nextTimestamp.add(REBATE_CYCLE);

            for (uint256 i = 0; i < markets.length; i++) {
                ILToken(markets[i]).withdrawReserves();
                address underlying = ILToken(markets[i]).underlying();

                if (underlying == address(ETH)) {
                    SafeToken.safeTransferETH(msg.sender, address(this).balance);
                } else {
                    underlying.safeTransfer(msg.sender, SafeToken.myBalance(underlying));
                }
            }
        }
    }

    function addLABToRebatePool(uint256 amount) external override nonReentrant {
        Constant.RebateCheckpoint storage lastCheckpoint = rebateCheckpoints[rebateCheckpoints.length - 1];
        lastCheckpoint.additionalLabAmount = lastCheckpoint.additionalLabAmount.add(amount);
        address(LAB).safeTransferFrom(msg.sender, address(this), amount);
    }

    function addMarketUTokenToRebatePool(address lToken, uint256 uAmount) external payable override nonReentrant {
        Constant.RebateCheckpoint storage lastCheckpoint = rebateCheckpoints[rebateCheckpoints.length - 1];
        address underlying = ILToken(lToken).underlying();

        if (underlying == ETH && msg.value > 0) {
            lastCheckpoint.marketFees[lToken] = lastCheckpoint.marketFees[lToken].add(msg.value);
        } else if (underlying != ETH) {
            address(underlying).safeTransferFrom(msg.sender, address(this), uAmount);
            lastCheckpoint.marketFees[lToken] = lastCheckpoint.marketFees[lToken].add(uAmount);
        }
    }

    /// @notice Claim accured all rebates
    function claimRebates()
        external
        override
        nonReentrant
        whenNotPaused
        returns (uint256 labAmount, uint256 additionalLabAmount, uint256[] memory marketFees)
    {
        (labAmount, additionalLabAmount, marketFees) = accruedRebates(msg.sender);
        Constant.RebateCheckpoint memory lastCheckpoint = rebateCheckpoints[rebateCheckpoints.length - 1];
        userCheckpoint[msg.sender] = _truncateTimestamp(lastCheckpoint.timestamp.sub(REBATE_CYCLE));

        address(LAB).safeTransfer(msg.sender, labAmount.add(additionalLabAmount));

        emit RebateClaimed(msg.sender, marketFees, labAmount.add(additionalLabAmount));
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    /// @notice Find checkpoint index of timestamp
    /// @param timestamp checkpoint timestamp
    function _getCheckpointIdxAt(uint256 timestamp) private view returns (uint256) {
        timestamp = _truncateTimestamp(timestamp);

        for (uint256 i = rebateCheckpoints.length - 1; i < uint256(-1); i--) {
            if (rebateCheckpoints[i].timestamp == timestamp) {
                return i;
            }
        }

        revert("RebateDistributor: checkpoint index error");
    }

    function _getUserVP(address account) private view returns (uint256) {
        uint256 userScore = IBEP20(address(xLAB)).balanceOf(account);
        uint256 totalScore = IBEP20(address(xLAB)).totalSupply();

        return totalScore != 0 ? userScore.mul(1e18).div(totalScore) : 0;
    }

    /// @notice Get user voting power at timestamp
    /// @param account account address
    /// @param timestamp timestamp
    function _getUserVPAt(address account, uint256 timestamp) private view returns (uint256) {
        timestamp = _truncateTimestamp(timestamp);
        uint256 userScore = xLAB.balanceOfAt(account, timestamp);
        uint256 idx = _getCheckpointIdxAt(timestamp);
        uint256 totalScore = rebateCheckpoints[idx].totalScore;

        return totalScore != 0 ? userScore.mul(1e18).div(totalScore).div(1e8).mul(1e8) : 0;
    }

    /// @notice Truncate timestamp to adjust to rebate checkpoint
    function _truncateTimestamp(uint256 timestamp) private pure returns (uint256) {
        return timestamp.div(REBATE_CYCLE).mul(REBATE_CYCLE);
    }

    function _getDecimals(address lToken) private view returns (uint256 decimals) {
        address underlying = ILToken(lToken).underlying();
        if (underlying == address(0)) {
            decimals = 18;
        } else {
            decimals = IBEP20(underlying).decimals();
        }
    }
}
