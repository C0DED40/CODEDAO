// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBridgeAdapter, IRepaymentReceiver, Repayment} from "../../src/interfaces/IBridge.sol";

/// @dev Stands in for the messaging layer. `deliver` is split from `send` so a test can exercise the
///      window in which value has left the satellite and not yet arrived home, which is precisely the
///      bridge risk §9 assigns to the DAO rather than the founder.
contract MockBridgeAdapter is IBridgeAdapter {
    IERC20 public immutable weth;
    uint256 public fee = 0.01 ether;

    bytes public lastPayload;
    uint256 public lastAmount;
    uint256 public sends;

    IRepaymentReceiver public homeReceiver;
    uint32 public srcChainId = 42;

    constructor(IERC20 weth_) {
        weth = weth_;
    }

    function setFee(uint256 f) external {
        fee = f;
    }

    function setReceiver(IRepaymentReceiver r) external {
        homeReceiver = r;
    }

    function quoteFee(bytes calldata) external view returns (uint256) {
        return fee;
    }

    function send(uint256 wethAmount, bytes calldata payload) external payable {
        if (wethAmount != 0) weth.transferFrom(msg.sender, address(this), wethAmount);
        lastPayload = payload;
        lastAmount = wethAmount;
        ++sends;
    }

    /// @dev Complete the crossing: hand the WETH to the receiver and announce the batch.
    function deliver() external {
        if (lastAmount != 0) weth.transfer(address(homeReceiver), lastAmount);
        homeReceiver.receiveBatch(srcChainId, lastAmount, lastPayload);
    }

    /// @dev Announce a batch without delivering the WETH, to prove the receiver refuses it.
    function announceWithoutDelivering() external {
        homeReceiver.receiveBatch(srcChainId, lastAmount, lastPayload);
    }
}

contract EscrowRecordSpy {
    struct Record {
        uint256 dealId;
        uint16 count;
        uint256 wethValue;
        bool viaFloor;
    }

    Record[] public records;

    function recordInstallments(uint256 dealId, uint16 count, uint256 wethValue, bool viaFloor) external {
        records.push(Record(dealId, count, wethValue, viaFloor));
    }

    function count() external view returns (uint256) {
        return records.length;
    }

    function releaseTranche(uint256, uint8) external {}
    function challengeTge(uint256) external {}

    function vintageOf(uint256) external pure returns (uint32) {
        return 0;
    }

    function isDefaulted(address) external pure returns (bool) {
        return false;
    }

    function milestoneHash(uint256, uint8) external pure returns (bytes32) {
        return bytes32(0);
    }
}

contract VintageCreditSpy {
    mapping(uint32 => uint256) public credited;
    uint256 public calls;
    IERC20 public immutable code;

    constructor(IERC20 code_) {
        code = code_;
    }

    function creditVintage(uint32 vintage, uint256 amount) external {
        code.transferFrom(msg.sender, address(this), amount);
        credited[vintage] += amount;
        ++calls;
    }

    function syncVintageWeight(address, uint32, uint256) external {}
}

contract OracleRateStub {
    uint256 public codePerWeth = 100_000e18;

    function setRate(uint256 r) external {
        codePerWeth = r;
    }

    function wethToCode(uint256 wethAmount) external view returns (uint256) {
        return (wethAmount * codePerWeth) / 1e18;
    }

    function poke() external {}
}
