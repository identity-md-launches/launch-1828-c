// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {MockCardNFT} from "src/MockCardNFT.sol";
import {CardOracle} from "src/CardOracle.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract CardCatalogEdgesTest is Fixture {
    function test_everyMetadataFieldRejectsEmptyAndOverlongInput() public {
        for (uint256 field; field < 7; ++field) {
            MockCardNFT.Card memory card = _replace(cardMetadata("edge cert"), field, "");
            vm.expectRevert(MockCardNFT.InvalidMetadata.selector);
            nft.mint(bob, card);
            card = _replace(cardMetadata("edge cert"), field, string(new bytes(129)));
            vm.expectRevert(MockCardNFT.InvalidMetadata.selector);
            nft.mint(bob, card);
        }
        assertEq(nft.nextTokenId(), 2);
        assertEq(nft.balanceOf(bob), 0);
    }

    function test_maxLengthMetadataAcceptedAndFieldsCannotAliasAcrossClassHash() public {
        bytes memory label = new bytes(128);
        for (uint256 i; i < label.length; ++i) {
            label[i] = "a";
        }
        MockCardNFT.Card memory card = cardMetadata("maximum metadata cert");
        for (uint256 field; field < 7; ++field) {
            card = _replace(card, field, string(label));
        }
        uint256 id = nft.mint(bob, card);
        assertEq(bytes(nft.cardData(id).cardName).length, 128);
        MockCardNFT.Card memory left = cardMetadata("certificate excluded");
        MockCardNFT.Card memory right = cardMetadata("other certificate");
        left.game = "ab";
        left.set = "c";
        right.game = "a";
        right.set = "bc";
        assertTrue(nft.computeClassId(left) != nft.computeClassId(right), "abi encoding must separate fields");
    }

    function test_eachClassFieldMattersButCertificateDoesNot() public view {
        for (uint256 field; field < 7; ++field) {
            MockCardNFT.Card memory changed = _replace(cardMetadata("100001"), field, "changed");
            if (field == 6) assertEq(nft.computeClassId(changed), cardClass);
            else assertTrue(nft.computeClassId(changed) != cardClass);
        }
    }

    function test_rejectedSafeMintDoesNotConsumeCertificateOrTokenID() public {
        MockCardNFT.Card memory card = cardMetadata("retryable certificate");
        bytes32 certificate = keccak256(abi.encode(card.grader, card.certNumber));
        // CardPool is a contract with no ERC-721 receiver, so safe mint must revert.
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(pool)));
        nft.mint(address(pool), card);
        assertFalse(nft.certificateUsed(certificate));
        assertEq(nft.nextTokenId(), 2);
        uint256 id = nft.mint(bob, card);
        assertEq(id, 2);
        assertTrue(nft.certificateUsed(certificate));
        assertEq(nft.ownerOf(id), bob);
        vm.expectRevert(MockCardNFT.DuplicateCertificate.selector);
        nft.mint(alice, card);
    }

    function test_allTemplateLabelsRejectControlQuoteBackslashAndNonASCII() public {
        string[5] memory invalid = [string(""), "a\"b", "a\\b", "a\nb", unicode"Pokémon"];
        for (uint256 field; field < 4; ++field) {
            for (uint256 i; i < invalid.length; ++i) {
                CardOracle.Template memory value = _label(cardTemplate(), field, invalid[i]);
                vm.expectRevert(CardOracle.InvalidTemplate.selector);
                oracle.setClass(cardClass, value, true);
            }
            uint256 maximum = field == 1 ? 32 : field == 3 ? 64 : 128;
            CardOracle.Template memory oversized = _label(cardTemplate(), field, string(new bytes(maximum + 1)));
            vm.expectRevert(CardOracle.InvalidTemplate.selector);
            oracle.setClass(cardClass, oversized, true);
        }
        assertEq(oracle.classVersion(cardClass), 1);
    }

    function test_slugsCannotInjectPathsQueriesOrJSON() public {
        string[7] memory invalid = [string(""), "Pokemon", "../escape", "card?x=1", "card#x", "card_name", "card\"x"];
        for (uint256 i; i < invalid.length; ++i) {
            CardOracle.Template memory value = cardTemplate();
            value.setSlug = invalid[i];
            vm.expectRevert(CardOracle.InvalidTemplate.selector);
            oracle.setClass(cardClass, value, true);
            value = cardTemplate();
            value.cardSlug = invalid[i];
            vm.expectRevert(CardOracle.InvalidTemplate.selector);
            oracle.setClass(cardClass, value, true);
        }
        vm.expectRevert(CardOracle.InvalidTemplate.selector);
        oracle.setClass(bytes32(0), cardTemplate(), true);
        vm.expectRevert(CardOracle.UnknownClass.selector);
        oracle.requestBody(keccak256("unlisted class"));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_catalogProducesParseableBoundedJSON(bytes32 seed, uint8 lengthSeed) public {
        uint256 length = bound(lengthSeed, 1, 32);
        bytes memory text = new bytes(length);
        for (uint256 i; i < length; ++i) {
            text[i] = bytes1(uint8(97 + uint8(seed[i]) % 26));
        }
        CardOracle.Template memory value = cardTemplate();
        value.cardName = string(text);
        value.cardNumber = string(text);
        value.setName = string(text);
        value.setSlug = string(text);
        value.cardSlug = string(text);
        value.gradeColumn = string(text);
        oracle.setClass(cardClass, value, true);
        assertEq(keccak256(abi.encode(oracle.template(cardClass))), keccak256(abi.encode(value)), "catalog round trip");
        string memory body = string(oracle.requestBody(cardClass));
        string memory question = vm.parseJsonString(body, ".question");
        assertLe(bytes(question).length, 2000);
        assertLt(bytes(body).length, 16_384);
        assertEq(vm.parseJsonUint(body, ".consumer.chainId"), 11155111);
        assertEq(vm.parseJsonAddress(body, ".consumer.verifyingContract"), address(oracle));
        assertEq(vm.parseJsonString(body, ".answerType"), "uint256");
        string memory url = string.concat("https://www.pricecharting.com/game/", string(text), "/", string(text));
        assertEq(vm.parseJsonString(body, ".guards.sources[0]"), url);
        assertTrue(vm.contains(question, string.concat('"', string(text), " #", string(text), '"')));
        assertEq(vm.parseJsonString(body, ".definitions.rounding"), "Whole dollars rounded down.");
    }

    function _replace(MockCardNFT.Card memory card, uint256 field, string memory value)
        internal
        pure
        returns (MockCardNFT.Card memory)
    {
        if (field == 0) card.game = value;
        else if (field == 1) card.set = value;
        else if (field == 2) card.cardName = value;
        else if (field == 3) card.cardNumber = value;
        else if (field == 4) card.grader = value;
        else if (field == 5) card.grade = value;
        else card.certNumber = value;
        return card;
    }

    function _label(CardOracle.Template memory value, uint256 field, string memory text)
        internal
        pure
        returns (CardOracle.Template memory)
    {
        if (field == 0) value.cardName = text;
        else if (field == 1) value.cardNumber = text;
        else if (field == 2) value.setName = text;
        else value.gradeColumn = text;
        return value;
    }
}
