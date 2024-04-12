// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/* solhint-disable private-vars-leading-underscore  */
/* solhint-disable func-name-mixedcase  */
/* solhint-disable var-name-mixedcase  */

// oz imports
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// contracts
import {DJUSDMinting} from "../src/DJUSDMinting.sol";
import {DJUSDPointsBoostVault} from "../src/DJUSDPointsBoostingVault.sol";
import {MockOracle} from "../src/mock/MockOracle.sol";
import {MockToken} from "../src/mock/MockToken.sol";
import {DJUSD} from "../src/DJUSD.sol";
import {DJUSDTaxManager} from "../src/DJUSDTaxManager.sol";
import {DJUSDFeeCollector} from "../src/DJUSDFeeCollector.sol";

// interfaces
import {IDJUSD} from "../src/interfaces/IDJUSD.sol";
import {IDJUSDDefinitions} from "../src/interfaces/IDJUSDDefinitions.sol";

// helpers
import {stdStorage, StdStorage, Test} from "forge-std/Test.sol";
import {SigUtils} from "./utils/SigUtils.sol";
import {Vm} from "forge-std/Vm.sol";
import {Utils} from "./utils/Utils.sol";

contract BaseSetup is Test, IDJUSDDefinitions {
    Utils internal utils;
    DJUSD internal djUsdToken;
    DJUSDTaxManager internal taxManager;
    DJUSDFeeCollector internal feeCollector;
    DJUSDPointsBoostVault internal djUsdVault;
    MockToken internal USTB;
    MockOracle internal USTBOracle;
    MockToken internal cbETHToken;
    MockToken internal rETHToken;
    MockToken internal USDCToken;
    MockToken internal USDTToken;
    MockToken internal token;
    DJUSDMinting internal djUsdMintingContract;
    SigUtils internal sigUtils;
    SigUtils internal sigUtilsDJUSD;

    uint256 internal constant ownerPrivateKey = 0xA11CE;
    uint256 internal constant newOwnerPrivateKey = 0xA14CE;
    uint256 internal constant minterPrivateKey = 0xB44DE;
    uint256 internal constant redeemerPrivateKey = 0xB45DE;
    uint256 internal constant maker1PrivateKey = 0xA13CE;
    uint256 internal constant maker2PrivateKey = 0xA14CE;
    uint256 internal constant trader1PrivateKey = 0x1DE;
    uint256 internal constant trader2PrivateKey = 0x1DEA;
    uint256 internal constant gatekeeperPrivateKey = 0x1DEA1;
    uint256 internal constant bobPrivateKey = 0x1DEA2;
    uint256 internal constant alicePrivateKey = 0x1DBA2;
    uint256 internal constant custodian1PrivateKey = 0x1DCDE;
    uint256 internal constant randomerPrivateKey = 0x1DECC;
    uint256 internal constant rebaseManagerPrivateKey = 0x1DB11;
    uint256 internal constant layerZeroEndpointPrivateKey = 0x1DB12;

    address internal owner;
    address internal newOwner;
    address internal minter;
    address internal redeemer;
    address internal maker1;
    address internal maker2;
    address internal trader1;
    address internal trader2;
    address internal gatekeeper;
    address internal bob;
    address internal alice;
    address internal custodian1;
    address internal randomer;
    address internal rebaseManager;
    address internal layerZeroEndpoint;

    address internal NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // Roles references
    bytes32 internal minterRole = keccak256("MINTER_ROLE");
    bytes32 internal gatekeeperRole = keccak256("GATEKEEPER_ROLE");
    bytes32 internal adminRole = 0x00;
    bytes32 internal redeemerRole = keccak256("REDEEMER_ROLE");

    // DJUSD error encodings
    bytes internal OnlyMinterErr = abi.encodeWithSelector(IDJUSDDefinitions.OnlyMinter.selector);
    bytes internal ZeroAddressExceptionErr = abi.encodeWithSelector(IDJUSDDefinitions.ZeroAddressException.selector);
    bytes internal CantRenounceOwnershipErr = abi.encodeWithSelector(IDJUSDDefinitions.CantRenounceOwnership.selector);
    bytes internal LimitExceeded = abi.encodeWithSelector(IDJUSDDefinitions.SupplyLimitExceeded.selector);

    uint256 internal _slippageRange = 50000000000000000;
    uint256 internal _amountToDeposit = 50 * 10 ** 18;
    uint256 internal _stETHToWithdraw = 30 * 10 ** 18;
    uint256 internal _djUsdToMint = 8.75 * 10 ** 23;
    uint256 internal _maxMintPerBlock = 10e23;
    uint256 internal _maxRedeemPerBlock = _maxMintPerBlock;

    // Declared at contract level to avoid stack too deep
    SigUtils.Permit public permit;

    /// @notice packs r, s, v into signature bytes
    function _packRsv(bytes32 r, bytes32 s, uint8 v) internal pure returns (bytes memory) {
        bytes memory sig = new bytes(65);
        assembly {
            mstore(add(sig, 32), r)
            mstore(add(sig, 64), s)
            mstore8(add(sig, 96), v)
        }
        return sig;
    }

    function setUp() public virtual {
        utils = new Utils();

        USTB = new MockToken("US T-Bill", "USTB", 18, msg.sender);
        USTBOracle = new MockOracle(address(USTB), 1e18, 18);
        USDCToken = new MockToken("United States Dollar Coin", "USDC", 6, msg.sender);
        USDTToken = new MockToken("United States Dollar Token", "USDT", 18, msg.sender);

        _createAddresses();

        vm.label(minter, "minter");
        vm.label(redeemer, "redeemer");
        vm.label(owner, "owner");
        vm.label(maker1, "maker1");
        vm.label(maker2, "maker2");
        vm.label(trader1, "trader1");
        vm.label(trader2, "trader2");
        vm.label(gatekeeper, "gatekeeper");
        vm.label(bob, "bob");
        vm.label(alice, "alice");
        vm.label(custodian1, "custodian1");
        vm.label(randomer, "randomer");

        address[] memory distributors = new address[](2);
        distributors[0] = address(2);
        distributors[1] = address(3);

        uint256[] memory ratios = new uint256[](2);
        ratios[0] = 1;
        ratios[1] = 1;

        // ~ Deploy Contracts ~

        djUsdToken = new DJUSD(1, layerZeroEndpoint);
        ERC1967Proxy djUsdTokenProxy = new ERC1967Proxy(
            address(djUsdToken), abi.encodeWithSelector(DJUSD.initialize.selector, address(this), rebaseManager)
        );
        djUsdToken = DJUSD(address(djUsdTokenProxy));

        feeCollector = new DJUSDFeeCollector(owner, address(djUsdToken), distributors, ratios);

        taxManager = new DJUSDTaxManager(owner, address(djUsdToken), address(feeCollector));

        djUsdMintingContract = new DJUSDMinting(IDJUSD(address(djUsdToken)));
        ERC1967Proxy djinnMintingProxy = new ERC1967Proxy(
            address(djUsdMintingContract),
            abi.encodeWithSelector(DJUSDMinting.initialize.selector, owner, 5 days, custodian1)
        );
        djUsdMintingContract = DJUSDMinting(payable(address(djinnMintingProxy)));

        djUsdVault = new DJUSDPointsBoostVault(address(djUsdToken));

        // ~ Config ~

        vm.startPrank(owner);

        // Add self as approved custodian
        djUsdMintingContract.addSupportedAsset(address(USTB), address(USTBOracle));
        djUsdMintingContract.addSupportedAsset(address(USDCToken), address(USTBOracle));
        djUsdMintingContract.addSupportedAsset(address(USDTToken), address(USTBOracle));

        // Mint stEth to the actor in order to test
        USTB.mint(_amountToDeposit, bob);
        vm.stopPrank();

        djUsdToken.setMinter(address(djUsdMintingContract));

        djUsdToken.setSupplyLimit(type(uint256).max);

        djUsdToken.setTaxManager(address(taxManager));
    }

    function _createAddresses() internal {
        owner = vm.addr(ownerPrivateKey);
        newOwner = vm.addr(newOwnerPrivateKey);
        minter = vm.addr(minterPrivateKey);
        redeemer = vm.addr(redeemerPrivateKey);
        maker1 = vm.addr(maker1PrivateKey);
        maker2 = vm.addr(maker2PrivateKey);
        trader1 = vm.addr(trader1PrivateKey);
        trader2 = vm.addr(trader2PrivateKey);
        gatekeeper = vm.addr(gatekeeperPrivateKey);
        bob = vm.addr(bobPrivateKey);
        alice = vm.addr(alicePrivateKey);
        custodian1 = vm.addr(custodian1PrivateKey);
        randomer = vm.addr(randomerPrivateKey);
        rebaseManager = vm.addr(rebaseManagerPrivateKey);
        layerZeroEndpoint = vm.addr(layerZeroEndpointPrivateKey);
    }
}
