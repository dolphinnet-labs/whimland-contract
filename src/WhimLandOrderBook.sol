// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {LibTransferSafeUpgradeable, IERC721} from "./libraries/LibTransferSafeUpgradeable.sol";
import {Price} from "./libraries/RedBlackTreeLibrary.sol";
import {LibOrder, OrderKey} from "./libraries/LibOrder.sol";
import {LibPayInfo} from "./libraries/LibPayInfo.sol";

import {IWhimLandOrderBook} from "./interface/IWhimLandOrderBook.sol";
import {IWhimLandVault} from "./interface/IWhimLandVault.sol";

import {OrderStorage} from "./OrderStorage.sol";
import {OrderValidator} from "./OrderValidator.sol";
import {ProtocolManager} from "./ProtocolManager.sol";
import {NFTManager} from "./token/NFTManager.sol";

contract WhimLandOrderBook is
    IWhimLandOrderBook,
    Initializable,
    ContextUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    OrderStorage,
    ProtocolManager,
    OrderValidator
{
    using LibTransferSafeUpgradeable for address;
    using LibTransferSafeUpgradeable for IERC721;
    using SafeERC20 for IERC20;

    event LogMake(
        OrderKey orderKey,
        LibOrder.Side indexed side,
        LibOrder.SaleKind indexed saleKind,
        address indexed maker,
        LibOrder.Asset nft,
        Price price,
        address currency,
        uint64 expiry,
        uint64 salt
    );

    event LogCancel(OrderKey indexed orderKey, address indexed maker);

    event LogMatch(
        OrderKey indexed makeOrderKey,
        OrderKey indexed takeOrderKey,
        LibOrder.Order makeOrder,
        LibOrder.Order takeOrder,
        uint128 fillPrice
    );

    event LogWithdrawETH(address recipient, uint256 amount);
    event LogWithdrawERC20(address recipient, address token, uint256 amount);
    event BatchMatchInnerError(uint256 offset, bytes msg);
    event LogSkipOrder(OrderKey orderKey, uint64 salt);

    error NotMatchBidETHAmount(uint256 msgValue, uint256 bidETHAmount);
    error ValueBelowFillPrice(uint256 msgValue, uint256 fillPrice);
    error BuyPriceBelowFillPrice(uint256 buyPrice, uint256 fillPrice);

    modifier onlyDelegateCall() {
        _checkDelegateCall();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable state-variable-assignment
    address private immutable self = address(this);

    address private _vault;
    bool private _isInternalMatching;
    mapping(address => bool) public isSupportedCurrency;
    mapping(address => bool) public isWhitelistedCollection;

    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize contracts.
     * @param newProtocolShare Default protocol fee.
     * @param newVault easy swap vault address.
     */
    function initialize(
        uint128 newProtocolShare,
        address newVault,
        string memory EIP712Name,
        string memory EIP712Version
    ) public initializer {
        __WhimLandOrderBook_init(
            newProtocolShare,
            newVault,
            EIP712Name,
            EIP712Version
        );
    }

    function __WhimLandOrderBook_init(
        uint128 newProtocolShare,
        address newVault,
        string memory EIP712Name,
        string memory EIP712Version
    ) internal onlyInitializing {
        __WhimLandOrderBook_init_unchained(
            newProtocolShare,
            newVault,
            EIP712Name,
            EIP712Version
        );
    }

    function __WhimLandOrderBook_init_unchained(
        uint128 newProtocolShare,
        address newVault,
        string memory EIP712Name,
        string memory EIP712Version
    ) internal onlyInitializing {
        __Context_init();
        __Ownable_init(_msgSender());
        __ReentrancyGuard_init();
        __Pausable_init();

        __OrderStorage_init();
        __ProtocolManager_init(newProtocolShare);
        __OrderValidator_init(EIP712Name, EIP712Version);

        setVault(newVault);
    }

    /**
     * @notice Create multiple orders and transfer related assets.
     * @dev If Side=List, you need to authorize the WhimLandVault contract first (creating a List order will transfer the NFT to the order pool).
     * @dev If Side=Bid, you need to pass {value}: the price of the bid (similarly, creating a Bid order will transfer ETH to the order pool).
     * @dev order.maker needs to be msg.sender.
     * @dev order.price cannot be 0.
     * @dev order.expiry needs to be greater than block.timestamp, or 0.
     * @dev order.salt cannot be 0.
     * @param newOrders Multiple order structure data.
     * @return newOrderKeys The unique id of the order is returned in order, if the id is empty, the corresponding order was not created correctly.
     */
    function makeOrders(
        LibOrder.Order[] calldata newOrders
    )
        external
        payable
        override
        whenNotPaused
        nonReentrant
        returns (OrderKey[] memory newOrderKeys)
    {
        uint256 orderAmount = newOrders.length;
        newOrderKeys = new OrderKey[](orderAmount);

        uint128 ETHAmount; // total eth amount
        for (uint256 i = 0; i < orderAmount; ++i) {
            address collection = newOrders[i].nft.collectionAddr;
            require(
                isWhitelistedCollection[collection],
                "Collection not allowed"
            );
            require(
                isSupportedCurrency[newOrders[i].currency] ||
                    newOrders[i].currency == address(0),
                "WOB: unsupported currency"
            );
            uint128 buyPrice = 0; // the price of bid order

            if (
                newOrders[i].side == LibOrder.Side.Bid &&
                newOrders[i].currency == address(0)
            ) {
                buyPrice =
                    Price.unwrap(newOrders[i].price) *
                    newOrders[i].nft.amount;
            }

            OrderKey newOrderKey = _makeOrderTry(newOrders[i], buyPrice);
            newOrderKeys[i] = newOrderKey;
            if (
                // if the order is not created successfully, the eth will be returned
                OrderKey.unwrap(newOrderKey) !=
                OrderKey.unwrap(LibOrder.ORDERKEY_SENTINEL)
            ) {
                ETHAmount += buyPrice;
            }
        }

        if (msg.value > ETHAmount) {
            // return the remaining eth，if the eth is not enough, the transaction will be reverted
            _msgSender().safeTransferETH(msg.value - ETHAmount);
        }
    }

    /**
     * @dev Cancels multiple orders by their order keys.
     * @param orderKeys The array of order keys to cancel.
     */
    function cancelOrders(
        OrderKey[] calldata orderKeys
    )
        external
        override
        whenNotPaused
        nonReentrant
        returns (bool[] memory successes)
    {
        successes = new bool[](orderKeys.length);

        for (uint256 i = 0; i < orderKeys.length; ++i) {
            bool success = _cancelOrderTry(orderKeys[i]);
            successes[i] = success;
        }
    }

    /**
     * @notice Cancels multiple orders by their order keys.
     * @dev newOrder's saleKind, side, maker, and nft must match the corresponding order of oldOrderKey, otherwise it will be skipped; only the price can be modified.
     * @dev newOrder's expiry and salt can be regenerated.
     * @param editDetails The edit details of oldOrderKey and new order info
     * @return newOrderKeys The unique id of the order is returned in order, if the id is empty, the corresponding order was not edit correctly.
     */
    function editOrders(
        LibOrder.EditDetail[] calldata editDetails
    )
        external
        payable
        override
        whenNotPaused
        nonReentrant
        returns (OrderKey[] memory newOrderKeys)
    {
        newOrderKeys = new OrderKey[](editDetails.length);

        uint256 bidETHAmount;
        uint256 bidERC20Amount;
        for (uint256 i = 0; i < editDetails.length; ++i) {
            (OrderKey newOrderKey, uint256 bidPrice) = _editOrderTry(
                editDetails[i].oldOrderKey,
                editDetails[i].newOrder
            );
            if (editDetails[i].newOrder.currency != address(0)) {
                bidERC20Amount += bidPrice;
            } else {
                bidETHAmount += bidPrice;
            }
            newOrderKeys[i] = newOrderKey;
        }

        if (msg.value < bidETHAmount) {
            revert NotMatchBidETHAmount(msg.value, bidETHAmount);
        }
        if (msg.value > bidETHAmount) {
            _msgSender().safeTransferETH(msg.value - bidETHAmount);
        }
    }

    function matchOrder(
        LibOrder.Order calldata sellOrder,
        LibOrder.Order calldata buyOrder
    ) external payable override whenNotPaused nonReentrant {
        if (sellOrder.currency == address(0)) {
            uint256 costValue = _matchOrder(sellOrder, buyOrder, msg.value);
            if (msg.value > costValue) {
                _msgSender().safeTransferETH(msg.value - costValue);
            }
        } else {
            _matchOrder(sellOrder, buyOrder, Price.unwrap(buyOrder.price));
        }
    }

    /**
     * @dev Matches multiple orders atomically.
     * @dev If buying NFT, use the "valid sellOrder order" and construct a matching buyOrder order for order matching:
     * @dev    buyOrder.side = Bid, buyOrder.saleKind = FixedPriceForItem, buyOrder.maker = msg.sender,
     * @dev    nft and price values are the same as sellOrder, buyOrder.expiry > block.timestamp, buyOrder.salt != 0;
     * @dev If selling NFT, use the "valid buyOrder order" and construct a matching sellOrder order for order matching:
     * @dev    sellOrder.side = List, sellOrder.saleKind = FixedPriceForItem, sellOrder.maker = msg.sender,
     * @dev    nft and price values are the same as buyOrder, sellOrder.expiry > block.timestamp, sellOrder.salt != 0;
     * @param matchDetails Array of `MatchDetail` structs containing the details of sell and buy order to be matched.
     */
    /// @custom:oz-upgrades-unsafe-allow delegatecall
    function matchOrders(
        LibOrder.MatchDetail[] calldata matchDetails
    )
        external
        payable
        override
        whenNotPaused
        nonReentrant
        returns (bool[] memory successes)
    {
        _isInternalMatching = true;
        successes = new bool[](matchDetails.length);

        uint128 buyETHAmount;

        for (uint256 i = 0; i < matchDetails.length; ++i) {
            LibOrder.MatchDetail calldata matchDetail = matchDetails[i];

            // erc20 bid order
            if (matchDetail.buyOrder.currency != address(0)) {
                (bool success, bytes memory data) = address(this).delegatecall(
                    abi.encodeWithSignature(
                        "matchOrderWithoutPayback((uint8,uint8,address,(uint256,address,uint96),uint128,uint64,uint64),(uint8,uint8,address,(uint256,address,uint96),uint128,uint64,uint64),uint256)",
                        matchDetail.sellOrder,
                        matchDetail.buyOrder,
                        matchDetail.buyOrder.price
                    )
                );
                if (success) {
                    successes[i] = success;
                } else {
                    emit BatchMatchInnerError(i, data);
                }
            } else {
                (bool success, bytes memory data) = address(this).delegatecall(
                    abi.encodeWithSignature(
                        "matchOrderWithoutPayback((uint8,uint8,address,(uint256,address,uint96),uint128,uint64,uint64),(uint8,uint8,address,(uint256,address,uint96),uint128,uint64,uint64),uint256)",
                        matchDetail.sellOrder,
                        matchDetail.buyOrder,
                        msg.value - buyETHAmount
                    )
                );

                if (success) {
                    successes[i] = success;
                    if (matchDetail.buyOrder.maker == _msgSender()) {
                        // buy order
                        uint128 buyPrice;
                        buyPrice = abi.decode(data, (uint128));
                        // Calculate ETH the buyer has spent
                        buyETHAmount += buyPrice;
                    }
                } else {
                    emit BatchMatchInnerError(i, data);
                }
            }
        }

        if (msg.value > buyETHAmount) {
            // return the remaining eth
            _msgSender().safeTransferETH(msg.value - buyETHAmount);
        }

        _isInternalMatching = false;
    }

    function matchOrderWithoutPayback(
        LibOrder.Order calldata sellOrder,
        LibOrder.Order calldata buyOrder,
        uint256 msgValue
    )
        external
        payable
        whenNotPaused
        onlyDelegateCall
        returns (uint128 costValue)
    {
        require(_isInternalMatching, "Only internal call allowed");
        costValue = _matchOrder(sellOrder, buyOrder, msgValue);
    }

    function _makeOrderTry(
        LibOrder.Order calldata order,
        uint128 ETHAmount
    ) internal returns (OrderKey newOrderKey) {
        if (
            order.maker == _msgSender() && // only maker can make order
            Price.unwrap(order.price) != 0 && // price cannot be zero
            order.salt != 0 && // salt cannot be zero
            (order.expiry > block.timestamp || order.expiry == 0) && // expiry must be greater than current block timestamp or no expiry
            filledAmount[LibOrder.hash(order)] == 0 // order cannot be canceled or filled
        ) {
            newOrderKey = LibOrder.hash(order);
            require(
                orders[newOrderKey].order.maker == address(0),
                "WOB: order exist"
            );
            // add order to order storage
            orders[newOrderKey] = LibOrder.DBOrder({
                order: order,
                next: LibOrder.ORDERKEY_SENTINEL
            });

            // deposit asset to vault
            if (order.side == LibOrder.Side.List) {
                if (order.nft.amount != 1) {
                    // limit list order amount to 1
                    return LibOrder.ORDERKEY_SENTINEL;
                }
                IWhimLandVault(_vault).depositNFT(
                    newOrderKey,
                    order.maker,
                    order.nft.collectionAddr,
                    order.nft.tokenId
                );
            } else if (order.side == LibOrder.Side.Bid) {
                if (order.nft.amount == 0) {
                    return LibOrder.ORDERKEY_SENTINEL;
                }
                if (order.currency == address(0)) {
                    IWhimLandVault(_vault).depositETH{
                        value: uint256(ETHAmount)
                    }(newOrderKey, ETHAmount);
                } else {
                    IWhimLandVault(_vault).depositERC20(
                        newOrderKey,
                        ETHAmount,
                        order.currency,
                        order.maker
                    );
                }
            }

            // _addOrder(order);

            emit LogMake(
                newOrderKey,
                order.side,
                order.saleKind,
                order.maker,
                order.nft,
                order.price,
                order.currency,
                order.expiry,
                order.salt
            );
        } else {
            emit LogSkipOrder(LibOrder.hash(order), order.salt);
        }
    }

    function _cancelOrderTry(
        OrderKey orderKey
    ) internal returns (bool success) {
        LibOrder.Order memory order = orders[orderKey].order;

        if (
            order.maker == _msgSender() &&
            filledAmount[orderKey] < order.nft.amount // only unfilled order can be canceled
        ) {
            OrderKey orderHash = LibOrder.hash(order);

            // _removeOrder(order);

            // withdraw asset from vault
            if (order.side == LibOrder.Side.List) {
                IWhimLandVault(_vault).withdrawNFT(
                    orderHash,
                    order.maker,
                    order.nft.collectionAddr,
                    order.nft.tokenId
                );
            } else if (order.side == LibOrder.Side.Bid) {
                uint256 availNFTAmount = order.nft.amount -
                    filledAmount[orderKey]; // NFT买单剩余未成交的数量
                if (order.currency != address(0)) {
                    IWhimLandVault(_vault).withdrawERC20(
                        orderHash,
                        availNFTAmount * Price.unwrap(order.price), // the withdraw amount of erc20
                        order.currency,
                        order.maker
                    );
                } else {
                    IWhimLandVault(_vault).withdrawETH(
                        orderHash,
                        Price.unwrap(order.price) * availNFTAmount, // the withdraw amount of eth
                        order.maker
                    );
                }
            }
            _cancelOrder(orderKey);
            success = true;
            emit LogCancel(orderKey, order.maker);
        } else {
            emit LogSkipOrder(orderKey, order.salt);
        }
    }

    function _editOrderTry(
        OrderKey oldOrderKey,
        LibOrder.Order calldata newOrder
    ) internal returns (OrderKey newOrderKey, uint256 deltaBidPrice) {
        LibOrder.Order memory oldOrder = orders[oldOrderKey].order;

        // check order, only the price and amount can be modified
        if (
            (oldOrder.saleKind != newOrder.saleKind) ||
            (oldOrder.side != newOrder.side) ||
            (oldOrder.maker != newOrder.maker) ||
            (oldOrder.currency != newOrder.currency) ||
            (oldOrder.nft.collectionAddr != newOrder.nft.collectionAddr) ||
            (oldOrder.nft.tokenId != newOrder.nft.tokenId) ||
            filledAmount[oldOrderKey] >= oldOrder.nft.amount // order cannot be canceled or filled
        ) {
            emit LogSkipOrder(oldOrderKey, oldOrder.salt);
            return (LibOrder.ORDERKEY_SENTINEL, 0);
        }

        // check new order is valid
        if (
            newOrder.maker != _msgSender() ||
            newOrder.salt == 0 ||
            (newOrder.expiry < block.timestamp && newOrder.expiry != 0) ||
            filledAmount[LibOrder.hash(newOrder)] != 0 // order cannot be canceled or filled
        ) {
            emit LogSkipOrder(oldOrderKey, newOrder.salt);
            return (LibOrder.ORDERKEY_SENTINEL, 0);
        }

        // cancel old order
        uint256 oldFilledAmount = filledAmount[oldOrderKey];

        // _removeOrder(oldOrder); // remove order from order storage

        _cancelOrder(oldOrderKey); // cancel order from order book
        emit LogCancel(oldOrderKey, oldOrder.maker);

        // newOrderKey = _addOrder(newOrder); // add new order to order storage

        newOrderKey = LibOrder.hash(newOrder);
        // make new order, change the order key of the asset in the vault
        if (oldOrder.side == LibOrder.Side.List) {
            IWhimLandVault(_vault).editNFT(oldOrderKey, newOrderKey);
        } else if (oldOrder.side == LibOrder.Side.Bid) {
            uint256 oldRemainingPrice = Price.unwrap(oldOrder.price) *
                (oldOrder.nft.amount - oldFilledAmount);
            uint256 newRemainingPrice = Price.unwrap(newOrder.price) *
                newOrder.nft.amount;
            if (newRemainingPrice > oldRemainingPrice) {
                deltaBidPrice = newRemainingPrice - oldRemainingPrice;
                if (newOrder.currency != address(0)) {
                    IWhimLandVault(_vault).editERC20(
                        oldOrderKey,
                        newOrderKey,
                        oldRemainingPrice,
                        newRemainingPrice,
                        newOrder.currency,
                        oldOrder.maker
                    );
                } else {
                    IWhimLandVault(_vault).editETH{
                        value: uint256(deltaBidPrice)
                    }(
                        oldOrderKey,
                        newOrderKey,
                        oldRemainingPrice,
                        newRemainingPrice,
                        oldOrder.maker
                    );
                }
            } else {
                if (newOrder.currency != address(0)) {
                    IWhimLandVault(_vault).editERC20(
                        oldOrderKey,
                        newOrderKey,
                        oldRemainingPrice,
                        newRemainingPrice,
                        newOrder.currency,
                        oldOrder.maker
                    );
                } else {
                    IWhimLandVault(_vault).editETH(
                        oldOrderKey,
                        newOrderKey,
                        oldRemainingPrice,
                        newRemainingPrice,
                        oldOrder.maker
                    );
                }
            }
        }

        emit LogMake(
            newOrderKey,
            newOrder.side,
            newOrder.saleKind,
            newOrder.maker,
            newOrder.nft,
            newOrder.price,
            newOrder.currency,
            newOrder.expiry,
            newOrder.salt
        );
    }

    function _matchOrder(
        LibOrder.Order calldata sellOrder,
        LibOrder.Order calldata buyOrder,
        uint256 msgValue
    ) internal returns (uint128 costValue) {
        OrderKey sellOrderKey = LibOrder.hash(sellOrder);
        OrderKey buyOrderKey = LibOrder.hash(buyOrder);
        _isMatchAvailable(sellOrder, buyOrder, sellOrderKey, buyOrderKey);

        // 卖家发起匹配
        if (_msgSender() == sellOrder.maker) {
            // sell order
            // accept bid
            // require(msgValue == 0, "HD: value > 0"); // sell order cannot accept eth
            bool isSellExist = orders[sellOrderKey].order.maker != address(0); // check if sellOrder exist in order storage
            _validateOrder(sellOrder, !isSellExist); // if not exist, skip expiry check
            _validateOrder(orders[buyOrderKey].order, false); // check if exist in order storage

            uint128 fillPrice = Price.unwrap(buyOrder.price); // the price of bid order
            if (isSellExist) {
                // check if sellOrder exist in order storage , del&fill if exist
                // _removeOrder(sellOrder);

                _updateFilledAmount(sellOrder.nft.amount, sellOrderKey); // sell order totally filled
            }
            _updateFilledAmount(filledAmount[buyOrderKey] + 1, buyOrderKey);
            emit LogMatch(
                sellOrderKey,
                buyOrderKey,
                sellOrder,
                buyOrder,
                fillPrice
            );

            // calculate protocol fee (手续费)
            uint128 protocolFee = _shareToAmount(fillPrice, protocolShare);
            // calculate royalty fee (版税)
            (address royaltyReceiver, uint256 royaltyFee) = NFTManager(
                payable(buyOrder.nft.collectionAddr)
            ).royaltyInfo(buyOrder.nft.tokenId, fillPrice);

            // 从vault提取资金，扣取手续费后给卖家
            if (sellOrder.currency == address(0)) {
                IWhimLandVault(_vault).withdrawETH(
                    buyOrderKey,
                    fillPrice,
                    address(this)
                );
                sellOrder.maker.safeTransferETH(
                    fillPrice - protocolFee - royaltyFee
                );
                // 版税发送给创作者
                royaltyReceiver.safeTransferETH(royaltyFee);
            } else {
                IWhimLandVault(_vault).withdrawERC20(
                    buyOrderKey,
                    fillPrice,
                    sellOrder.currency,
                    address(this)
                );
                IERC20(sellOrder.currency).safeTransfer(
                    sellOrder.maker,
                    fillPrice - protocolFee - royaltyFee
                );
                // 版税发送给创作者
                IERC20(sellOrder.currency).safeTransfer(
                    royaltyReceiver,
                    royaltyFee
                );
            }

            // 卖家交付NFT
            if (isSellExist) {
                IWhimLandVault(_vault).withdrawNFT(
                    sellOrderKey,
                    buyOrder.maker,
                    sellOrder.nft.collectionAddr,
                    sellOrder.nft.tokenId
                );
            } else {
                IWhimLandVault(_vault).transferERC721(
                    sellOrder.maker,
                    buyOrder.maker,
                    sellOrder.nft
                );
            }
        }
        // 买家发起匹配
        else if (_msgSender() == buyOrder.maker) {
            // buy order
            // accept list
            bool isBuyExist = orders[buyOrderKey].order.maker != address(0);
            _validateOrder(orders[sellOrderKey].order, false); // check if exist in order storage
            _validateOrder(buyOrder, !isBuyExist);

            uint128 buyPrice = Price.unwrap(buyOrder.price);
            uint128 fillPrice = Price.unwrap(sellOrder.price);

            // calculate protocol fee (手续费)
            uint128 protocolFee = _shareToAmount(fillPrice, protocolShare);
            // calculate royalty fee (版税)
            (address royaltyReceiver, uint256 royaltyFee) = NFTManager(
                payable(buyOrder.nft.collectionAddr)
            ).royaltyInfo(buyOrder.nft.tokenId, fillPrice);

            // 如果买单不存在，先从买家账户扣款到合约，再把扣款转给卖家
            // 如果买单存在，从vault提取资金到合约，再把扣款转给卖家
            // 卖家收到钱后，把NFT从vault转给买家
            if (!isBuyExist) {
                if (msgValue < fillPrice || msgValue < buyPrice) {
                    revert ValueBelowFillPrice(msgValue, fillPrice);
                }
                if (sellOrder.currency == address(0)) {
                    // 扣除手续费和版税之后转给卖家
                    sellOrder.maker.safeTransferETH(
                        fillPrice - protocolFee - royaltyFee
                    );
                    // 版税发送给创作者
                    royaltyReceiver.safeTransferETH(royaltyFee);
                    if (buyPrice > fillPrice) {
                        buyOrder.maker.safeTransferETH(buyPrice - fillPrice);
                    }
                } else {
                    // 将买家的代币转移到合约
                    IERC20(sellOrder.currency).safeTransferFrom(
                        buyOrder.maker,
                        address(this),
                        msgValue
                    );
                    // 扣除手续费和版税之后转给卖家
                    IERC20(sellOrder.currency).safeTransfer(
                        sellOrder.maker,
                        fillPrice - protocolFee - royaltyFee
                    );
                    // 版税发送给创作者
                    IERC20(sellOrder.currency).safeTransfer(
                        royaltyReceiver,
                        royaltyFee
                    );
                    if (buyPrice > fillPrice) {
                        IERC20(sellOrder.currency).safeTransfer(
                            buyOrder.maker,
                            buyPrice - fillPrice
                        );
                    }
                }
            } else {
                // 如果买单已经存在
                if (buyPrice < fillPrice) {
                    revert BuyPriceBelowFillPrice(buyPrice, fillPrice);
                }
                if (sellOrder.currency == address(0)) {
                    IWhimLandVault(_vault).withdrawETH(
                        buyOrderKey,
                        buyPrice,
                        address(this)
                    );
                    sellOrder.maker.safeTransferETH(
                        fillPrice - protocolFee - royaltyFee
                    );
                    royaltyReceiver.safeTransferETH(royaltyFee);
                    if (buyPrice > fillPrice) {
                        buyOrder.maker.safeTransferETH(buyPrice - fillPrice);
                    }
                } else {
                    IWhimLandVault(_vault).withdrawERC20(
                        buyOrderKey,
                        buyPrice,
                        sellOrder.currency,
                        address(this)
                    );
                    IERC20(sellOrder.currency).safeTransfer(
                        sellOrder.maker,
                        fillPrice - protocolFee - royaltyFee
                    );
                    IERC20(sellOrder.currency).safeTransfer(
                        royaltyReceiver,
                        royaltyFee
                    );
                    if (buyPrice > fillPrice) {
                        IERC20(sellOrder.currency).safeTransfer(
                            buyOrder.maker,
                            buyPrice - fillPrice
                        );
                    }
                }
                // check if buyOrder exist in order storage , del&fill if exist
                // _removeOrder(buyOrder);

                _updateFilledAmount(filledAmount[buyOrderKey] + 1, buyOrderKey);
            }
            _updateFilledAmount(sellOrder.nft.amount, sellOrderKey);

            emit LogMatch(
                buyOrderKey,
                sellOrderKey,
                buyOrder,
                sellOrder,
                fillPrice
            );

            // 交付NFT给买家
            IWhimLandVault(_vault).withdrawNFT(
                sellOrderKey,
                buyOrder.maker,
                sellOrder.nft.collectionAddr,
                sellOrder.nft.tokenId
            );
            costValue = isBuyExist ? 0 : buyPrice;
        } else {
            revert("HD: sender invalid");
        }
    }

    function _isMatchAvailable(
        LibOrder.Order memory sellOrder,
        LibOrder.Order memory buyOrder,
        OrderKey sellOrderKey,
        OrderKey buyOrderKey
    ) internal view {
        require(
            OrderKey.unwrap(sellOrderKey) != OrderKey.unwrap(buyOrderKey),
            "HD: same order"
        );
        require(
            sellOrder.side == LibOrder.Side.List &&
                buyOrder.side == LibOrder.Side.Bid,
            "HD: side mismatch"
        );
        require(
            sellOrder.saleKind == LibOrder.SaleKind.FixedPriceForItem,
            "HD: kind mismatch"
        );
        require(sellOrder.maker != buyOrder.maker, "HD: same maker");
        require( // check if the asset is the same
            (sellOrder.nft.collectionAddr == buyOrder.nft.collectionAddr &&
                buyOrder.saleKind ==
                LibOrder.SaleKind.FixedPriceForCollection) ||
                (sellOrder.nft.collectionAddr == buyOrder.nft.collectionAddr &&
                    sellOrder.nft.tokenId == buyOrder.nft.tokenId),
            "HD: asset mismatch"
        );
        require(
            filledAmount[sellOrderKey] < sellOrder.nft.amount &&
                filledAmount[buyOrderKey] < buyOrder.nft.amount,
            "HD: order closed"
        );
        require(
            (sellOrder.expiry > block.timestamp || sellOrder.expiry == 0) &&
                (buyOrder.expiry > block.timestamp || buyOrder.expiry == 0),
            "HD: order expired"
        );
        require(
            Price.unwrap(buyOrder.price) >= Price.unwrap(sellOrder.price),
            "HD: price mismatch"
        );
        require(
            sellOrder.currency == buyOrder.currency,
            "HD: currency mismatch"
        );
    }

    /**
     * @notice caculate amount based on share.
     * @param total the total amount.
     * @param share the share in base point.
     */
    function _shareToAmount(
        uint128 total,
        uint128 share
    ) internal pure returns (uint128) {
        return (total * share) / LibPayInfo.TOTAL_SHARE;
    }

    function _checkDelegateCall() private view {
        require(address(this) != self);
    }

    function setVault(address newVault) public onlyOwner {
        require(newVault != address(0), "HD: zero address");
        _vault = newVault;
    }

    function withdrawETH(
        address recipient,
        uint256 amount
    ) external nonReentrant onlyOwner {
        recipient.safeTransferETH(amount);
        emit LogWithdrawETH(recipient, amount);
    }

    function withdrawERC20(
        address recipient,
        address token,
        uint256 amount
    ) external nonReentrant onlyOwner {
        IERC20(token).safeTransfer(recipient, amount);
        emit LogWithdrawERC20(recipient, token, amount);
    }

    function setSupportCurrency(
        address currency,
        bool isSupported
    ) external onlyOwner {
        isSupportedCurrency[currency] = isSupported;
    }

    function setWhitelistedCollection(
        address collection,
        bool isWhitelisted
    ) external onlyOwner {
        isWhitelistedCollection[collection] = isWhitelisted;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    receive() external payable {}

    uint256[50] private __gap;
}
