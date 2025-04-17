// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "../library/Constant.sol";

import "../interfaces/IBEP20.sol";
import "../interfaces/IValidator.sol";
import "../interfaces/IRateModel.sol";
import "../interfaces/ILToken.sol";
import "../interfaces/ICore.sol";
import "../interfaces/IRebateDistributor.sol";

abstract contract Market is ILToken, Ownable, ReentrancyGuard {
    using SafeMath for uint256;

    /* ========== CONSTANT VARIABLES ========== */

    uint256 internal constant RESERVE_FACTOR_MAX = 1e18;
    uint256 internal constant DUST = 1000;

    address internal constant ETH = 0x0000000000000000000000000000000000000000;

    /* ========== STATE VARIABLES ========== */

    ICore public core;
    IRateModel public rateModel;
    IRebateDistributor public rebateDistributor;
    address public override underlying;

    uint256 public override totalSupply; // Total supply of lToken
    uint256 public override totalReserve;
    uint256 public override _totalBorrow;

    mapping(address => uint256) internal accountBalances;
    mapping(address => Constant.BorrowInfo) internal accountBorrows;

    uint256 public override reserveFactor;
    uint256 public override lastAccruedTime;
    uint256 public override accInterestIndex;

    /* ========== INITIALIZER ========== */

    receive() external payable {}

    /// @dev Initialization
    function __GMarket_init() internal {
        lastAccruedTime = block.timestamp;
        accInterestIndex = 1e18;
    }

    /* ========== MODIFIERS ========== */

    /// @dev 아직 처리되지 않은 totalBorrow, totalReserve, accInterestIndex 계산 및 저장
    modifier accrue() {
        if (block.timestamp > lastAccruedTime && address(rateModel) != address(0)) {
            uint256 borrowRate = rateModel.getBorrowRate(getCashPrior(), _totalBorrow, totalReserve);
            uint256 interestFactor = borrowRate.mul(block.timestamp.sub(lastAccruedTime));
            uint256 pendingInterest = _totalBorrow.mul(interestFactor).div(1e18);

            _totalBorrow = _totalBorrow.add(pendingInterest);
            totalReserve = totalReserve.add(pendingInterest.mul(reserveFactor).div(1e18));
            accInterestIndex = accInterestIndex.add(interestFactor.mul(accInterestIndex).div(1e18));
            lastAccruedTime = block.timestamp;
        }
        _;
    }

    /// @dev msg.sender 가 core address 인지 검증
    modifier onlyCore() {
        require(msg.sender == address(core), "LToken: only Core Contract");
        _;
    }

    modifier onlyRebateDistributor() {
        require(msg.sender == address(rebateDistributor), "LToken: only RebateDistributor");
        _;
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    /// @notice core address 를 설정
    /// @dev ZERO ADDRESS 로 설정할 수 없음
    ///      설정 이후에는 다른 주소로 변경할 수 없음
    /// @param _core core contract address
    function setCore(address _core) public onlyOwner {
        require(_core != address(0), "GMarket: invalid core address");
        require(address(core) == address(0), "GMarket: core already set");
        core = ICore(_core);
    }

    /// @notice underlying asset 의 token 설정
    /// @dev ZERO ADDRESS 로 설정할 수 없음
    ///      설정 이후에는 다른 주소로 변경할 수 없음
    /// @param _underlying Underlying token contract address
    function setUnderlying(address _underlying) public onlyOwner {
        require(_underlying != address(0), "GMarket: invalid underlying address");
        require(underlying == address(0), "GMarket: set underlying already");
        underlying = _underlying;
    }

    /// @notice rateModel 설정
    /// @param _rateModel 새로운 RateModel contract address
    function setRateModel(address _rateModel) public accrue onlyOwner {
        require(_rateModel != address(0), "GMarket: invalid rate model address");
        rateModel = IRateModel(_rateModel);
    }

    /// @notice reserve factor 변경
    /// @dev RESERVE_FACTOR_MAX 를 초과할 수 없음
    /// @param _reserveFactor 새로운 reserveFactor 값
    function setReserveFactor(uint256 _reserveFactor) public accrue onlyOwner {
        require(_reserveFactor <= RESERVE_FACTOR_MAX, "GMarket: invalid reserve factor");
        reserveFactor = _reserveFactor;
    }

    function setRebateDistributor(address _rebateDistributor) public onlyOwner {
        require(_rebateDistributor != address(0), "GMarket: invalid rebate distributor address");
        rebateDistributor = IRebateDistributor(_rebateDistributor);
    }

    /* ========== VIEWS ========== */

    function balanceOf(address account) external view override returns (uint256) {
        return accountBalances[account];
    }

    /// @notice account 의 AccountSnapshot 조회
    /// @param account account address
    function accountSnapshot(address account) external view override returns (Constant.AccountSnapshot memory) {
        Constant.AccountSnapshot memory snapshot;
        snapshot.lTokenBalance = accountBalances[account];
        snapshot.borrowBalance = borrowBalanceOf(account);
        snapshot.exchangeRate = exchangeRate();
        return snapshot;
    }

    /// @notice account 의 supply 된 underlying token 의 amount 조회
    /// @dev 원금에 붙은 이자를 포함
    /// @param account account address
    function underlyingBalanceOf(address account) external view override returns (uint256) {
        return accountBalances[account].mul(exchangeRate()).div(1e18);
    }

    /// @notice 계정의 borrow amount 조회
    /// @dev 원금에 붙은 이자를 포함
    function borrowBalanceOf(address account) public view override returns (uint256) {
        Constant.AccrueSnapshot memory snapshot = pendingAccrueSnapshot();
        Constant.BorrowInfo storage info = accountBorrows[account];

        if (info.borrow == 0) return 0;
        return info.borrow.mul(snapshot.accInterestIndex).div(info.interestIndex);
    }

    function totalBorrow() public view override returns (uint256) {
        Constant.AccrueSnapshot memory snapshot = pendingAccrueSnapshot();
        return snapshot.totalBorrow;
    }

    function exchangeRate() public view override returns (uint256) {
        if (totalSupply == 0) return 1e18;
        Constant.AccrueSnapshot memory snapshot = pendingAccrueSnapshot();
        return getCashPrior().add(snapshot.totalBorrow).sub(snapshot.totalReserve).mul(1e18).div(totalSupply);
    }

    function getCash() public view override returns (uint256) {
        return getCashPrior();
    }

    function getRateModel() external view override returns (address) {
        return address(rateModel);
    }

    function getAccInterestIndex() public view override returns (uint256) {
        Constant.AccrueSnapshot memory snapshot = pendingAccrueSnapshot();
        return snapshot.accInterestIndex;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function accruedAccountSnapshot(
        address account
    ) external override accrue returns (Constant.AccountSnapshot memory) {
        Constant.AccountSnapshot memory snapshot;
        Constant.BorrowInfo storage info = accountBorrows[account];
        if (info.interestIndex != 0) {
            info.borrow = info.borrow.mul(accInterestIndex).div(info.interestIndex);
            info.interestIndex = accInterestIndex;
        }

        snapshot.lTokenBalance = accountBalances[account];
        snapshot.borrowBalance = info.borrow;
        snapshot.exchangeRate = exchangeRate();
        return snapshot;
    }

    /// @notice View borrow balance amount after accure mutation
    function accruedBorrowBalanceOf(address account) external override accrue returns (uint256) {
        Constant.BorrowInfo storage info = accountBorrows[account];
        if (info.interestIndex != 0) {
            info.borrow = info.borrow.mul(accInterestIndex).div(info.interestIndex);
            info.interestIndex = accInterestIndex;
        }
        return info.borrow;
    }

    /// @notice View total borrow amount after accrue mutation
    function accruedTotalBorrow() external override accrue returns (uint256) {
        return _totalBorrow;
    }

    /// @notice View underlying token exchange rate after accure mutation
    function accruedExchangeRate() external override accrue returns (uint256) {
        return exchangeRate();
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    /// @notice borrow info 업데이트
    /// @dev account 의 accountBorrows 를 변경하고, totalSupply 를 변경함
    /// @param account borrow 하는 address account
    /// @param addAmount 추가되는 borrow amount
    /// @param subAmount 제거되는 borrow amount
    function updateBorrowInfo(address account, uint256 addAmount, uint256 subAmount) internal {
        Constant.BorrowInfo storage info = accountBorrows[account];
        if (info.interestIndex == 0) {
            info.interestIndex = accInterestIndex;
        }

        info.borrow = info.borrow.mul(accInterestIndex).div(info.interestIndex).add(addAmount).sub(subAmount);
        info.interestIndex = accInterestIndex;
        _totalBorrow = _totalBorrow.add(addAmount).sub(subAmount);

        info.borrow = (info.borrow < DUST) ? 0 : info.borrow;
        _totalBorrow = (_totalBorrow < DUST) ? 0 : _totalBorrow;
    }

    /// @notice supply info 업데이트
    /// @dev account 의 accountBalances 를 변경하고, totalSupply 를 변경함
    /// @param account supply 하는 address account
    /// @param addAmount 추가되는 supply amount
    /// @param subAmount 제거되는 supply amount
    function updateSupplyInfo(address account, uint256 addAmount, uint256 subAmount) internal {
        accountBalances[account] = accountBalances[account].add(addAmount).sub(subAmount);
        totalSupply = totalSupply.add(addAmount).sub(subAmount);

        totalSupply = (totalSupply < DUST) ? 0 : totalSupply;
    }

    /// @notice contract 가 가지고 있는 underlying token amount 조회
    /// @dev underlying token 이 ETH 인 경우 msg.value 값을 빼서 계산함
    function getCashPrior() internal view returns (uint256) {
        return
            underlying == address(ETH)
                ? address(this).balance.sub(msg.value)
                : IBEP20(underlying).balanceOf(address(this));
    }

    /// @notice totalBorrow, totlaReserver, accInterestIdx 조회
    /// @dev 아직 계산되지 않은 pending interest 더한 값으로 조회
    ///      상태가 변겅되거나 저장되지는 않는다
    function pendingAccrueSnapshot() internal view returns (Constant.AccrueSnapshot memory) {
        Constant.AccrueSnapshot memory snapshot;
        snapshot.totalBorrow = _totalBorrow;
        snapshot.totalReserve = totalReserve;
        snapshot.accInterestIndex = accInterestIndex;

        if (block.timestamp > lastAccruedTime && _totalBorrow > 0) {
            uint256 borrowRate = rateModel.getBorrowRate(getCashPrior(), _totalBorrow, totalReserve);
            uint256 interestFactor = borrowRate.mul(block.timestamp.sub(lastAccruedTime));
            uint256 pendingInterest = _totalBorrow.mul(interestFactor).div(1e18);

            snapshot.totalBorrow = _totalBorrow.add(pendingInterest);
            snapshot.totalReserve = totalReserve.add(pendingInterest.mul(reserveFactor).div(1e18));
            snapshot.accInterestIndex = accInterestIndex.add(interestFactor.mul(accInterestIndex).div(1e18));
        }
        return snapshot;
    }
}
