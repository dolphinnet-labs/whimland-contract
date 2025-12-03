// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "./token/NFTManager.sol";
import "./token/ERC20Manager.sol";

contract CollectionFactory is Initializable, OwnableUpgradeable {
    address[] public allCollections;

    event CollectionCreated(
        address collectionAddress,
        string name,
        string symbol
    );

    constructor() {
        _disableInitializers();
    }

    function initialize(address owner) external initializer {
        __Ownable_init(owner);
    }

    function createCollection(
        string memory name,
        string memory symbol,
        uint256 maxSupply,
        string memory baseURI,
        address vrf
    ) external returns (address) {
        NFTManager newCol = new NFTManager();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(newCol),
            abi.encodeWithSignature(
                "initialize(string,string,uint256,string,address,address)",
                name,
                symbol,
                maxSupply,
                baseURI,
                msg.sender,
                vrf
            )
        );
        allCollections.push(address(proxy));
        emit CollectionCreated(address(proxy), name, symbol);
        return address(proxy);
    }

    function createERC20(
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        address owner
    ) external returns (address) {
        ERC20Manager newToken = new ERC20Manager();

        ERC1967Proxy proxy = new ERC1967Proxy(
            address(newToken),
            abi.encodeWithSignature(
                "initialize(string,string,uint256,address)",
                name,
                symbol,
                initialSupply,
                owner
            )
        );

        return address(proxy);
    }
}
