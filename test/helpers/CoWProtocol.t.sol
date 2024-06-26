// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {Test} from "forge-std/Test.sol";

import {IVault} from "cowprotocol/contracts/interfaces/IVault.sol";
import {
    IERC20,
    GPv2Settlement,
    GPv2Order,
    GPv2Trade,
    GPv2Interaction,
    GPv2Signing
} from "cowprotocol/contracts/GPv2Settlement.sol";
import {GPv2AllowListAuthentication} from "cowprotocol/contracts/GPv2AllowListAuthentication.sol";
import {GPv2Authentication} from "cowprotocol/contracts/interfaces/GPv2Authentication.sol";

import {GPv2TradeEncoder} from "../vendored/GPv2TradeEncoder.sol";
import {TestAccount, TestAccountLib} from "../libraries/TestAccountLib.t.sol";
import {Tokens} from "./Tokens.t.sol";

/**
 * @title CoW Protocol - A helper contract for local integration testing with CoW Protocol.
 * @author mfw78 <mfw78@rndlabs.xyz>
 */
abstract contract CoWProtocol is Test, Tokens {
    using TestAccountLib for TestAccount;

    // --- constants
    uint256 constant PAUSE_WINDOW_DURATION = 7776000;
    uint256 constant BUFFER_PERIOD_DURATION = 2592000;

    // --- contracts
    IVault public vault;
    GPv2Settlement public settlement;

    // --- accounts
    TestAccount admin;
    TestAccount solver;

    address public relayer;

    /**
     * @dev Sets up the CoW Protocol test environment.
     */
    function setUp() public virtual {
        // cowprotocol test accounts
        /// @dev the admin account is used to deploy the vault and allow list manager
        admin = TestAccountLib.createTestAccount("admin");
        /// @dev the solver account simulates a solver in the allow list
        solver = TestAccountLib.createTestAccount("solver");

        vault = IVault(makeAddr("fakeVault"));

        // deploy the allow list manager
        GPv2AllowListAuthentication allowList = new GPv2AllowListAuthentication();
        allowList.initializeManager(admin.addr);

        /// @dev the settlement contract is the main entry point for the CoW Protocol
        settlement = new GPv2Settlement(allowList, vault);

        /// @dev the relayer is the account authorized to spend the user's tokens
        relayer = address(settlement.vaultRelayer());

        // authorize the solver
        vm.prank(admin.addr);
        allowList.addSolver(solver.addr);
    }

    /**
     * Settle a CoW Protocol Order
     * @dev This generates a counter order and signs it.
     * @param who this order belongs to
     * @param counterParty the account that is on the other side of the trade
     * @param order the order to settle
     * @param bundleBytes the ERC-1271 bundle for the order
     * @param _revertSelector the selector to revert with if the order is invalid
     */
    function settle(
        address who,
        TestAccount memory counterParty,
        GPv2Order.Data memory order,
        bytes memory bundleBytes,
        bytes4 _revertSelector
    ) internal {
        // Generate counter party's order
        GPv2Order.Data memory counterOrder = GPv2Order.Data({
            sellToken: order.buyToken,
            buyToken: order.sellToken,
            receiver: address(0),
            sellAmount: order.buyAmount,
            buyAmount: order.sellAmount,
            validTo: order.validTo,
            appData: order.appData,
            feeAmount: 0,
            kind: GPv2Order.KIND_BUY,
            partiallyFillable: false,
            buyTokenBalance: GPv2Order.BALANCE_ERC20,
            sellTokenBalance: GPv2Order.BALANCE_ERC20
        });

        bytes memory counterPartySig =
            counterParty.signPacked(GPv2Order.hash(counterOrder, settlement.domainSeparator()));

        // Authorize the GPv2VaultRelayer to spend bob's sell token
        vm.prank(counterParty.addr);
        IERC20(counterOrder.sellToken).approve(address(relayer), counterOrder.sellAmount);

        // first declare the tokens we will be trading
        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(order.sellToken);
        tokens[1] = IERC20(order.buyToken);

        // second declare the clearing prices
        uint256[] memory clearingPrices = new uint256[](2);
        clearingPrices[0] = counterOrder.sellAmount;
        clearingPrices[1] = counterOrder.buyAmount;

        // third declare the trades
        GPv2Trade.Data[] memory trades = new GPv2Trade.Data[](2);

        // The safe's order is the first trade
        trades[0] = GPv2Trade.Data({
            sellTokenIndex: 0,
            buyTokenIndex: 1,
            receiver: order.receiver,
            sellAmount: order.sellAmount,
            buyAmount: order.buyAmount,
            validTo: order.validTo,
            appData: order.appData,
            feeAmount: order.feeAmount,
            flags: GPv2TradeEncoder.encodeFlags(order, GPv2Signing.Scheme.Eip1271),
            executedAmount: order.sellAmount,
            signature: abi.encodePacked(who, bundleBytes)
        });

        // Bob's order is the second trade
        trades[1] = GPv2Trade.Data({
            sellTokenIndex: 1,
            buyTokenIndex: 0,
            receiver: address(0),
            sellAmount: counterOrder.sellAmount,
            buyAmount: counterOrder.buyAmount,
            validTo: counterOrder.validTo,
            appData: counterOrder.appData,
            feeAmount: counterOrder.feeAmount,
            flags: GPv2TradeEncoder.encodeFlags(counterOrder, GPv2Signing.Scheme.Eip712),
            executedAmount: counterOrder.sellAmount,
            signature: counterPartySig
        });

        // fourth declare the interactions
        GPv2Interaction.Data[][3] memory interactions =
            [new GPv2Interaction.Data[](0), new GPv2Interaction.Data[](0), new GPv2Interaction.Data[](0)];

        // finally we can execute the settlement
        vm.prank(solver.addr);
        if (_revertSelector == bytes4(0)) {
            settlement.settle(tokens, clearingPrices, trades, interactions);
        } else {
            vm.expectRevert(_revertSelector);
            settlement.settle(tokens, clearingPrices, trades, interactions);
        }
    }
}
