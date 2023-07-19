// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/Math.sol";

import "../library/SafeToken.sol";

import "./Market.sol";

import "../interfaces/IWETH.sol";

contract LToken is Market {
  using SafeMath for uint256;
  using SafeToken for address;

  /* ========== STATE VARIABLES ========== */

  string public name;
  string public symbol;
  uint8 public decimals;

  bool public initialized;

  mapping(address => mapping(address => uint256)) private _transferAllowances;

  /* ========== EVENT ========== */

  event Mint(address minter, uint256 mintAmount);
  event Redeem(address account, uint underlyingAmount, uint gTokenAmount);

  event Borrow(address account, uint256 ammount, uint256 accountBorrow);
  event RepayBorrow(address payer, address borrower, uint256 amount, uint256 accountBorrow);
  event LiquidateBorrow(
    address liquidator,
    address borrower,
    uint256 amount,
    address gTokenCollateral,
    uint256 seizeAmount
  );

  event Transfer(address indexed from, address indexed to, uint256 amount);
  event Approval(address indexed owner, address indexed spender, uint256 amount);

  /* ========== INITIALIZER ========== */

  constructor() public {}

  function initialize(string memory _name, string memory _symbol, uint8 _decimals) external onlyOwner {
    require(initialized == false, "already initialized");
    __GMarket_init();

    name = _name;
    symbol = _symbol;
    decimals = _decimals;
    initialized = true;
  }

  /* ========== VIEWS ========== */

  function allowance(address account, address spender) external view override returns (uint256) {
    return _transferAllowances[account][spender];
  }

  function getOwner() external view returns (address) {
    return owner();
  }

  /* ========== MUTATIVE FUNCTIONS ========== */

  function transfer(address dst, uint256 amount) external override accrue nonReentrant returns (bool) {
    core.transferTokens(msg.sender, msg.sender, dst, amount);
    return true;
  }

  function transferFrom(address src, address dst, uint256 amount) external override accrue nonReentrant returns (bool) {
    core.transferTokens(msg.sender, src, dst, amount);
    return true;
  }

  function approve(address spender, uint256 amount) external override returns (bool) {
    _transferAllowances[msg.sender][spender] = amount;
    emit Approval(msg.sender, spender, amount);
    return true;
  }

  /* ========== RESTRICTED FUNCTIONS ========== */

  function supply(address account, uint256 uAmount) external payable override accrue onlyCore returns (uint256) {
    uint256 exchangeRate = exchangeRate();
    uAmount = underlying == address(ETH) ? msg.value : uAmount;
    uAmount = _doTransferIn(account, uAmount);
    uint256 gAmount = uAmount.mul(1e18).div(exchangeRate);
    require(gAmount > 0, "LToken: invalid gAmount");
    updateSupplyInfo(account, gAmount, 0);

    emit Mint(account, gAmount);
    emit Transfer(address(0), account, gAmount);
    return gAmount;
  }

  function redeemToken(address redeemer, uint256 gAmount) external override accrue onlyCore returns (uint256) {
    return _redeem(redeemer, gAmount, 0);
  }

  function redeemUnderlying(address redeemer, uint256 uAmount) external override accrue onlyCore returns (uint256) {
    return _redeem(redeemer, 0, uAmount);
  }

  function borrow(address account, uint256 amount) external override accrue onlyCore returns (uint256) {
    require(getCash() >= amount, "LToken: borrow amount exceeds cash");
    updateBorrowInfo(account, amount, 0);
    _doTransferOut(account, amount);

    emit Borrow(account, amount, borrowBalanceOf(account));
    return amount;
  }

  function repayBorrow(address account, uint256 amount) external payable override accrue onlyCore returns (uint256) {
    if (amount == uint256(-1)) {
      amount = borrowBalanceOf(account);
    }
    return _repay(account, account, underlying == address(ETH) ? msg.value : amount);
  }

  function repayBorrowBehalf(
    address payer,
    address borrower,
    uint256 amount
  ) external payable override accrue onlyCore returns (uint256) {
    return _repay(payer, borrower, underlying == address(ETH) ? msg.value : amount);
  }

  function liquidateBorrow(
    address gTokenCollateral,
    address liquidator,
    address borrower,
    uint256 amount
  )
    external
    payable
    override
    accrue
    onlyCore
    returns (uint256 seizeGAmount, uint256 rebateGAmount, uint256 liquidatorGAmount)
  {
    require(borrower != liquidator, "LToken: cannot liquidate yourself");
    amount = underlying == address(ETH) ? msg.value : amount;
    amount = _repay(liquidator, borrower, amount);
    require(amount > 0 && amount < uint256(-1), "LToken: invalid repay amount");

    (seizeGAmount, rebateGAmount, liquidatorGAmount) = IValidator(core.validator()).gTokenAmountToSeize(
      address(this),
      gTokenCollateral,
      amount
    );

    require(ILToken(payable(gTokenCollateral)).balanceOf(borrower) >= seizeGAmount, "LToken: too much seize amount");

    emit LiquidateBorrow(liquidator, borrower, amount, gTokenCollateral, seizeGAmount);
  }

  function seize(address liquidator, address borrower, uint256 gAmount) external override accrue onlyCore nonReentrant {
    accountBalances[borrower] = accountBalances[borrower].sub(gAmount);
    accountBalances[liquidator] = accountBalances[liquidator].add(gAmount);

    emit Transfer(borrower, liquidator, gAmount);
  }

  function withdrawReserves() external override accrue onlyRebateDistributor nonReentrant {
    if (getCash() >= totalReserve) {
      uint256 amount = totalReserve;

      if (totalReserve > 0) {
        totalReserve = 0;
        _doTransferOut(address(rebateDistributor), amount);
      }
    }
  }

  function transferTokensInternal(
    address spender,
    address src,
    address dst,
    uint256 amount
  ) external override onlyCore {
    require(
      src != dst && IValidator(core.validator()).redeemAllowed(address(this), src, amount),
      "LToken: cannot transfer"
    );
    require(amount != 0, "LToken: zero amount");
    uint256 _allowance = spender == src ? uint256(-1) : _transferAllowances[src][spender];
    uint256 _allowanceNew = _allowance.sub(amount, "LToken: transfer amount exceeds allowance");

    accountBalances[src] = accountBalances[src].sub(amount);
    accountBalances[dst] = accountBalances[dst].add(amount);

    if (_allowance != uint256(-1)) {
      _transferAllowances[src][spender] = _allowanceNew;
    }
    emit Transfer(src, dst, amount);
  }

  /* ========== PRIVATE FUNCTIONS ========== */

  function _doTransferIn(address from, uint256 amount) private returns (uint256) {
    if (underlying == address(ETH)) {
      require(msg.value >= amount, "LToken: value mismatch");
      return Math.min(msg.value, amount);
    } else {
      uint256 balanceBefore = IBEP20(underlying).balanceOf(address(this));
      underlying.safeTransferFrom(from, address(this), amount);
      uint256 balanceAfter = IBEP20(underlying).balanceOf(address(this));
      require(balanceAfter.sub(balanceBefore) <= amount);
      return balanceAfter.sub(balanceBefore);
    }
  }

  function _doTransferOut(address to, uint256 amount) private {
    if (underlying == address(ETH)) {
      SafeToken.safeTransferETH(to, amount);
    } else {
      underlying.safeTransfer(to, amount);
    }
  }

  function _redeem(address account, uint256 gAmountIn, uint256 uAmountIn) private returns (uint256) {
    require(gAmountIn == 0 || uAmountIn == 0, "LToken: one of gAmountIn or uAmountIn must be zero");
    require(totalSupply >= gAmountIn, "LToken: not enough total supply");
    require(getCash() >= uAmountIn || uAmountIn == 0, "LToken: not enough underlying");
    require(getCash() >= gAmountIn.mul(exchangeRate()).div(1e18) || gAmountIn == 0, "LToken: not enough underlying");

    uint gAmountToRedeem = gAmountIn > 0 ? gAmountIn : uAmountIn.mul(1e18).div(exchangeRate());
    uint uAmountToRedeem = gAmountIn > 0 ? gAmountIn.mul(exchangeRate()).div(1e18) : uAmountIn;

    require(
      IValidator(core.validator()).redeemAllowed(address(this), account, gAmountToRedeem),
      "LToken: cannot redeem"
    );

    updateSupplyInfo(account, 0, gAmountToRedeem);
    _doTransferOut(account, uAmountToRedeem);

    emit Transfer(account, address(0), gAmountToRedeem);
    emit Redeem(account, uAmountToRedeem, gAmountToRedeem);
    return uAmountToRedeem;
  }

  function _repay(address payer, address borrower, uint256 amount) private returns (uint256) {
    uint256 borrowBalance = borrowBalanceOf(borrower);
    uint256 repayAmount = Math.min(borrowBalance, amount);
    repayAmount = _doTransferIn(payer, repayAmount);
    updateBorrowInfo(borrower, 0, repayAmount);

    if (underlying == address(ETH)) {
      uint256 refundAmount = amount > repayAmount ? amount.sub(repayAmount) : 0;
      if (refundAmount > 0) {
        _doTransferOut(payer, refundAmount);
      }
    }

    emit RepayBorrow(payer, borrower, repayAmount, borrowBalanceOf(borrower));
    return repayAmount;
  }
}
