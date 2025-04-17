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

    // initializer
    bool public initialized;

    mapping(address => mapping(address => uint256)) private _transferAllowances;

    /* ========== EVENT ========== */

    event Mint(address minter, uint256 mintAmount);
    event Redeem(address account, uint underlyingAmount, uint lTokenAmount);

    event Borrow(address account, uint256 ammount, uint256 accountBorrow);
    event RepayBorrow(address payer, address borrower, uint256 amount, uint256 accountBorrow);
    event LiquidateBorrow(
        address liquidator,
        address borrower,
        uint256 amount,
        address lTokenCollateral,
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

    function transferFrom(
        address src,
        address dst,
        uint256 amount
    ) external override accrue nonReentrant returns (bool) {
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
        uint256 lAmount = uAmount.mul(1e18).div(exchangeRate);
        require(lAmount > 0, "LToken: invalid lAmount");
        updateSupplyInfo(account, lAmount, 0);

        emit Mint(account, lAmount);
        emit Transfer(address(0), account, lAmount);
        return lAmount;
    }

    function supplyBehalf(
        address account,
        address supplier,
        uint256 uAmount
    ) external payable override accrue onlyCore returns (uint256) {
        uint256 exchangeRate = exchangeRate();
        uAmount = underlying == address(ETH) ? msg.value : uAmount;
        uAmount = _doTransferIn(account, uAmount);
        uint256 lAmount = uAmount.mul(1e18).div(exchangeRate);
        require(lAmount > 0, "LToken: invalid lAmount");
        updateSupplyInfo(supplier, lAmount, 0);

        emit Mint(supplier, lAmount);
        emit Transfer(address(0), supplier, lAmount);
        return lAmount;
    }

    function redeemToken(address redeemer, uint256 lAmount) external override accrue onlyCore returns (uint256) {
        return _redeem(redeemer, lAmount, 0);
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

    function borrowBehalf(
        address account,
        address borrower,
        uint256 amount
    ) external override accrue onlyCore returns (uint256) {
        require(getCash() >= amount, "LToken: borrow amount exceeds cash");
        updateBorrowInfo(borrower, amount, 0);
        _doTransferOut(account, amount);

        emit Borrow(borrower, amount, borrowBalanceOf(borrower));
        return amount;
    }

    function repayBorrow(address account, uint256 amount) external payable override accrue onlyCore returns (uint256) {
        if (amount == uint256(-1)) {
            amount = borrowBalanceOf(account);
        }
        return _repay(account, account, underlying == address(ETH) ? msg.value : amount);
    }

    function liquidateBorrow(
        address lTokenCollateral,
        address liquidator,
        address borrower,
        uint256 amount
    )
        external
        payable
        override
        accrue
        onlyCore
        returns (uint256 seizeLAmount, uint256 rebateLAmount, uint256 liquidatorLAmount)
    {
        require(borrower != liquidator, "LToken: cannot liquidate yourself");
        amount = underlying == address(ETH) ? msg.value : amount;
        amount = _repay(liquidator, borrower, amount);
        require(amount > 0 && amount < uint256(-1), "LToken: invalid repay amount");

        (seizeLAmount, rebateLAmount, liquidatorLAmount) = IValidator(core.validator()).lTokenAmountToSeize(
            address(this),
            lTokenCollateral,
            amount
        );

        require(
            ILToken(payable(lTokenCollateral)).balanceOf(borrower) >= seizeLAmount,
            "LToken: too much seize amount"
        );

        emit LiquidateBorrow(liquidator, borrower, amount, lTokenCollateral, seizeLAmount);
    }

    function seize(
        address liquidator,
        address borrower,
        uint256 lAmount
    ) external override accrue onlyCore nonReentrant {
        accountBalances[borrower] = accountBalances[borrower].sub(lAmount);
        accountBalances[liquidator] = accountBalances[liquidator].add(lAmount);

        emit Transfer(borrower, liquidator, lAmount);
    }

    function withdrawReserves() external override accrue onlyRebateDistributor nonReentrant {
        if (getCash() >= totalReserve) {
            uint256 amount = totalReserve;

            if (amount > 0) {
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

    function _redeem(address account, uint256 lAmountIn, uint256 uAmountIn) private returns (uint256) {
        require(lAmountIn == 0 || uAmountIn == 0, "LToken: one of lAmountIn or uAmountIn must be zero");
        require(totalSupply >= lAmountIn, "LToken: not enough total supply");
        require(getCash() >= uAmountIn || uAmountIn == 0, "LToken: not enough underlying");
        require(
            getCash() >= lAmountIn.mul(exchangeRate()).div(1e18) || lAmountIn == 0,
            "LToken: not enough underlying"
        );

        uint lAmountToRedeem = lAmountIn > 0 ? lAmountIn : uAmountIn.mul(1e18).div(exchangeRate());
        uint uAmountToRedeem = lAmountIn > 0 ? lAmountIn.mul(exchangeRate()).div(1e18) : uAmountIn;

        require(
            IValidator(core.validator()).redeemAllowed(address(this), account, lAmountToRedeem),
            "LToken: cannot redeem"
        );

        updateSupplyInfo(account, 0, lAmountToRedeem);
        _doTransferOut(account, uAmountToRedeem);

        emit Transfer(account, address(0), lAmountToRedeem);
        emit Redeem(account, uAmountToRedeem, lAmountToRedeem);
        return uAmountToRedeem;
    }

    function _repay(address payer, address borrower, uint256 amount) private returns (uint256) {
        uint256 borrowBalance = borrowBalanceOf(borrower);
        uint256 repayAmount = Math.min(borrowBalance, amount);
        if (borrowBalance.sub(repayAmount) != 0 && borrowBalance.sub(repayAmount) < DUST) {
            repayAmount = borrowBalance.sub(DUST);
        }

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
