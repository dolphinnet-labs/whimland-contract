// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {LibTransferSafeUpgradeable, IERC721} from "./libraries/LibTransferSafeUpgradeable.sol";

import {NFTManager} from "./token/NFTManager.sol";

contract NFTAuction is
    ReentrancyGuardUpgradeable,
    ContextUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;
    using LibTransferSafeUpgradeable for IERC721;
    using LibTransferSafeUpgradeable for address;

    uint256 public perFee; // 500 = 500 / 10000 = 5%

    struct Auction {
        address seller;
        address nftCollection;
        uint256 tokenId;
        address currency; // 竞价货币地址，ETH 用 address(0)
        uint256 minBid; // 起拍价
        uint256 endTime;
        uint256 minBidIncrement;
        bool settled;
        address highestBidder;
        uint256 highestBid;
    }

    struct Bid {
        address bidder;
        uint256 amount;
    }

    uint256 public auctionCount;
    mapping(uint256 => Auction) public auctions;
    mapping(uint256 => mapping(address => uint256)) public pendingReturns;
    mapping(address => mapping(uint256 => uint256)) public bids; // address => auctionId => amount
    mapping(uint256 => address) public claimableWinner; // auctionId => winner
    mapping(uint256 => bool) public nftDelivered; // auctionId => delivered
    mapping(address => bool) public isWhitelistedCollection;
    mapping(address => uint256) public totalFeesCollected;

    event AuctionCreated(
        uint256 auctionId,
        address seller,
        address nftCollection,
        uint256 tokenId,
        uint256 minBid,
        uint256 endTime,
        uint256 minBidIncrement,
        address currency
    );
    event LogWithdrawETH(address recipient, uint256 amount);
    event LogWithdrawERC20(address recipient, address token, uint256 amount);

    event BidPlaced(uint256 auctionId, address bidder, uint256 amount);
    event AuctionSettled(uint256 auctionId, address winner, uint256 amount);
    event AuctionPerFeeSet(uint256 oldPerFee, uint256 newPerFee);
    event NftDeliveryFailed(
        uint256 indexed auctionId,
        address indexed winner,
        bytes reason
    );

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _initialOwner,
        uint256 _perFee
    ) public initializer {
        __Context_init();
        __Ownable_init(_initialOwner);
        __Pausable_init();
        __ReentrancyGuard_init();
        perFee = _perFee;
    }

    // 创建拍卖
    function createAuction(
        address _nftCollection,
        uint256 _tokenId,
        address _currency,
        uint256 _minBid,
        uint256 _duration,
        uint256 _minBidIncrement
    ) external nonReentrant whenNotPaused {
        require(_duration > 0, "Duration must be > 0");
        require(
            isWhitelistedCollection[_nftCollection],
            "Collection not allowed"
        );

        // 托管 NFT 到合约
        IERC721(_nftCollection).safeTransferFrom(
            msg.sender,
            address(this),
            _tokenId
        );

        auctionCount++;
        auctions[auctionCount] = Auction({
            seller: msg.sender,
            nftCollection: _nftCollection,
            tokenId: _tokenId,
            currency: _currency,
            minBid: _minBid,
            endTime: block.timestamp + _duration,
            minBidIncrement: _minBidIncrement,
            settled: false,
            highestBidder: address(0),
            highestBid: 0
        });

        emit AuctionCreated(
            auctionCount, // 拍卖编号
            msg.sender,
            _nftCollection,
            _tokenId,
            _minBid,
            block.timestamp + _duration,
            _minBidIncrement,
            _currency
        );
    }

    // 参与拍卖
    function placeBid(
        uint256 _auctionId,
        uint256 _amount
    ) external payable nonReentrant whenNotPaused {
        Auction storage auction = auctions[_auctionId];
        require(block.timestamp < auction.endTime, "Auction ended");
        require(!auction.settled, "Auction settled");

        require(_amount >= auction.minBid, "Bid below min price");
        require(_amount > auction.highestBid, "Bid not higher than current");

        require(
            _amount > bids[msg.sender][_auctionId],
            "New bid must be higher than previous bid"
        );
        uint256 bidAmount = _amount - bids[msg.sender][_auctionId]; // 计算差价
        bids[msg.sender][_auctionId] = _amount;

        require(bidAmount >= auction.minBidIncrement, "Bid increment too low");

        if (auction.currency == address(0)) {
            require(msg.value >= bidAmount, "Insufficient ETH sent");
            msg.sender.safeTransferETH(msg.value - bidAmount); // 返还多余 ETH
        } else {
            // ERC20 出价
            IERC20(auction.currency).safeTransferFrom(
                msg.sender,
                address(this),
                bidAmount
            );
        }

        // 返还上一次最高出价者
        if (auction.highestBid > 0 && auction.highestBidder != msg.sender) {
            pendingReturns[_auctionId][auction.highestBidder] = auction
                .highestBid;
        }

        auction.highestBid = _amount;
        auction.highestBidder = msg.sender;
        pendingReturns[_auctionId][msg.sender] = 0;

        emit BidPlaced(_auctionId, msg.sender, _amount);
    }

    // 提现多余资金
    function withdraw(uint256 _auctionId) external nonReentrant whenNotPaused {
        Auction storage auction = auctions[_auctionId];
        uint256 amount = pendingReturns[_auctionId][msg.sender];
        require(amount > 0, "Nothing to withdraw");
        require(auction.settled, "Not settled yet");
        require(
            msg.sender != auctions[_auctionId].highestBidder,
            "Winner cannot withdraw"
        );

        pendingReturns[_auctionId][msg.sender] = 0;

        if (auction.currency == address(0)) {
            msg.sender.safeTransferETH(amount);
        } else {
            IERC20(auction.currency).safeTransfer(msg.sender, amount);
        }
    }

    // 拍卖结算
    function settleAuction(
        uint256 _auctionId
    ) external nonReentrant whenNotPaused {
        Auction storage auction = auctions[_auctionId];
        require(block.timestamp >= auction.endTime, "Auction not ended");
        require(!auction.settled, "Already settled");

        auction.settled = true;

        // 计算手续费
        uint256 auctionFee = (auction.highestBid * perFee) / 10000;
        // 计算版税
        (address royaltyReceiver, uint256 royaltyFee) = NFTManager(
            payable(auction.nftCollection)
        ).royaltyInfo(auction.tokenId, auction.highestBid);

        if (auction.highestBidder != address(0)) {
            // 赢家获得 NFT
            try
                IERC721(auction.nftCollection).safeTransferFrom(
                    address(this),
                    auction.highestBidder,
                    auction.tokenId
                )
            {
                nftDelivered[_auctionId] = true; // 成功：标记已交付
                // 成功就不记录 claimableWinner（保持为0）
            } catch (bytes memory reason) {
                claimableWinner[_auctionId] = auction.highestBidder; // 失败：记录 winner 可后续 claim
                emit NftDeliveryFailed(
                    _auctionId,
                    auction.highestBidder,
                    reason
                );
                // 注意：这里不要 revert，让 settleAuction 继续走完并落地 settled
            }

            // 卖家收款(扣除手续费和版税)
            if (auction.currency == address(0)) {
                auction.seller.safeTransferETH(
                    auction.highestBid - auctionFee - royaltyFee
                );
                // 版税发送给创作者
                royaltyReceiver.safeTransferETH(royaltyFee);
                totalFeesCollected[address(0)] += auctionFee;
            } else {
                IERC20(auction.currency).safeTransfer(
                    auction.seller,
                    auction.highestBid - auctionFee - royaltyFee
                );
                IERC20(auction.currency).safeTransfer(
                    royaltyReceiver,
                    royaltyFee
                );
                totalFeesCollected[auction.currency] += auctionFee;
            }
        } else {
            // 没有人出价，退回 NFT 给卖家
            IERC721(auction.nftCollection).safeTransferFrom(
                address(this),
                auction.seller,
                auction.tokenId
            );
        }

        emit AuctionSettled(
            _auctionId,
            auction.highestBidder,
            auction.highestBid
        );
    }

    function claimNFTForWinner(
        uint256 _auctionId
    ) external nonReentrant whenNotPaused {
        Auction storage auction = auctions[_auctionId];
        require(auction.settled, "Auction not settled");
        require(
            msg.sender == claimableWinner[_auctionId],
            "Not eligible to claim"
        );

        // 转移 NFT 给赢家
        IERC721(auction.nftCollection).safeTransferFrom(
            address(this),
            msg.sender,
            auction.tokenId
        );

        // 清除记录，防止重复领取
        claimableWinner[_auctionId] = address(0);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
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

    function setPerFee(uint256 _perFee) public onlyOwner {
        emit AuctionPerFeeSet(perFee, _perFee);
        perFee = _perFee;
    }

    function setWhitelistedCollection(
        address collection,
        bool isWhitelisted
    ) external onlyOwner {
        isWhitelistedCollection[collection] = isWhitelisted;
    }

    function getTotalFeesCollected(
        address currency
    ) external view returns (uint256) {
        return totalFeesCollected[currency];
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
