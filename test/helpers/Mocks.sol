// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IIntake} from "../../src/interfaces/IIntake.sol";
import {OracleAttestation} from "../../src/OracleAttestation.sol";

contract TestIMD is ERC20 {
    constructor() ERC20("Test IMD", "IMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockIntake is IIntake {
    struct Ask {
        Callback callback;
        bytes4 failure;
        bytes body;
        address asset;
        uint256 amount;
        bytes32 action;
    }
    mapping(bytes32 => Ask) private _asks;
    uint256 public nonce;
    uint256 public price = 0.5 ether;
    bool public takePayment = true;
    bytes32 public forcedId;

    function setPrice(uint256 p) external {
        price = p;
    }

    function setTakePayment(bool value) external {
        takePayment = value;
    }

    function setForcedId(bytes32 id) external {
        forcedId = id;
    }

    function priceOf(bytes32, address) external view returns (uint256) {
        return price;
    }

    function ask(bytes32 id) external view returns (Ask memory) {
        return _asks[id];
    }

    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        bytes4 onFailure,
        address asset,
        uint256 amount
    ) external payable returns (bytes32 id) {
        if (takePayment) require(IERC20(asset).transferFrom(msg.sender, address(this), amount));
        id = forcedId == bytes32(0) ? keccak256(abi.encode(address(this), ++nonce)) : forcedId;
        _asks[id] = Ask(callback, onFailure, body, asset, amount, action);
    }

    function deliver(bytes32 id, OracleAttestation.Attestation calldata a, bytes calldata signature)
        external
        returns (bool ok, bytes memory data)
    {
        Callback memory cb = _asks[id].callback;
        (ok, data) = cb.target.call{gas: 200_000}(abi.encodeWithSelector(cb.selector, id, a, signature));
    }

    function fail(bytes32 id, uint8 status, bytes32 reason) external returns (bool ok) {
        Ask storage r = _asks[id];
        (ok,) = r.callback.target.call{gas: 200_000}(
            abi.encodeWithSelector(r.failure, id, status, reason, uint16(0), uint16(0), bytes(""))
        );
    }
}
