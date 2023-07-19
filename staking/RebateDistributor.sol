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
import "../interfaces/ILocker.sol";
import "../interfaces/IBEP20.sol";

contract RebateDistributor is
    IRebateDistributor,
    Ownable,
    ReentrancyGuard,
    Pausable
{
    using SafeMath for uint256;
    using SafeToken for address;

    /* ========== CONSTANT VARIABLES ========== */

    uint256 public constant MAX_ADMIN_FEE_RATE = 5e17;
    uint256 public constant REBATE_CYCLE = 1 weeks;
    address internal constant ETH = 0x0000000000000000000000000000000000000000;

    /* ========== STATE VARIABLES ========== */

    ICore public core;
    ILocker public locker;
    IPriceCalculator public priceCalc;
    address public lab;

    Constant.RebateCheckpoint[] public rebateCheckpoints;
    address public keeper;
    uint256 public adminFeeRate;
    uint256 public weeklyLabSpeed;

    mapping(address => uint256) private userCheckpoint;
    uint256 private adminCheckpoint;

    bool public initialized;

    /* ========== MODIFIERS ========== */

    modifier onlyCore() {
        require(
            msg.sender == address(core),
            "RebateDistributor: only core contract"
        );
        _;
    }

    modifier onlyKeeper() {
        require(
            msg.sender == keeper || msg.sender == owner(),
            "RebateDistributor: caller is not the owner or keeper"
        );
        _;
    }

    /* ========== EVENTS ========== */

    event RebateClaimed(
        address indexed user,
        uint256[] marketFees,
        uint256 totalLabAmount
    );
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
        address _locker,
        address _priceCalc,
        address _lab,
        uint256 _weeklyLabSpeed
    ) external onlyOwner {
        require(initialized == false, "already initialized");
        require(_core != address(0), "RebateDistributor: invalid core address");
        require(
            _locker != address(0),
            "RebateDistributor: invalid locker address"
        );
        require(
            _priceCalc != address(0),
            "RebateDistributor: invalid priceCalc address"
        );

        core = ICore(_core);
        locker = ILocker(_locker);
        priceCalc = IPriceCalculator(_priceCalc);
        lab = _lab;

        adminCheckpoint = block.timestamp;
        adminFeeRate = 0;
        weeklyLabSpeed = _weeklyLabSpeed;

        if (rebateCheckpoints.length == 0) {
            rebateCheckpoints.push(
                Constant.RebateCheckpoint({
                    timestamp: _truncateTimestamp(block.timestamp),
                    totalScore: _getTotalScoreAtTruncatedTime(),
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
        require(
            _priceCalculator != address(0),
            "RebateDistributor: invalid priceCalculator address"
        );
        priceCalc = IPriceCalculator(_priceCalculator);
    }

    function setLocker(address _locker) external onlyOwner {
        require(
            _locker != address(0),
            "RebateDistributor: invalid locker address"
        );
        locker = ILocker(_locker);
    }

    function setKeeper(address _keeper) external override onlyKeeper {
        require(
            _keeper != address(0),
            "RebateDistributor: invalid keeper address"
        );
        keeper = _keeper;
        emit KeeperUpdated(_keeper);
    }

    function updateAdminFeeRate(
        uint256 newAdminFeeRate
    ) external override onlyKeeper {
        require(
            newAdminFeeRate <= MAX_ADMIN_FEE_RATE,
            "RebateDisbtirubor: Invalid fee rate"
        );
        adminFeeRate = newAdminFeeRate;
        emit AdminFeeRateUpdated(newAdminFeeRate);
    }

    function updateWeeklyLabSpeed(
        uint256 newWeeklyLabSpeed
    ) external onlyKeeper {
        weeklyLabSpeed = newWeeklyLabSpeed;
        emit WeeklyLabSpeedUpdated(newWeeklyLabSpeed);
    }

    function claimAdminRebates()
        external
        override
        nonReentrant
        onlyKeeper
        returns (uint256 addtionalLabAmount, uint256[] memory marketFees)
    {
        (addtionalLabAmount, marketFees) = accruedAdminRebate();
        Constant.RebateCheckpoint memory lastCheckpoint = rebateCheckpoints[
            rebateCheckpoints.length - 1
        ];
        adminCheckpoint = _truncateTimestamp(
            lastCheckpoint.timestamp.sub(REBATE_CYCLE)
        );

        address(lab).safeTransfer(msg.sender, addtionalLabAmount);
    }

    /* ========== VIEWS ========== */

    function accruedRebates(
        address account
    )
        public
        view
        override
        returns (
            uint256 labAmount,
            uint256 additionalLabAmount,
            uint256[] memory marketFees
        )
    {
        Constant.RebateCheckpoint memory lastCheckpoint = rebateCheckpoints[
            rebateCheckpoints.length - 1
        ];
        address[] memory markets = core.allMarkets();
        marketFees = new uint256[](markets.length);

        if (locker.lockInfoOf(account).length == 0)
            return (labAmount, additionalLabAmount, marketFees);

        for (
            uint256 nextTimestamp = _truncateTimestamp(
                userCheckpoint[account] != 0
                    ? userCheckpoint[account]
                    : locker.lockInfoOf(account)[0].timestamp
            ).add(REBATE_CYCLE);
            nextTimestamp <= lastCheckpoint.timestamp.sub(REBATE_CYCLE);
            nextTimestamp = nextTimestamp.add(REBATE_CYCLE)
        ) {
            uint256 votingPower = _getUserVPAt(account, nextTimestamp);
            if (votingPower == 0) continue;

            Constant.RebateCheckpoint
                storage currentCheckpoint = rebateCheckpoints[
                    _getCheckpointIdxAt(nextTimestamp)
                ];
            labAmount = labAmount.add(
                currentCheckpoint.weeklyLabSpeed.mul(votingPower).div(1e18)
            );
            additionalLabAmount = additionalLabAmount.add(
                currentCheckpoint
                    .additionalLabAmount
                    .mul(
                        uint256(1e18).sub(currentCheckpoint.adminFeeRate).mul(
                            votingPower
                        )
                    )
                    .div(1e36)
            );

            for (uint256 i = 0; i < markets.length; i++) {
                if (currentCheckpoint.marketFees[markets[i]] > 0) {
                    uint256 marketFee = currentCheckpoint
                        .marketFees[markets[i]]
                        .mul(
                            uint256(1e18)
                                .sub(currentCheckpoint.adminFeeRate)
                                .mul(votingPower)
                        )
                        .div(1e36);
                    marketFees[i] = marketFees[i].add(marketFee);
                }
            }
        }
    }

    function accruedAdminRebate()
        public
        view
        returns (uint256 additionalLabAmount, uint256[] memory marketFees)
    {
        Constant.RebateCheckpoint memory lastCheckpoint = rebateCheckpoints[
            rebateCheckpoints.length - 1
        ];
        address[] memory markets = core.allMarkets();
        marketFees = new uint256[](markets.length);

        for (
            uint256 nextTimestamp = _truncateTimestamp(adminCheckpoint).add(
                REBATE_CYCLE
            );
            nextTimestamp <= lastCheckpoint.timestamp.sub(REBATE_CYCLE);
            nextTimestamp = nextTimestamp.add(REBATE_CYCLE)
        ) {
            uint256 checkpointIdx = _getCheckpointIdxAt(nextTimestamp);
            Constant.RebateCheckpoint
                storage currentCheckpoint = rebateCheckpoints[checkpointIdx];
            additionalLabAmount = additionalLabAmount.add(
                currentCheckpoint
                    .additionalLabAmount
                    .mul(currentCheckpoint.adminFeeRate)
                    .div(1e18)
            );

            for (uint256 i = 0; i < markets.length; i++) {
                if (currentCheckpoint.marketFees[markets[i]] > 0) {
                    marketFees[i] = marketFees[i].add(
                        currentCheckpoint
                            .marketFees[markets[i]]
                            .mul(currentCheckpoint.adminFeeRate)
                            .div(1e18)
                    );
                }
            }
        }
    }

    function totalAccruedRevenue()
        public
        view
        returns (uint256[] memory marketFees, address[] memory markets)
    {
        Constant.RebateCheckpoint memory lastCheckpoint = rebateCheckpoints[
            rebateCheckpoints.length - 1
        ];
        markets = core.allMarkets();
        marketFees = new uint256[](markets.length);

        for (
            uint256 nextTimestamp = _truncateTimestamp(
                rebateCheckpoints[0].timestamp
            );
            nextTimestamp <= lastCheckpoint.timestamp.sub(REBATE_CYCLE);
            nextTimestamp = nextTimestamp.add(REBATE_CYCLE)
        ) {
            uint256 checkpointIdx = _getCheckpointIdxAt(nextTimestamp);
            Constant.RebateCheckpoint
                storage currentCheckpoint = rebateCheckpoints[checkpointIdx];
            for (uint256 i = 0; i < markets.length; i++) {
                if (currentCheckpoint.marketFees[markets[i]] > 0) {
                    marketFees[i] = marketFees[i].add(
                        currentCheckpoint.marketFees[markets[i]]
                    );
                }
            }
        }
    }

    function weeklyRebatePool()
        public
        view
        override
        returns (uint256 labAmount)
    {
        Constant.RebateCheckpoint storage lastCheckpoint = rebateCheckpoints[
            rebateCheckpoints.length - 1
        ];
        labAmount = labAmount.add(lastCheckpoint.weeklyLabSpeed).add(
            lastCheckpoint
                .additionalLabAmount
                .mul(uint256(1e18).sub(lastCheckpoint.adminFeeRate))
                .div(1e18)
        );
    }

    function weeklyProfitOfVP(
        uint256 vp
    ) public view override returns (uint256 labAmount) {
        require(vp >= 0 && vp <= 1e18, "RebateDistributor: Invalid VP");
        uint256 weeklyLabAmount = weeklyRebatePool();
        labAmount = weeklyLabAmount.mul(vp).div(1e18);
    }

    function weeklyProfitOf(
        address account
    ) external view override returns (uint256) {
        uint256 vp = _getUserVPAt(account, block.timestamp.add(REBATE_CYCLE));
        return weeklyProfitOfVP(vp);
    }

    function indicativeYearProfit() external view override returns (uint256) {
        (uint256 totalScore, ) = locker.totalScore();
        if (totalScore == 0) {
            return 0;
        }

        uint256 preScore = locker.preScoreOf(
            address(0),
            1e18,
            uint256(block.timestamp).add(365 days),
            Constant.EcoScorePreviewOption.LOCK
        );
        uint256 vp = preScore.mul(1e18).div(totalScore);
        uint256 weeklyProfit = weeklyProfitOfVP(vp >= 1e18 ? 1e18 : vp);

        return weeklyProfit.mul(52);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function checkpoint() external override onlyKeeper nonReentrant {
        Constant.RebateCheckpoint memory lastRebateScore = rebateCheckpoints[
            rebateCheckpoints.length - 1
        ];
        address[] memory markets = core.allMarkets();

        uint256 nextTimestamp = lastRebateScore.timestamp.add(REBATE_CYCLE);
        while (block.timestamp >= nextTimestamp) {
            (uint256 totalScore, uint256 slope) = locker.totalScore();
            uint256 newTotalScore = totalScore == 0
                ? 0
                : totalScore.add(slope.mul(block.timestamp.sub(nextTimestamp)));
            rebateCheckpoints.push(
                Constant.RebateCheckpoint({
                    totalScore: newTotalScore,
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
                    SafeToken.safeTransferETH(
                        msg.sender,
                        address(this).balance
                    );
                } else {
                    underlying.safeTransfer(
                        msg.sender,
                        SafeToken.myBalance(underlying)
                    );
                }
            }
        }
    }

    function addLABToRebatePool(uint256 amount) external override nonReentrant {
        Constant.RebateCheckpoint storage lastCheckpoint = rebateCheckpoints[
            rebateCheckpoints.length - 1
        ];
        lastCheckpoint.additionalLabAmount = lastCheckpoint
            .additionalLabAmount
            .add(amount);
        address(lab).safeTransferFrom(msg.sender, address(this), amount);
    }

    function addMarketUTokenToRebatePool(
        address lToken,
        uint256 uAmount
    ) external payable override nonReentrant {
        Constant.RebateCheckpoint storage lastCheckpoint = rebateCheckpoints[
            rebateCheckpoints.length - 1
        ];
        address underlying = ILToken(lToken).underlying();

        if (underlying == ETH && msg.value > 0) {
            lastCheckpoint.marketFees[lToken] = lastCheckpoint
                .marketFees[lToken]
                .add(msg.value);
        } else if (underlying != ETH) {
            address(underlying).safeTransferFrom(
                msg.sender,
                address(this),
                uAmount
            );
            lastCheckpoint.marketFees[lToken] = lastCheckpoint
                .marketFees[lToken]
                .add(uAmount);
        }
    }

    function claimRebates()
        external
        override
        nonReentrant
        whenNotPaused
        returns (
            uint256 labAmount,
            uint256 additionalLabAmount,
            uint256[] memory marketFees
        )
    {
        (labAmount, additionalLabAmount, marketFees) = accruedRebates(
            msg.sender
        );
        Constant.RebateCheckpoint memory lastCheckpoint = rebateCheckpoints[
            rebateCheckpoints.length - 1
        ];
        userCheckpoint[msg.sender] = _truncateTimestamp(
            lastCheckpoint.timestamp.sub(REBATE_CYCLE)
        );

        address(lab).safeTransfer(
            msg.sender,
            labAmount.add(additionalLabAmount)
        );

        emit RebateClaimed(
            msg.sender,
            marketFees,
            labAmount.add(additionalLabAmount)
        );
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    function _getCheckpointIdxAt(
        uint256 timestamp
    ) private view returns (uint256) {
        timestamp = _truncateTimestamp(timestamp);

        for (uint256 i = rebateCheckpoints.length - 1; i < uint256(-1); i--) {
            if (rebateCheckpoints[i].timestamp == timestamp) {
                return i;
            }
        }

        revert("RebateDistributor: checkpoint index error");
    }

    function _getTotalScoreAt(
        uint256 timestamp
    ) private view returns (uint256) {
        for (uint256 i = rebateCheckpoints.length - 1; i < uint256(-1); i--) {
            if (rebateCheckpoints[i].timestamp == timestamp) {
                return rebateCheckpoints[i].totalScore;
            }
        }

        if (
            rebateCheckpoints[rebateCheckpoints.length - 1].timestamp <
            timestamp
        ) {
            (uint256 totalScore, uint256 slope) = locker.totalScore();

            if (totalScore == 0 || slope == 0) {
                return 0;
            } else if (block.timestamp > timestamp) {
                return
                    totalScore.add(slope.mul(block.timestamp.sub(timestamp)));
            } else if (block.timestamp < timestamp) {
                return
                    totalScore.sub(slope.mul(timestamp.sub(block.timestamp)));
            } else {
                return totalScore;
            }
        }

        revert("RebateDistributor: checkpoint index error");
    }

    function _getTotalScoreAtTruncatedTime()
        private
        view
        returns (uint256 score)
    {
        (uint256 totalScore, uint256 slope) = locker.totalScore();
        uint256 lastTimestmp = _truncateTimestamp(block.timestamp);
        score = 0;

        if (totalScore > 0 && slope > 0) {
            score = totalScore.add(
                slope.mul(block.timestamp.sub(lastTimestmp))
            );
        }
    }

    function _getUserVPAt(
        address account,
        uint256 timestamp
    ) private view returns (uint256) {
        timestamp = _truncateTimestamp(timestamp);
        uint256 userScore = locker.scoreOfAt(account, timestamp);
        uint256 totalScore = _getTotalScoreAt(timestamp);

        return
            totalScore != 0
                ? userScore.mul(1e18).div(totalScore).div(1e8).mul(1e8)
                : 0;
    }

    function _truncateTimestamp(
        uint256 timestamp
    ) private pure returns (uint256) {
        return timestamp.div(REBATE_CYCLE).mul(REBATE_CYCLE);
    }

    function _getDecimals(
        address gToken
    ) private view returns (uint256 decimals) {
        address underlying = ILToken(gToken).underlying();
        if (underlying == address(0)) {
            decimals = 18;
        } else {
            decimals = IBEP20(underlying).decimals();
        }
    }
}
