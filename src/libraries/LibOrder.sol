// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Price} from "./RedBlackTreeLibrary.sol";

type OrderKey is bytes32;

library LibOrder {
    enum Side {
        List,
        Bid
    }

    enum SaleKind {
        FixedPriceForCollection,
        FixedPriceForItem
    }

    struct Asset {
        uint256 tokenId;
        address collectionAddr;
        uint96 amount;
    }

    struct NFTInfo {
        address collection;
        uint256 tokenId;
    }

    struct Order {
        Side side;
        SaleKind saleKind;
        address maker;
        Asset nft;
        Price price; // unit price of nft
        address currency; // currency address for Bid order, address(0) for ETH
        uint64 expiry;
        uint64 salt;
    }

    struct DBOrder {
        Order order;
        OrderKey next;
    }

    /// @dev Order queue: used to store orders of the same price
    struct OrderQueue {
        OrderKey head;
        OrderKey tail;
    }

    struct EditDetail {
        OrderKey oldOrderKey; // old order key which need to be edit
        LibOrder.Order newOrder; // new order struct which need to be add
    }

    struct MatchDetail {
        LibOrder.Order sellOrder;
        LibOrder.Order buyOrder;
    }

    OrderKey public constant ORDERKEY_SENTINEL = OrderKey.wrap(0x0);

    bytes32 public constant ASSET_TYPEHASH =
        keccak256(
            "Asset(uint256 tokenId,address collectionAddr,uint96 amount)"
        );

    bytes32 public constant ORDER_TYPEHASH =
        keccak256(
            "Order(uint8 side,uint8 saleKind,address maker,Asset nft,uint128 price,uint64 expiry,uint64 salt)Asset(uint256 tokenId,address collectionAddr,uint96 amount)"
        );

    function hash(Asset memory asset) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    ASSET_TYPEHASH,
                    asset.tokenId,
                    asset.collectionAddr,
                    asset.amount
                )
            );
    }

    function hash(Order memory order) internal pure returns (OrderKey) {
        return
            OrderKey.wrap(
                keccak256(
                    abi.encode(
                        ORDER_TYPEHASH,
                        order.side,
                        order.saleKind,
                        order.maker,
                        hash(order.nft),
                        Price.unwrap(order.price),
                        order.currency,
                        order.expiry,
                        order.salt
                    )
                )
            );
    }

    function isSentinel(OrderKey orderKey) internal pure returns (bool) {
        return OrderKey.unwrap(orderKey) == OrderKey.unwrap(ORDERKEY_SENTINEL);
    }

    function isNotSentinel(OrderKey orderKey) internal pure returns (bool) {
        return OrderKey.unwrap(orderKey) != OrderKey.unwrap(ORDERKEY_SENTINEL);
    }
}
