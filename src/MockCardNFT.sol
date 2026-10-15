// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Admin} from "./Admin.sol";

/// @notice Owner-issued test representations of vaulted cards. Metadata is immutable after mint.
contract MockCardNFT is ERC721, Admin {
    struct Card {
        string game;
        string set;
        string cardName;
        string cardNumber;
        string grader;
        string grade;
        string certNumber;
    }

    error InvalidMetadata();
    error DuplicateCertificate();
    uint256 public nextTokenId = 1;
    mapping(uint256 => Card) private _cards;
    mapping(uint256 => bytes32) private _classes;
    mapping(bytes32 => bool) public certificateUsed;
    event CardMinted(uint256 indexed tokenId, bytes32 indexed classId, address indexed holder);

    constructor(address admin) ERC721("CardVault Card", "CARD") Admin(admin) {}

    /// @dev Certificates identify individual copies, so are deliberately excluded from the class.
    function computeClassId(Card memory card) public pure returns (bytes32) {
        return keccak256(abi.encode(card.game, card.set, card.cardName, card.cardNumber, card.grader, card.grade));
    }

    function mint(address to, Card calldata card) external onlyOwner returns (uint256 tokenId) {
        _check(card.game);
        _check(card.set);
        _check(card.cardName);
        _check(card.cardNumber);
        _check(card.grader);
        _check(card.grade);
        _check(card.certNumber);
        bytes32 cert = keccak256(abi.encode(card.grader, card.certNumber));
        if (certificateUsed[cert]) revert DuplicateCertificate();
        certificateUsed[cert] = true;
        tokenId = nextTokenId++;
        _cards[tokenId] = card;
        bytes32 id = computeClassId(card);
        _classes[tokenId] = id;
        _safeMint(to, tokenId);
        emit CardMinted(tokenId, id, to);
    }

    function cardData(uint256 tokenId) external view returns (Card memory) {
        _requireOwned(tokenId);
        return _cards[tokenId];
    }

    function classId(uint256 tokenId) external view returns (bytes32) {
        _requireOwned(tokenId);
        return _classes[tokenId];
    }

    function _check(string calldata value) private pure {
        if (bytes(value).length == 0 || bytes(value).length > 128) revert InvalidMetadata();
    }
}
