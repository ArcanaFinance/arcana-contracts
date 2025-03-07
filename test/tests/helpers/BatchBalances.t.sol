// SPDX-License-Identifier: Unlicensed
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../../../src/helpers/BatchBalances.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Mock ERC20 token for testing
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol, uint256 initialSupply) ERC20(name, symbol) {
        _mint(msg.sender, initialSupply);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract BatchBalancesTest is Test {
    BatchBalances public batchBalances;
    MockERC20 public token1;
    MockERC20 public token2;
    address public account1;
    address public account2;
    address public account3;

    function setUp() public {
        // Deploy BatchBalances contract
        batchBalances = new BatchBalances();

        // Deploy mock ERC20 tokens
        token1 = new MockERC20("MockToken1", "MTK1", 1000000 * 10**18);
        token2 = new MockERC20("MockToken2", "MTK2", 500000 * 10**18);

        // Set up test accounts
        account1 = address(0x123);
        account2 = address(0x456);
        account3 = address(0x789);

        // Mint tokens to test accounts
        token1.mint(account1, 100 * 10**18);
        token1.mint(account2, 200 * 10**18);
        token1.mint(account3, 300 * 10**18);

        token2.mint(account1, 400 * 10**18);
        token2.mint(account2, 500 * 10**18);
        token2.mint(account3, 600 * 10**18);
    }

    function test_batchBalances_getBalances_singleToken() public {
        address[] memory accounts = new address[](3);
        accounts[0] = account1;
        accounts[1] = account2;
        accounts[2] = account3;

        uint256[] memory balances = batchBalances.getBalances(address(token1), accounts);

        assertEq(balances.length, 3);
        assertEq(balances[0], 100 * 10**18); // Account1 balance of token1
        assertEq(balances[1], 200 * 10**18); // Account2 balance of token1
        assertEq(balances[2], 300 * 10**18); // Account3 balance of token1
    }

    function test_batchBalances_getBalances_multipleTokens() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(token1);
        tokens[1] = address(token2);

        address[] memory accounts = new address[](3);
        accounts[0] = account1;
        accounts[1] = account2;
        accounts[2] = account3;

        BatchBalances.AccountBalances[] memory balances = batchBalances.getBalances(tokens, accounts);

        assertEq(balances.length, 3);

        // Check balances for account1
        assertEq(balances[0].account, account1);
        assertEq(balances[0].balances.length, 2);
        assertEq(balances[0].balances[0], 100 * 10**18); // Account1 balance of token1
        assertEq(balances[0].balances[1], 400 * 10**18); // Account1 balance of token2

        // Check balances for account2
        assertEq(balances[1].account, account2);
        assertEq(balances[1].balances.length, 2);
        assertEq(balances[1].balances[0], 200 * 10**18); // Account2 balance of token1
        assertEq(balances[1].balances[1], 500 * 10**18); // Account2 balance of token2

        // Check balances for account3
        assertEq(balances[2].account, account3);
        assertEq(balances[2].balances.length, 2);
        assertEq(balances[2].balances[0], 300 * 10**18); // Account3 balance of token1
        assertEq(balances[2].balances[1], 600 * 10**18); // Account3 balance of token2
    }
}
