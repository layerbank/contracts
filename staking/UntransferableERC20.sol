// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";

abstract contract UntransferableERC20 {
    using SafeMath for uint256;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    string private _name;
    string private _symbol;
    uint256 private _totalSupply;

    event Burn(address indexed account, uint256 value);
    event Mint(address indexed beneficiary, uint256 value);

    function __UntransferableERC20_init(string memory name_, string memory symbol_) internal {
        _name = name_;
        _symbol = symbol_;
    }

    function name() external view virtual returns (string memory) {
        return _name;
    }

    function symbol() external view virtual returns (string memory) {
        return _symbol;
    }

    function decimals() external pure virtual returns (uint8) {
        return 18;
    }

    function totalSupply() public view virtual returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view virtual returns (uint256) {
        return _balances[account];
    }

    function _mint(address account, uint256 amount) internal virtual {
        require(account != address(0), "UntransferableERC20: mint to the zero address");

        _totalSupply += amount;
        _balances[account] += amount;

        emit Mint(account, amount);
    }

    function _burn(address account, uint256 amount) internal virtual {
        require(account != address(0), "UntransferableERC20: burn from the zero address");

        uint256 accountBalance = _balances[account];
        require(accountBalance >= amount, "UntransferableERC20: burn amount exceeds balance");
        _balances[account] = accountBalance.sub(amount);
        _totalSupply = _totalSupply.sub(amount);

        emit Burn(account, amount);
    }
}
