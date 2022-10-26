// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "../../src/USX.sol";
import "../../src/proxy/ERC1967Proxy.sol";
import "../interfaces/IUSXTest.t.sol";
import "forge-std/Test.sol";

contract TestERC1967Proxy is Test {
    // Test Contracts
    USX public usx_implementation;
    ERC1967Proxy public usx_proxy;

    // Test Constants
    address constant LZ_ENDPOINT = 0xbfD2135BFfbb0B5378b56643c2Df8a87552Bfa23;

    function setUp() public {
        usx_implementation = new USX();
        usx_proxy =
            new ERC1967Proxy(address(usx_implementation), abi.encodeWithSignature("initialize(address)", LZ_ENDPOINT));
    }

    function test_upgradeTo() public {
        // Setup
        bytes32 implentationStorageSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        address implementationAddressV1 =
            address(uint160(uint256(vm.load(address(usx_proxy), implentationStorageSlot))));

        // Pre-action Assertions
        assertEq(implementationAddressV1, address(usx_implementation));

        // Act
        USX usx_implementation_v2 = new USX();
        IUSXTest(address(usx_proxy)).upgradeTo(address(usx_implementation_v2));

        // Post-action assertions
        address implementationAddressV2 =
            address(uint160(uint256(vm.load(address(usx_proxy), implentationStorageSlot))));
        assertEq(implementationAddressV2, address(usx_implementation_v2));
        assertEq(IUSX(address(usx_proxy)).name(), "USX");
    }
}