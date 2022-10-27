// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "forge-std/Test.sol";
import "../../src/USX.sol";
import "../../src/proxy/ERC1967Proxy.sol";
import "../interfaces/IUSXTest.t.sol";
import "../common/constants.t.sol";

contract TestMintAndBurn is Test {
    using stdStorage for StdStorage;

    // Test Contracts
    USX public usx_implementation;
    ERC1967Proxy public usx_proxy;

    // Test Constants
    uint256 constant TEST_BURN_AMOUNT = 10e18;

    // Events
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function setUp() public {
        // Deploy USX implementation, and link to proxy
        usx_implementation = new USX();
        usx_proxy =
            new ERC1967Proxy(address(usx_implementation), abi.encodeWithSignature("initialize(address)", LZ_ENDPOINT));

        // Set Treasury Admin
        IUSXTest(address(usx_proxy)).manageTreasuries(TREASURY, true, true);
    }

    function test_mint() public {
        // Expectations
        vm.expectEmit(true, true, true, true, address(usx_proxy));
        emit Transfer(address(0), address(this), TEST_MINT_AMOUNT);

        // Pre-action Assertions
        assertEq(IUSX(address(usx_proxy)).totalSupply(), 0);
        assertEq(IUSX(address(usx_proxy)).balanceOf(address(this)), 0);

        // Act
        vm.prank(TREASURY);
        IUSX(address(usx_proxy)).mint(address(this), TEST_MINT_AMOUNT);

        // Post-action Assertions
        assertEq(IUSX(address(usx_proxy)).totalSupply(), TEST_MINT_AMOUNT);
        assertEq(IUSX(address(usx_proxy)).balanceOf(address(this)), TEST_MINT_AMOUNT);
    }

    function test_burn() public {
        // Setup
        vm.prank(TREASURY);
        IUSX(address(usx_proxy)).mint(address(this), TEST_MINT_AMOUNT);

        // Pre-action Assertions
        assertEq(IUSX(address(usx_proxy)).totalSupply(), TEST_MINT_AMOUNT);
        assertEq(IUSX(address(usx_proxy)).balanceOf(address(this)), TEST_MINT_AMOUNT);

        // Expectations
        vm.expectEmit(true, true, true, true, address(usx_proxy));
        emit Transfer(address(this), address(0), TEST_BURN_AMOUNT);

        // Act
        vm.prank(TREASURY);
        IUSX(address(usx_proxy)).burn(address(this), TEST_BURN_AMOUNT);

        // Post-action Assertions
        assertEq(IUSX(address(usx_proxy)).totalSupply(), TEST_MINT_AMOUNT - TEST_BURN_AMOUNT);
        assertEq(IUSX(address(usx_proxy)).balanceOf(address(this)), TEST_MINT_AMOUNT - TEST_BURN_AMOUNT);
    }

    function testFail_burn_amount() public {
        // Setup
        vm.prank(TREASURY);
        IUSX(address(usx_proxy)).mint(address(this), TEST_MINT_AMOUNT);

        // Act
        vm.prank(TREASURY);
        IUSX(address(usx_proxy)).burn(address(this), TEST_MINT_AMOUNT + 1);
    }
}
