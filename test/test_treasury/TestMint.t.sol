// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "forge-std/Test.sol";
import "solmate/utils/SafeTransferLib.sol";
import "../../src/interfaces/IStableSwap3Pool.sol";
import "../../src/interfaces/IBaseRewardPool.sol";
import "../../src/interfaces/IERC20.sol";
import "../interfaces/IUSXTest.t.sol";
import "../interfaces/ITreasuryTest.t.sol";
import "../common/constants.t.sol";
import "./common/TestHelpers.t.sol";

contract TestMint is Test, MintHelper {
    // Test that each supported token can be minted in a sequential manner, without resetting chain state after each mint
    function test_mint_sequential(uint256 amountMultiplier) public {
        vm.assume(amountMultiplier > 0 && amountMultiplier < 1e11);

        // Allocate funds for test
        deal(TEST_DAI, TEST_USER, DAI_AMOUNT * amountMultiplier);
        deal(TEST_USDC, TEST_USER, USDC_AMOUNT * amountMultiplier);
        deal(TEST_USDT, TEST_USER, USDT_AMOUNT * amountMultiplier);
        deal(TEST_3CRV, TEST_USER, CURVE_AMOUNT * amountMultiplier);

        vm.startPrank(TEST_USER);

        uint256 totalMinted;
        uint256 totalStaked;
        for (uint256 i; i < TEST_COINS.length; i++) {
            // Setup
            uint256 amount = TEST_AMOUNTS[i] * amountMultiplier;

            // Expectations
            (uint256 expectedMintAmount, uint256 lpTokens) = calculateMintAmount(i, amount, TEST_COINS[i]);
            vm.expectEmit(true, true, true, true, address(treasury_proxy));
            emit Mint(TEST_USER, expectedMintAmount);

            // Pre-action assertions
            uint256 preUserBalanceUSX = IUSXTest(address(usx_proxy)).balanceOf(TEST_USER);
            assertEq(
                IUSXTest(address(usx_proxy)).totalSupply(),
                totalMinted,
                "Equivalence violation: pre-action total supply and totalMinted"
            );
            assertEq(preUserBalanceUSX, totalMinted, "Equivalence violation: preUserBalanceUSX and totalMinted");

            // Act
            SafeTransferLib.safeApprove(ERC20(TEST_COINS[i]), address(treasury_proxy), amount);
            ITreasuryTest(address(treasury_proxy)).mint(TEST_COINS[i], amount);

            // Post-action assertions
            uint256 postUserBalanceUSX = IUSXTest(address(usx_proxy)).balanceOf(TEST_USER);
            uint256 mintedUSX = postUserBalanceUSX - preUserBalanceUSX;

            // Ensure the correct amount of USX was minted
            assertEq(mintedUSX, expectedMintAmount, "Equivalence violation: mintedUSX and expectedMintAmount");
            assertEq(
                IUSXTest(address(usx_proxy)).totalSupply(),
                totalMinted + mintedUSX,
                "Equivalence violation: post-action total supply (USX) and totalMinted + mintedUSX"
            );
            assertEq(
                ITreasuryTest(address(treasury_proxy)).totalSupply(),
                totalMinted + mintedUSX,
                "Equivalence violation: post-action total supply (Treasury) and totalMinted + mintedUSX"
            );

            // Ensure the user received USX
            assertEq(
                postUserBalanceUSX,
                totalMinted + mintedUSX,
                "Equivalence violation: postUserBalanceUSX and totalMinted + mintedUSX"
            );

            // Ensure the stable coins were taken from the user
            assertEq(
                IERC20(TEST_COINS[i]).balanceOf(TEST_USER),
                0,
                "Equivalence violation: user test coin balance is not zero"
            );

            // Ensure that the lp tokens and deposit tokens were staked through Convex
            assertEq(
                IBaseRewardPool(BASE_REWARD_POOL).balanceOf(address(treasury_proxy)),
                totalStaked + lpTokens,
                "Equivalence violation: treasury staked cvx3CRV balance and totalStaked + lpTokens"
            );

            totalMinted += mintedUSX;
            totalStaked += lpTokens;
        }
        vm.stopPrank();
    }

    /// @dev Test that each supported token can be minted on its own, resetting chain state after each mint
    function test_mint_independent(uint256 amountMultiplier) public {
        vm.assume(amountMultiplier > 0 && amountMultiplier < 1e11);

        // Allocate funds for test
        deal(TEST_DAI, TEST_USER, DAI_AMOUNT * amountMultiplier);
        deal(TEST_USDC, TEST_USER, USDC_AMOUNT * amountMultiplier);
        deal(TEST_USDT, TEST_USER, USDT_AMOUNT * amountMultiplier);
        deal(TEST_3CRV, TEST_USER, CURVE_AMOUNT * amountMultiplier);

        vm.startPrank(TEST_USER);

        for (uint256 i; i < TEST_COINS.length; i++) {
            // Setup
            uint256 amount = TEST_AMOUNTS[i] * amountMultiplier;

            // Expectations
            (uint256 expectedMintAmount, uint256 lpTokens) = calculateMintAmount(i, amount, TEST_COINS[i]);
            vm.expectEmit(true, true, true, true, address(treasury_proxy));
            emit Mint(TEST_USER, expectedMintAmount);

            // Pre-action assertions
            uint256 preUserBalanceUSX = IUSXTest(address(usx_proxy)).balanceOf(TEST_USER);
            assertEq(
                IUSXTest(address(usx_proxy)).totalSupply(),
                0,
                "Equivalence violation: pre-action total supply is not zero"
            );
            assertEq(preUserBalanceUSX, 0, "Equivalence violation: preUserBalanceUSX is not zero");

            // Act
            uint256 id = vm.snapshot();
            SafeTransferLib.safeApprove(ERC20(TEST_COINS[i]), address(treasury_proxy), amount);
            ITreasuryTest(address(treasury_proxy)).mint(TEST_COINS[i], amount);

            /// Post-action data extraction
            uint256 postUserBalanceUSX = IUSXTest(address(usx_proxy)).balanceOf(TEST_USER);
            uint256 mintedUSX = postUserBalanceUSX - preUserBalanceUSX;

            /// @dev Post-action assertions
            // Ensure the correct amount of USX was minted
            assertEq(mintedUSX, expectedMintAmount, "Equivalence violation: mintedUSX and expectedMintAmount");
            assertEq(
                IUSXTest(address(usx_proxy)).totalSupply(),
                mintedUSX,
                "Equivalence violation: post-action total supply (USX) and mintedUSX"
            );
            assertEq(
                ITreasuryTest(address(treasury_proxy)).totalSupply(),
                mintedUSX,
                "Equivalence violation: post-action total supply (Treasury) and mintedUSX"
            );

            // Ensure the user received USX
            assertEq(postUserBalanceUSX, mintedUSX, "Equivalence violation: postUserBalanceUSX and mintedUSX");

            // Ensure the stable coins were taken from the user
            assertEq(
                IERC20(TEST_COINS[i]).balanceOf(TEST_USER),
                0,
                "Equivalence violation: user test coin balance is not zero"
            );

            // Ensure that the lp tokens and deposit tokens were staked through Convex
            assertEq(
                IBaseRewardPool(BASE_REWARD_POOL).balanceOf(address(treasury_proxy)),
                lpTokens,
                "Equivalence violation: treasury staked cvx3CRV balance and lpTokens"
            );

            /// @dev Revert blockchain state to before USX was minted for next iteration
            vm.revertTo(id);
        }
        vm.stopPrank();
    }

    function testCannot_mint_unsupported_stable() public {
        // Test Variables
        address unsupportedStable = address(0);

        // Expectations
        vm.expectRevert("Unsupported stable.");

        // Act
        ITreasuryTest(address(treasury_proxy)).mint(unsupportedStable, TEST_MINT_AMOUNT);
    }
}
