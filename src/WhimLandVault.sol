// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {LibTransferSafeUpgradeable, IERC721} from "./libraries/LibTransferSafeUpgradeable.sol";
import {LibOrder, OrderKey} from "./libraries/LibOrder.sol";

import {IWhimLandVault} from "./interface/IWhimLandVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

contract WhimLandVault is IWhimLandVault, OwnableUpgradeable, IERC721Receiver {
    using LibTransferSafeUpgradeable for address;
    using LibTransferSafeUpgradeable for IERC721;
    using SafeERC20 for IERC20;

    address public orderBook;
    mapping(OrderKey => uint256) public ETHBalance;
    mapping(OrderKey => uint256) public ERC20Balance;
    mapping(OrderKey => uint256) public NFTBalance;

    modifier onlyWhimLandOrderBook() {
        require(msg.sender == orderBook, "HV: only WhimLand OrderBook");
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(address _owner) public initializer {
        __Ownable_init(_owner);
    }

    function setOrderBook(address newOrderBook) public onlyOwner {
        require(newOrderBook != address(0), "HV: zero address");
        orderBook = newOrderBook;
    }

    function balanceOf(
        OrderKey orderKey
    ) external view returns (uint256 ETHAmount, uint256 tokenId) {
        ETHAmount = ETHBalance[orderKey];
        tokenId = NFTBalance[orderKey];
    }

    // ========== Deposit & Withdraw ==========

    function depositETH(
        OrderKey orderKey,
        uint256 ETHAmount
    ) external payable onlyWhimLandOrderBook {
        require(msg.value >= ETHAmount, "HV: not match ETHAmount");
        ETHBalance[orderKey] += msg.value;
    }

    function withdrawETH(
        OrderKey orderKey,
        uint256 ETHAmount,
        address to
    ) external onlyWhimLandOrderBook {
        ETHBalance[orderKey] -= ETHAmount;
        to.safeTransferETH(ETHAmount);
    }

    function depositNFT(
        OrderKey orderKey,
        address from,
        address collection,
        uint256 tokenId
    ) external onlyWhimLandOrderBook {
        IERC721(collection).safeTransferNFT(from, address(this), tokenId);

        NFTBalance[orderKey] = tokenId;
    }

    function withdrawNFT(
        OrderKey orderKey,
        address to,
        address collection,
        uint256 tokenId
    ) external onlyWhimLandOrderBook {
        require(NFTBalance[orderKey] == tokenId, "HV: not match tokenId");
        delete NFTBalance[orderKey];

        IERC721(collection).safeTransferNFT(address(this), to, tokenId);
    }

    function depositERC20(
        OrderKey orderKey,
        uint256 ERC20Amount,
        address currency,
        address from
    ) external onlyWhimLandOrderBook {
        IERC20(currency).safeTransferFrom(from, address(this), ERC20Amount);
        ERC20Balance[orderKey] += ERC20Amount;
    }

    function withdrawERC20(
        OrderKey orderKey,
        uint256 ERC20Amount,
        address currency,
        address to
    ) external onlyWhimLandOrderBook {
        ERC20Balance[orderKey] -= ERC20Amount;
        IERC20(currency).safeTransfer(to, ERC20Amount);
    }

    // ========== Edit Order ==========

    function editETH(
        OrderKey oldOrderKey,
        OrderKey newOrderKey,
        uint256 oldETHAmount,
        uint256 newETHAmount,
        address to
    ) external payable onlyWhimLandOrderBook {
        ETHBalance[oldOrderKey] = 0;
        if (oldETHAmount > newETHAmount) {
            ETHBalance[newOrderKey] = newETHAmount;
            to.safeTransferETH(oldETHAmount - newETHAmount);
        } else if (oldETHAmount < newETHAmount) {
            require(
                msg.value >= newETHAmount - oldETHAmount,
                "HV: not match newETHAmount"
            );
            require(
                msg.value <= type(uint256).max - oldETHAmount,
                "HV: overflow"
            );
            ETHBalance[newOrderKey] = msg.value + oldETHAmount;
        } else {
            ETHBalance[newOrderKey] = oldETHAmount;
        }
    }

    function editERC20(
        OrderKey oldOrderKey,
        OrderKey newOrderKey,
        uint256 oldERC20Amount,
        uint256 newERC20Amount,
        address currency,
        address orderMaker
    ) external onlyWhimLandOrderBook {
        ERC20Balance[oldOrderKey] = 0;
        if (oldERC20Amount > newERC20Amount) {
            ERC20Balance[newOrderKey] = newERC20Amount;
            IERC20(currency).safeTransfer(
                orderMaker,
                oldERC20Amount - newERC20Amount
            );
        } else if (oldERC20Amount < newERC20Amount) {
            IERC20(currency).safeTransferFrom(
                orderMaker,
                address(this),
                newERC20Amount - oldERC20Amount
            );
            ERC20Balance[newOrderKey] = newERC20Amount;
        } else {
            ERC20Balance[newOrderKey] = oldERC20Amount;
        }
    }

    function editNFT(
        OrderKey oldOrderKey,
        OrderKey newOrderKey
    ) external onlyWhimLandOrderBook {
        NFTBalance[newOrderKey] = NFTBalance[oldOrderKey];
        delete NFTBalance[oldOrderKey];
    }

    // ========== ERC721 Transfer ==========

    function transferERC721(
        address from,
        address to,
        LibOrder.Asset calldata assets
    ) external onlyWhimLandOrderBook {
        IERC721(assets.collectionAddr).safeTransferNFT(
            from,
            to,
            assets.tokenId
        );
    }

    function batchTransferERC721(
        address to,
        LibOrder.NFTInfo[] calldata assets
    ) external onlyWhimLandOrderBook {
        for (uint256 i = 0; i < assets.length; ++i) {
            IERC721(assets[i].collection).safeTransferNFT(
                _msgSender(),
                to,
                assets[i].tokenId
            );
        }
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes memory
    ) public virtual returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {}

    uint256[50] private __gap;
}
