// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract ERC20Manager is Initializable, ERC20Upgradeable, OwnableUpgradeable {
    constructor() {
        _disableInitializers();
    }

    /// @notice 初始化函数，替代构造函数
    function initialize(
        string memory name_,
        string memory symbol_,
        uint256 initialSupply,
        address owner_
    ) public initializer {
        // 初始化 ERC20 名称和符号
        __ERC20_init(name_, symbol_);
        __Ownable_init(owner_);
        _transferOwnership(owner_);

        // 铸造初始代币给部署者
        _mint(owner_, initialSupply);
    }

    /// @notice 可选：额外铸造函数
    function mint(address to, uint256 amount) public onlyOwner {
        require(to != address(0), "Mint to the zero address");
        _mint(to, amount);
    }
}
