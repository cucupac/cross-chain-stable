// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "forge-std/Test.sol";
import "solmate/utils/SafeTransferLib.sol";
import "../../src/Treasury.sol";
import "../../src/USX.sol";
import "../../src/proxy/ERC1967Proxy.sol";
import "../../src/interfaces/IStableSwap3Pool.sol";
import "../../src/interfaces/IERC20.sol";
import "../interfaces/IUSXTest.t.sol";
import "../interfaces/ITreasuryTest.t.sol";
import "../mocks/MockStableSwap3Pool.t.sol";
import "../mocks/MockERC20.t.sol";
import "../common/constants.t.sol";

abstract contract SharedSetup is Test {
    // Test Contracts
    Treasury public treasury_implementation;
    USX public usx_implementation;
    ERC1967Proxy public treasury_proxy;
    ERC1967Proxy public usx_proxy;

    // Test Constants
    address constant TEST_STABLE_SWAP_3POOL = 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7; // Ethereum
    address constant TEST_DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F; // Ethereum
    address constant TEST_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // Ethereum
    address constant TEST_USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7; // Ethereum
    address constant TEST_STABLE = 0xaD37Cd49a9dd24BE734212AEFA1b862ead92eEF2;
    address constant TEST_USER = 0x19Bb08638DD185b7455ffD1bB96765108B0aB556;
    address[4] TEST_COINS = [TEST_DAI, TEST_USDC, TEST_USDT, TEST_3CRV];

    uint256 constant DAI_AMOUNT = 1e18;
    uint256 constant USDC_AMOUNT = 1e6;
    uint256 constant USDT_AMOUNT = 1e6;
    uint256 constant CURVE_AMOUNT = 1e18;
    uint256 constant USX_AMOUNT = 1e18;
    uint256[4] TEST_AMOUNTS = [DAI_AMOUNT, USDC_AMOUNT, USDT_AMOUNT, CURVE_AMOUNT];

    // Events
    event Mint(address indexed account, uint256 amount);
    event Redemption(address indexed account, uint256 amount);

    function setUp() public {
        // Deploy USX implementation, and link to proxy
        usx_implementation = new USX();
        usx_proxy =
            new ERC1967Proxy(address(usx_implementation), abi.encodeWithSignature("initialize(address)", LZ_ENDPOINT));

        // Deploy Treasury implementation, and link to proxy
        treasury_implementation = new Treasury();
        treasury_proxy =
        new ERC1967Proxy(address(treasury_implementation), abi.encodeWithSignature("initialize(address,address,address)", TEST_STABLE_SWAP_3POOL, address(usx_proxy), TEST_3CRV));

        // Set treasury admin on token contract
        IUSXTest(address(usx_proxy)).manageTreasuries(address(treasury_proxy), true, true);

        // Set supported stable coins on treasury contract
        ITreasuryTest(address(treasury_proxy)).addSupportedStable(TEST_DAI, 0);
        ITreasuryTest(address(treasury_proxy)).addSupportedStable(TEST_USDC, 1);
        ITreasuryTest(address(treasury_proxy)).addSupportedStable(TEST_USDT, 2);
    }
}

contract TestMint is Test, SharedSetup {
    function calculateMintAmount(uint256 index, uint256 amount, address coin) private returns (uint256) {
        // Take snapshot before calculation
        uint256 id = vm.snapshot();

        // Add liquidity
        uint256 lpTokens;
        if (coin != TEST_3CRV) {
            SafeTransferLib.safeApprove(ERC20(coin), TEST_STABLE_SWAP_3POOL, amount);
            uint256[3] memory amounts;
            amounts[index] = amount;
            uint256 preBalance = IERC20(TEST_3CRV).balanceOf(TEST_USER);
            IStableSwap3Pool(TEST_STABLE_SWAP_3POOL).add_liquidity(amounts, 0);
            uint256 postBalance = IERC20(TEST_3CRV).balanceOf(TEST_USER);
            lpTokens = postBalance - preBalance;
        } else {
            lpTokens = amount;
        }

        // Obtain 3CRV price
        uint256 lpTokenPrice = IStableSwap3Pool(TEST_STABLE_SWAP_3POOL).get_virtual_price();

        // Revert to blockchain state before Curve interaction
        vm.revertTo(id);

        // Return expected mint amount
        return (lpTokens * lpTokenPrice) / 1e18;
    }

    function test_mint_sequential(uint256 amountMultiplier) public {
        vm.assume(amountMultiplier > 0 && amountMultiplier < 1e11);
        /// @dev Allocate funds for test
        deal(TEST_DAI, TEST_USER, DAI_AMOUNT * amountMultiplier);
        deal(TEST_USDC, TEST_USER, USDC_AMOUNT * amountMultiplier);
        deal(TEST_USDT, TEST_USER, USDT_AMOUNT * amountMultiplier);
        deal(TEST_3CRV, TEST_USER, CURVE_AMOUNT * amountMultiplier);

        vm.startPrank(TEST_USER);

        uint256 totalMinted;
        for (uint256 i; i < TEST_COINS.length; i++) {
            /// @dev Setup
            uint256 amount = TEST_AMOUNTS[i] * amountMultiplier;

            // Expectations
            uint256 expectedMintAmount = calculateMintAmount(i, amount, TEST_COINS[i]);
            vm.expectEmit(true, true, true, true, address(treasury_proxy));
            emit Mint(TEST_USER, expectedMintAmount);

            // Pre-action Assertions
            uint256 preUserBalanceUSX = IUSX(address(usx_proxy)).balanceOf(TEST_USER);
            assertEq(IUSX(address(usx_proxy)).totalSupply(), totalMinted);
            assertEq(preUserBalanceUSX, totalMinted);

            // Act
            SafeTransferLib.safeApprove(ERC20(TEST_COINS[i]), address(treasury_proxy), amount);
            ITreasuryTest(address(treasury_proxy)).mint(TEST_COINS[i], amount);

            // Post-action Assertions
            uint256 postUserBalanceUSX = IUSX(address(usx_proxy)).balanceOf(TEST_USER);
            uint256 mintedUSX = postUserBalanceUSX - preUserBalanceUSX;

            // Ensure the correct amount of USX was minted
            assertEq(mintedUSX, expectedMintAmount);
            assertEq(IUSX(address(usx_proxy)).totalSupply(), totalMinted + mintedUSX);

            // Ensure the user received USX
            assertEq(postUserBalanceUSX, totalMinted + mintedUSX);

            // Ensure the stable coins were taken from the user
            assertEq(IERC20(TEST_COINS[i]).balanceOf(TEST_USER), 0);

            totalMinted += mintedUSX;
        }
    }

    function test_mint_independent(uint256 amountMultiplier) public {
        vm.assume(amountMultiplier > 0 && amountMultiplier < 1e11);

        /// @dev Allocate funds for test
        deal(TEST_DAI, TEST_USER, DAI_AMOUNT * amountMultiplier);
        deal(TEST_USDC, TEST_USER, USDC_AMOUNT * amountMultiplier);
        deal(TEST_USDT, TEST_USER, USDT_AMOUNT * amountMultiplier);
        deal(TEST_3CRV, TEST_USER, CURVE_AMOUNT * amountMultiplier);

        vm.startPrank(TEST_USER);

        for (uint256 i; i < TEST_COINS.length; i++) {
            /// @dev Setup
            uint256 amount = TEST_AMOUNTS[i] * amountMultiplier;

            /// @dev Expectations
            uint256 expectedMintAmount = calculateMintAmount(i, amount, TEST_COINS[i]);
            vm.expectEmit(true, true, true, true, address(treasury_proxy));
            emit Mint(TEST_USER, expectedMintAmount);

            /// @dev Pre-action Assertions
            uint256 preUserBalanceUSX = IUSX(address(usx_proxy)).balanceOf(TEST_USER);
            assertEq(IUSX(address(usx_proxy)).totalSupply(), 0);
            assertEq(preUserBalanceUSX, 0);

            /// @dev Act
            uint256 id = vm.snapshot();
            SafeTransferLib.safeApprove(ERC20(TEST_COINS[i]), address(treasury_proxy), amount);
            ITreasuryTest(address(treasury_proxy)).mint(TEST_COINS[i], amount);

            /// @dev Post-action Assertions
            uint256 postUserBalanceUSX = IUSX(address(usx_proxy)).balanceOf(TEST_USER);
            uint256 mintedUSX = postUserBalanceUSX - preUserBalanceUSX;

            // Ensure the correct amount of USX was minted
            assertEq(mintedUSX, expectedMintAmount);
            assertEq(IUSX(address(usx_proxy)).totalSupply(), mintedUSX);

            // Ensure the user received USX
            assertEq(postUserBalanceUSX, mintedUSX);

            // Ensure the stable coins were taken from the user
            assertEq(IERC20(TEST_COINS[i]).balanceOf(TEST_USER), 0);

            /// @dev Revert blockchain state to before USX was minted for next iteration
            vm.revertTo(id);
        }
    }

    function test_mint_negative_price_delta() public {
        vm.startPrank(TEST_USER);

        /// @dev Allocate funds for test
        deal(TEST_DAI, TEST_USER, TEST_DEPOSIT_AMOUNT);

        /// @dev Mock Curve
        bytes memory mockStableSwap3PoolCode = address(new MockStableSwap3Pool()).code;
        vm.etch(address(TEST_STABLE_SWAP_3POOL), mockStableSwap3PoolCode);
        vm.mockCall(
            TEST_STABLE_SWAP_3POOL,
            abi.encodeWithSelector(IStableSwap3Pool(TEST_STABLE_SWAP_3POOL).get_virtual_price.selector),
            abi.encode(TEST_3CRV_VIRTUAL_PRICE)
        );

        /// @dev Mock ERC20, for checking balance with different return values
        bytes memory mockERC20Code = address(new MockERC20()).code;
        vm.etch(address(TEST_DAI), mockERC20Code);

        /// @dev Expectations
        uint256 preUserBalanceUSX = IUSX(address(usx_proxy)).balanceOf(TEST_USER);
        assertEq(IUSX(address(usx_proxy)).totalSupply(), 0);
        assertEq(preUserBalanceUSX, 0);

        /// @dev Act 1
        SafeTransferLib.safeApprove(ERC20(TEST_DAI), address(treasury_proxy), TEST_DEPOSIT_AMOUNT);
        ITreasuryTest(address(treasury_proxy)).mint(TEST_DAI, TEST_DEPOSIT_AMOUNT);

        /// @dev Post-action data extraction 1
        uint256 postUserBalanceUSX1 = IUSX(address(usx_proxy)).balanceOf(TEST_USER);
        uint256 mintedUSX1 = postUserBalanceUSX1 - preUserBalanceUSX;

        /// @dev Mock Curve
        vm.mockCall(
            TEST_STABLE_SWAP_3POOL,
            abi.encodeWithSelector(IStableSwap3Pool(TEST_STABLE_SWAP_3POOL).get_virtual_price.selector),
            abi.encode(TEST_3CRV_VIRTUAL_PRICE - 1e6)
        );

        /// @dev Act 2
        SafeTransferLib.safeApprove(ERC20(TEST_DAI), address(treasury_proxy), TEST_DEPOSIT_AMOUNT);
        ITreasuryTest(address(treasury_proxy)).mint(TEST_DAI, TEST_DEPOSIT_AMOUNT);

        /// @dev Post-action Assertions
        uint256 postUserBalanceUSX2 = IUSX(address(usx_proxy)).balanceOf(TEST_USER);
        uint256 mintedUSX2 = postUserBalanceUSX2 - postUserBalanceUSX1;

        // Ensure the same amount was minted both times (used same conversion factor)
        assertEq(mintedUSX2, mintedUSX1);
    }

    function test_fail_treasury_mint_unsupported_stable() public {
        // Test Variables
        address unsupportedStable = address(0);

        // Expectations
        vm.expectRevert("Unsupported stable.");

        // Act
        ITreasuryTest(address(treasury_proxy)).mint(unsupportedStable, TEST_MINT_AMOUNT);
    }
}

contract TestRedeem is Test, SharedSetup {
    function calculateRedeemAmount(uint256 index, uint256 lpTokens, address coin) private returns (uint256) {
        // Take snapshot before calculation
        uint256 id = vm.snapshot();

        uint256 redeemAmount;
        if (coin != TEST_3CRV) {
            // Obtain contract's withdraw token balance before adding removing liquidity
            uint256 preBalance = IERC20(coin).balanceOf(address(treasury_proxy));

            // Remove liquidity from Curve

            vm.prank(address(treasury_proxy));
            IStableSwap3Pool(TEST_STABLE_SWAP_3POOL).remove_liquidity_one_coin(lpTokens, int128(uint128(index)), 0);

            // Calculate the amount of stablecoin received from removing liquidity
            redeemAmount = IERC20(coin).balanceOf(address(treasury_proxy)) - preBalance;
        } else {
            redeemAmount = lpTokens;
        }

        // Revert to blockchain state before Curve interaction
        vm.revertTo(id);

        return redeemAmount;
    }

    function calculateCurveTokenAmount(uint256 usxAmount) private returns (uint256) {
        uint256 lpTokenPrice = IStableSwap3Pool(TEST_STABLE_SWAP_3POOL).get_virtual_price();
        uint256 conversionFactor = (1e18 * 1e18 / lpTokenPrice);
        return (usxAmount * conversionFactor) / 1e18;
    }

    function test_redeem_sequential(uint256 amountMultiplier) public {
        vm.assume(amountMultiplier > 0 && amountMultiplier < 1e7);

        /// @dev Allocate funds for test
        // Give user USX
        vm.prank(address(treasury_proxy));
        uint256 usxAmount = USX_AMOUNT * TEST_COINS.length * amountMultiplier;
        IUSX(address(usx_proxy)).mint(TEST_USER, usxAmount);

        // Give Treasury 3CRV
        uint256 curveAmount = calculateCurveTokenAmount(usxAmount);
        deal(TEST_3CRV, address(treasury_proxy), curveAmount);

        uint256 usxSupply = IUSX(address(usx_proxy)).totalSupply();
        for (uint256 i; i < TEST_COINS.length; i++) {
            /// @dev Expectations
            uint256 burnAmountUSX = usxAmount / TEST_COINS.length;
            uint256 curveAmountUsed = calculateCurveTokenAmount(burnAmountUSX);
            uint256 expectedRedeemAmount = calculateRedeemAmount(i, curveAmountUsed, TEST_COINS[i]);

            vm.expectEmit(true, true, true, true, address(treasury_proxy));
            emit Redemption(TEST_USER, burnAmountUSX);

            /// @dev Setup
            vm.startPrank(TEST_USER);

            /// @dev Pre-action Assertions
            uint256 preUserBalanceUSX = IUSX(address(usx_proxy)).balanceOf(TEST_USER);
            uint256 preTreasuryBalance = IERC20(address(TEST_3CRV)).balanceOf(address(treasury_proxy));
            assertEq(IUSX(address(usx_proxy)).totalSupply(), usxSupply);
            assertEq(preUserBalanceUSX, usxSupply);

            /// @dev Act
            ITreasuryTest(address(treasury_proxy)).redeem(TEST_COINS[i], burnAmountUSX);

            /// @dev Post-action Assertions
            // Ensure USX was burned
            assertEq(IUSX(address(usx_proxy)).totalSupply(), usxSupply - burnAmountUSX);
            assertEq(IUSX(address(usx_proxy)).balanceOf(TEST_USER), usxSupply - burnAmountUSX);

            // Ensure the treasury 3CRV balance properly decreased
            uint256 postCurveBalance = IERC20(address(TEST_3CRV)).balanceOf(address(treasury_proxy));

            assertEq(postCurveBalance, preTreasuryBalance - curveAmountUsed);

            // Ensure the user received the desired output token
            uint256 userERC20Balance = IERC20(TEST_COINS[i]).balanceOf(TEST_USER);
            assertEq(userERC20Balance, expectedRedeemAmount);

            usxSupply -= burnAmountUSX;
            vm.stopPrank();
        }
    }

    function test_redeem_independent(uint256 amountMultiplier) public {
        vm.assume(amountMultiplier > 0 && amountMultiplier < 1e7);

        /// @dev Allocate funds for test
        // Give user USX
        uint256 usxAmount = USX_AMOUNT * amountMultiplier;
        vm.prank(address(treasury_proxy));
        IUSX(address(usx_proxy)).mint(TEST_USER, usxAmount);

        // Give Treasury 3CRV
        uint256 curveAmount = calculateCurveTokenAmount(usxAmount);
        deal(TEST_3CRV, address(treasury_proxy), curveAmount);

        for (uint256 i; i < TEST_COINS.length; i++) {
            /// @dev Expectations
            uint256 curveAmountUsed = calculateCurveTokenAmount(usxAmount);
            uint256 expectedRedeemAmount = calculateRedeemAmount(i, curveAmountUsed, TEST_COINS[i]);

            vm.expectEmit(true, true, true, true, address(treasury_proxy));
            emit Redemption(TEST_USER, usxAmount);

            /// @dev Setup
            vm.startPrank(TEST_USER);

            /// @dev Pre-action Assertions
            uint256 preUserBalanceUSX = IUSX(address(usx_proxy)).balanceOf(TEST_USER);
            uint256 preTreasuryBalance = IERC20(address(TEST_3CRV)).balanceOf(address(treasury_proxy));
            assertEq(IUSX(address(usx_proxy)).totalSupply(), usxAmount);
            assertEq(preUserBalanceUSX, usxAmount);

            /// @dev Act
            uint256 id = vm.snapshot();
            ITreasuryTest(address(treasury_proxy)).redeem(TEST_COINS[i], usxAmount);

            /// @dev Post-action Assertions
            // Ensure USX was burned
            assertEq(IUSX(address(usx_proxy)).totalSupply(), 0);
            assertEq(IUSX(address(usx_proxy)).balanceOf(TEST_USER), 0);

            // Ensure the treasury 3CRV balance properly decreased
            uint256 postCurveBalance = IERC20(address(TEST_3CRV)).balanceOf(address(treasury_proxy));

            assertEq(postCurveBalance, preTreasuryBalance - curveAmountUsed);

            // Ensure the user received the desired output token
            uint256 userERC20Balance = IERC20(TEST_COINS[i]).balanceOf(TEST_USER);
            assertEq(userERC20Balance, expectedRedeemAmount);

            /// @dev Revert blockchain state to before USX was minted for next iteration
            vm.revertTo(id);
            vm.stopPrank();
        }
    }

    function test_redeem_negative_price_delta() public {
        /// @dev Allocate funds for test
        // Give user USX
        vm.prank(address(treasury_proxy));
        IUSX(address(usx_proxy)).mint(TEST_USER, USX_AMOUNT);

        // Give Treasury 3CRV
        uint256 curveAmount = calculateCurveTokenAmount(USX_AMOUNT);
        deal(TEST_3CRV, address(treasury_proxy), curveAmount);

        vm.startPrank(TEST_USER);

        /// @dev Mock Curve 1
        bytes memory mockStableSwap3PoolCode = address(new MockStableSwap3Pool()).code;
        vm.etch(address(TEST_STABLE_SWAP_3POOL), mockStableSwap3PoolCode);
        vm.mockCall(
            TEST_STABLE_SWAP_3POOL,
            abi.encodeWithSelector(IStableSwap3Pool(TEST_STABLE_SWAP_3POOL).get_virtual_price.selector),
            abi.encode(TEST_3CRV_VIRTUAL_PRICE)
        );

        /// @dev Pre-action assertions
        uint256 initialUserBalance1 = IERC20(TEST_DAI).balanceOf(TEST_USER);
        assertEq(initialUserBalance1, 0);

        /// @dev Act 1
        ITreasuryTest(address(treasury_proxy)).redeem(TEST_DAI, (USX_AMOUNT / 2));

        /// @dev Post-action 1 data extraction
        uint256 postUserBalance1 = IERC20(TEST_DAI).balanceOf(TEST_USER);
        uint256 redeemedAmount1 = postUserBalance1 - initialUserBalance1;

        /// @dev Mock Curve 2
        vm.mockCall(
            TEST_STABLE_SWAP_3POOL,
            abi.encodeWithSelector(IStableSwap3Pool(TEST_STABLE_SWAP_3POOL).get_virtual_price.selector),
            abi.encode(TEST_3CRV_VIRTUAL_PRICE - 1e6)
        );

        /// @dev Act 2
        ITreasuryTest(address(treasury_proxy)).redeem(TEST_DAI, (USX_AMOUNT / 2));

        /// @dev Post-action 2 data extraction
        uint256 postUserBalance2 = IERC20(TEST_DAI).balanceOf(TEST_USER);
        uint256 redeemedAmount2 = postUserBalance2 - postUserBalance1;

        // Ensure the same amount was redeemed both times (used same conversion factor)
        assertEq(redeemedAmount2, redeemedAmount1);
    }

    function test_fail_treasury_redeem_unsupported_stable() public {
        // Test Variables
        address unsupportedStable = address(0);

        // Expectations
        vm.expectRevert("Unsupported stable.");

        // Act
        ITreasuryTest(address(treasury_proxy)).redeem(unsupportedStable, TEST_MINT_AMOUNT);
    }

    function testFail_treasury_redeem_amount(uint256 burnAmount) public {
        vm.assume(burnAmount > TEST_MINT_AMOUNT);

        /// @dev Allocate funds for test
        // Give this contract USX
        vm.prank(address(treasury_proxy));
        IUSX(address(usx_proxy)).mint(address(this), TEST_MINT_AMOUNT);

        // Give Treasury 3CRV
        uint256 curveAmount = calculateCurveTokenAmount(TEST_MINT_AMOUNT);
        deal(TEST_3CRV, address(treasury_proxy), curveAmount);

        /// @dev Expectations
        vm.expectEmit(true, true, true, true, address(treasury_proxy));
        emit Redemption(address(this), burnAmount);

        /// @dev Pre-action Assertions
        assertEq(IUSX(address(usx_proxy)).totalSupply(), TEST_MINT_AMOUNT);
        assertEq(IUSX(address(usx_proxy)).balanceOf(address(this)), TEST_MINT_AMOUNT);

        // Act
        ITreasuryTest(address(treasury_proxy)).redeem(TEST_DAI, burnAmount);
    }
}

contract TestAdmin is Test, SharedSetup {
    function test_addSupportedStable() public {
        // Test Variables
        int128 testCurveIndex = 0;

        // Pre-action Assertions
        (bool supported, int128 returnedTestCurveIndex) =
            ITreasuryTest(address(treasury_proxy)).supportedStables(TEST_STABLE);
        assertEq(supported, false);

        // Act
        ITreasuryTest(address(treasury_proxy)).addSupportedStable(TEST_STABLE, testCurveIndex);

        // Post-action Assertions
        (supported, returnedTestCurveIndex) = ITreasuryTest(address(treasury_proxy)).supportedStables(TEST_STABLE);
        assertEq(supported, true);
        assertEq(returnedTestCurveIndex, testCurveIndex);
    }

    function test_fail_addSupportedStable_sender() public {
        // Test Variables
        int128 testCurveIndex = 0;

        // Expectations
        vm.expectRevert("Ownable: caller is not the owner");

        // Act
        vm.prank(TEST_ADDRESS);
        ITreasuryTest(address(treasury_proxy)).addSupportedStable(TEST_STABLE, testCurveIndex);
    }

    function test_removeSupportedStable() public {
        // Setup
        ITreasuryTest(address(treasury_proxy)).addSupportedStable(TEST_STABLE, 0);

        // Pre-action Assertions
        (bool supported, int128 returnedTestCurveIndex) =
            ITreasuryTest(address(treasury_proxy)).supportedStables(TEST_STABLE);
        assertEq(supported, true);
        assertEq(returnedTestCurveIndex, 0);

        // Act
        ITreasuryTest(address(treasury_proxy)).removeSupportedStable(TEST_STABLE);

        // Post-action Assertions
        (supported, returnedTestCurveIndex) = ITreasuryTest(address(treasury_proxy)).supportedStables(TEST_STABLE);
        assertEq(supported, false);
    }

    function test_fail_removeSupportedStable_sender() public {
        // Expectations
        vm.expectRevert("Ownable: caller is not the owner");

        // Act
        vm.prank(TEST_ADDRESS);
        ITreasuryTest(address(treasury_proxy)).removeSupportedStable(TEST_STABLE);
    }
}
