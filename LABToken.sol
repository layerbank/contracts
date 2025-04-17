// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract LABToken is Ownable, ERC20("LayerBank Token", "LAB.m") {
    /* ========== STATE VARIABLES ========== */

    mapping(address => bool) private _minters;

    /* ========== MODIFIERS ========== */

    modifier onlyMinter() {
        require(isMinter(msg.sender), "LAB: caller is not the minter");
        _;
    }

    /* ========== INITIALIZER ========== */

    constructor() public {
        _minters[owner()] = true;
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function setMinter(address minter, bool canMint) external onlyOwner {
        _minters[minter] = canMint;
    }

    function mint(address _to, uint256 _amount) public onlyMinter {
        _mint(_to, _amount);
    }

    /* ========== VIEWS ========== */

    function isMinter(address account) public view returns (bool) {
        return _minters[account];
    }
}
