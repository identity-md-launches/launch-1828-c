// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Guarded} from "./Guarded.sol";
import {OracleAttestation, OracleAttestationConsumer} from "./OracleAttestation.sol";
import {IIntake} from "./interfaces/IIntake.sol";

/// @notice Same-chain IdentityMD consumer. USD integer answers are scaled to six-decimal USDC.
contract CardOracle is OracleAttestationConsumer, Guarded, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Strings for uint256;

    struct Template {
        string cardName;
        string cardNumber;
        string setName;
        string setSlug;
        string cardSlug;
        string gradeColumn;
    }

    struct Price {
        uint256 price;
        uint64 issuedAt;
        uint64 expiresAt;
    }

    struct Request {
        bytes32 classId;
        address intake;
        address requester;
        uint64 openedAt;
        uint64 deadline;
        uint32 version;
        uint256 observationChainId;
        uint16 panelSize;
        uint16 quorum;
        bool pending;
        bytes32 bodyHash;
        bytes32 oracleId;
        bytes32 questionHash;
    }

    uint256 public constant MAX_AGE = 1 days;
    uint256 public constant REQUEST_TIMEOUT = 2 days;
    uint256 public constant MAX_USD = 1_000_000_000_000;
    address public intake;
    address public paymentAsset;
    uint256 public requestFee;
    bytes32 public action;
    /// @notice PriceCharting is off chain; mainnet supplies the time window, independently of the consumer domain.
    uint256 public observationChainId = 1;
    uint16 public panelSize = 30;
    uint16 public quorum = 21;
    mapping(bytes32 => Template) private _templates;
    mapping(bytes32 => bool) public allowed;
    mapping(bytes32 => uint32) public classVersion;
    mapping(bytes32 => Price) public prices;
    mapping(bytes32 => Request) public requests;
    mapping(bytes32 => bytes32) public pendingForClass;
    mapping(bytes32 => bytes32) public intakeForOracleId;

    error UnknownClass();
    error InvalidTemplate();
    error ClassBusy();
    error UnknownRequest();
    error NotIntake();
    error RequestExpired();
    error TooEarly();
    error BadAttestation();
    error PanelTooWeak();
    error StalePrice();
    error InvalidConfiguration();
    error BadRelayBinding();
    error WrongPayment();

    event ClassSet(bytes32 indexed classId, uint32 version, bool enabled);
    event Requested(bytes32 indexed intakeId, bytes32 indexed classId, address indexed payer, bytes32 bodyHash);
    event PriceStored(
        bytes32 indexed classId, bytes32 indexed oracleId, uint256 price, uint64 issuedAt, uint64 expiresAt
    );
    event Failed(bytes32 indexed intakeId, uint8 status, bytes32 reason, uint16 agreed, uint16 answered);
    event TimedOut(bytes32 indexed intakeId);
    event RelayBound(bytes32 indexed intakeId, bytes32 indexed oracleId, bytes32 questionHash);
    event ObservationChainSet(uint256 chainId);
    event IntakeSet(address indexed intake);
    event PaymentSet(address indexed asset, uint256 fee);
    event ActionSet(bytes32 action);
    event PanelSet(uint16 panelSize, uint16 quorum);

    constructor(address admin, address intake_, address imd_, address signer_)
        OracleAttestationConsumer(signer_)
        Guarded(admin)
    {
        if (intake_ == address(0) || imd_ == address(0)) revert InvalidAddress();
        intake = intake_;
        paymentAsset = imd_;
        requestFee = 0.5 ether;
        action = bytes32("oracle.request@oracle-1");
    }

    function setClass(bytes32 id, Template calldata value, bool enabled) external onlyOwner {
        if (id == bytes32(0)) revert InvalidTemplate();
        if (pendingForClass[id] != bytes32(0)) revert ClassBusy();
        _label(value.cardName, 128);
        _label(value.cardNumber, 32);
        _label(value.setName, 128);
        _label(value.gradeColumn, 64);
        _slug(value.setSlug);
        _slug(value.cardSlug);
        _templates[id] = value;
        allowed[id] = enabled;
        ++classVersion[id];
        delete prices[id];
        emit ClassSet(id, classVersion[id], enabled);
    }

    function request(bytes32 id) external view returns (Request memory) {
        return requests[id];
    }

    function template(bytes32 id) external view returns (Template memory) {
        return _templates[id];
    }

    function requestBody(bytes32 id) public view returns (bytes memory) {
        if (!allowed[id]) revert UnknownClass();
        Template storage t = _templates[id];
        string memory url = string.concat("https://www.pricecharting.com/game/", t.setSlug, "/", t.cardSlug);
        string memory question = string.concat(
            'On pricecharting.com, on the product page for "',
            t.cardName,
            " #",
            t.cardNumber,
            '" in "',
            t.setName,
            '" (URL starting ',
            url,
            '), what is the price shown in the "',
            t.gradeColumn,
            '" column at the time of reading within the pinned window?'
        );
        return bytes(
            string.concat(
                '{"v":1,"question":"',
                Strings.escapeJSON(question),
                '","chainId":',
                observationChainId.toString(),
                ',"window":{"hours":24},"answerType":"uint256","evidence":"panel","panelSize":',
                uint256(panelSize).toString(),
                ',"quorum":',
                uint256(quorum).toString(),
                ',"toleranceBps":500,"validForSeconds":86400,"definitions":{',
                '"term":"The single number displayed in the named grade column on the specified product page. ',
                'Do not substitute an auction sale, an ungraded price, or another grade. If unavailable, report inability, not zero.",',
                '"period":"Value when read within the pinned block window.",',
                '"unit":"US dollars.","rounding":"Whole dollars rounded down."},',
                '"guards":{"sources":["',
                url,
                '"],"minSources":1,"min":"1","max":"1000000000000"},',
                '"consumer":{"chainId":',
                block.chainid.toString(),
                ',"verifyingContract":"',
                Strings.toHexString(address(this)),
                '"}}'
            )
        );
    }

    function requestPrice(bytes32 id) external whenNotPaused nonReentrant returns (bytes32 intakeId) {
        if (!allowed[id]) revert UnknownClass();
        if (pendingForClass[id] != bytes32(0)) revert ClassBusy();
        if (IIntake(intake).priceOf(action, paymentAsset) != requestFee) revert WrongPayment();
        bytes memory body = requestBody(id);
        IERC20 token = IERC20(paymentAsset);
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), requestFee);
        if (token.balanceOf(address(this)) != beforeBalance + requestFee) revert WrongPayment();
        token.forceApprove(intake, requestFee);
        intakeId = IIntake(intake)
            .requestWithFailure(
                action,
                body,
                IIntake.Callback(address(this), this.onPrice.selector),
                this.onFailure.selector,
                paymentAsset,
                requestFee
            );
        token.forceApprove(intake, 0);
        if (token.balanceOf(address(this)) != beforeBalance) revert WrongPayment();
        if (intakeId == bytes32(0) || requests[intakeId].requester != address(0)) revert UnknownRequest();
        requests[intakeId] = Request({
            classId: id,
            intake: intake,
            requester: msg.sender,
            openedAt: uint64(block.timestamp),
            deadline: uint64(block.timestamp + REQUEST_TIMEOUT),
            version: classVersion[id],
            observationChainId: observationChainId,
            panelSize: panelSize,
            quorum: quorum,
            pending: true,
            bodyHash: keccak256(body),
            oracleId: bytes32(0),
            questionHash: bytes32(0)
        });
        pendingForClass[id] = intakeId;
        emit Requested(intakeId, id, msg.sender, keccak256(body));
    }

    function onPrice(bytes32 intakeId, OracleAttestation.Attestation calldata a, bytes calldata signature)
        external
        nonReentrant
    {
        Request storage r = requests[intakeId];
        if (!r.pending) revert UnknownRequest();
        if (msg.sender != r.intake) revert NotIntake();
        _settle(intakeId, a, signature);
    }

    /// @notice Recovery for missed callbacks. Owner verifies the API's request/body mapping before binding.
    /// @dev Neither a relayer nor a requester can invent the UUID-to-Intake pairing.
    function bindRelay(bytes32 intakeId, bytes32 oracleId, bytes32 questionHash) external onlyOwner {
        Request storage r = requests[intakeId];
        if (!r.pending) revert UnknownRequest();
        if (block.timestamp > r.deadline) revert RequestExpired();
        if (
            oracleId == bytes32(0) || questionHash == bytes32(0) || r.oracleId != bytes32(0)
                || intakeForOracleId[oracleId] != bytes32(0) || consumed[oracleId]
        ) revert BadRelayBinding();
        r.oracleId = oracleId;
        r.questionHash = questionHash;
        intakeForOracleId[oracleId] = intakeId;
        emit RelayBound(intakeId, oracleId, questionHash);
    }

    function submit(OracleAttestation.Attestation calldata a, bytes calldata signature) external nonReentrant {
        bytes32 intakeId = intakeForOracleId[a.requestId];
        if (intakeId == bytes32(0) || !requests[intakeId].pending) revert UnknownRequest();
        _settle(intakeId, a, signature);
    }

    function _settle(bytes32 intakeId, OracleAttestation.Attestation calldata a, bytes calldata signature) private {
        Request storage r = requests[intakeId];
        if (block.timestamp > r.deadline) revert RequestExpired();
        if (r.oracleId != bytes32(0) && (r.oracleId != a.requestId || r.questionHash != a.questionHash)) {
            revert BadRelayBinding();
        }
        if (
            a.panelSize < r.panelSize || a.quorum < r.quorum || a.agreed < a.quorum || a.agreed > a.panelSize
                || a.quorum > a.panelSize
        ) revert PanelTooWeak();
        // The base check tolerates an issuance up to ISSUED_AT_TOLERANCE ahead of this block's clock;
        // freshPrice refuses to serve such a price until the chain's clock catches up.
        _verifyAttestation(a, signature);
        if (
            a.chainId != r.observationChainId || a.requestId == bytes32(0) || a.questionHash == bytes32(0)
                || a.fromBlock > a.toBlock || a.issuedAt < r.openedAt || a.expiresAt < a.issuedAt
                || a.expiresAt > uint256(a.issuedAt) + MAX_AGE || uint256(a.issuedAt) + MAX_AGE < block.timestamp
                || a.answer.length != 32
        ) revert BadAttestation();
        if (!allowed[r.classId] || r.version != classVersion[r.classId]) revert UnknownClass();
        uint256 dollars = decodeUint256(a);
        // Zero is the "column unavailable" reading the definitions forbid, never a valuation.
        if (dollars == 0 || dollars > MAX_USD) revert BadAttestation();
        if (a.issuedAt <= prices[r.classId].issuedAt) revert StalePrice();
        _consume(a.requestId);
        r.pending = false;
        delete pendingForClass[r.classId];
        prices[r.classId] = Price(dollars * 1e6, a.issuedAt, a.expiresAt);
        emit PriceStored(r.classId, a.requestId, dollars * 1e6, a.issuedAt, a.expiresAt);
    }

    function onFailure(bytes32 intakeId, uint8 status, bytes32 reason, uint16 agreed, uint16 answered, bytes calldata)
        external
        nonReentrant
    {
        Request storage r = requests[intakeId];
        if (!r.pending) revert UnknownRequest();
        if (msg.sender != r.intake) revert NotIntake();
        if (status != 1 && status != 2) revert BadAttestation();
        r.pending = false;
        delete pendingForClass[r.classId];
        emit Failed(intakeId, status, reason, agreed, answered);
    }

    /// @notice Clears a lost request after two days. The Intake fee is already spent; there is no refund.
    function clearExpired(bytes32 intakeId) external {
        Request storage r = requests[intakeId];
        if (!r.pending) revert UnknownRequest();
        if (block.timestamp <= r.deadline) revert TooEarly();
        r.pending = false;
        delete pendingForClass[r.classId];
        emit TimedOut(intakeId);
    }

    function freshPrice(bytes32 id) external view returns (Price memory p) {
        if (!allowed[id]) revert UnknownClass();
        p = prices[id];
        if (
            p.issuedAt == 0 || p.issuedAt > block.timestamp || block.timestamp > p.expiresAt
                || block.timestamp - p.issuedAt > MAX_AGE
        ) revert StalePrice();
    }

    function setObservationChain(uint256 chainId_) external onlyOwner {
        if (chainId_ == 0) revert InvalidConfiguration();
        observationChainId = chainId_;
        emit ObservationChainSet(chainId_);
    }

    function setIntake(address next) external onlyOwner {
        if (next == address(0)) revert InvalidAddress();
        intake = next;
        emit IntakeSet(next);
    }

    function setPayment(address asset_, uint256 fee_) external onlyOwner {
        if (asset_ == address(0) || fee_ == 0) revert InvalidConfiguration();
        paymentAsset = asset_;
        requestFee = fee_;
        emit PaymentSet(asset_, fee_);
    }

    function setAction(bytes32 next) external onlyOwner {
        if (next == bytes32(0)) revert InvalidConfiguration();
        action = next;
        emit ActionSet(next);
    }

    function setSigner(address next) external onlyOwner {
        _setOracleSigner(next);
    }

    function setPanel(uint16 size, uint16 agreement) external onlyOwner {
        if (size < 5 || size > 100 || agreement < 2 || agreement > size) revert InvalidConfiguration();
        panelSize = size;
        quorum = agreement;
        emit PanelSet(size, agreement);
    }

    // Restrict the owner's catalog to bounded printable ASCII. Quotes and backslashes cannot break
    // the panel's quoted labels. Non-ASCII names must use a reviewed transliteration.
    function _label(string calldata s, uint256 maximum) private pure {
        bytes calldata b = bytes(s);
        if (b.length == 0 || b.length > maximum) revert InvalidTemplate();
        for (uint256 i; i < b.length; ++i) {
            if (b[i] < 0x20 || b[i] > 0x7e || b[i] == '"' || b[i] == "\\") revert InvalidTemplate();
        }
    }

    function _slug(string calldata s) private pure {
        bytes calldata b = bytes(s);
        if (b.length == 0 || b.length > 128) revert InvalidTemplate();
        for (uint256 i; i < b.length; ++i) {
            bytes1 c = b[i];
            if (!((c >= "a" && c <= "z") || (c >= "0" && c <= "9") || c == "-")) revert InvalidTemplate();
        }
    }
}
