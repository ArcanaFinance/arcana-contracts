// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/* solhint-disable private-vars-leading-underscore  */
/* solhint-disable func-name-mixedcase  */
/* solhint-disable var-name-mixedcase  */

// oz imports
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// contracts
import {arcUSDMinter} from "../src/arcUSDMinter.sol";
import {arcUSDPointsBoostVault} from "../src/arcUSDPointsBoostingVault.sol";
import {MockOracle} from "./mock/MockOracle.sol";
import {MockToken} from "./mock/MockToken.sol";
import {LZEndpointMock} from "./mock/LZEndpointMock.sol";
import {arcUSD} from "../src/arcUSD.sol";
import {arcUSDTaxManager} from "../src/arcUSDTaxManager.sol";
import {arcUSDFeeCollector} from "../src/arcUSDFeeCollector.sol";
import {CustodianManager} from "../src/CustodianManager.sol";

// interfaces
import {IarcUSD} from "../src/interfaces/IarcUSD.sol";
import {IarcUSDDefinitions} from "../src/interfaces/IarcUSDDefinitions.sol";

// helpers
import {stdStorage, StdStorage, Test} from "forge-std/Test.sol";
import {SigUtils} from "./utils/SigUtils.sol";
import {Vm} from "forge-std/Vm.sol";
import {Utils} from "./utils/Utils.sol";

contract BaseSetup is Test, IarcUSDDefinitions {
    Utils internal utils;
    arcUSD internal arcUSDToken;
    arcUSDTaxManager internal taxManager;
    arcUSDFeeCollector internal feeCollector;
    arcUSDPointsBoostVault internal arcUSDVault;
    CustodianManager internal custodian;
    LZEndpointMock public layerZeroEndpoint;
    MockToken internal USTB;
    MockOracle internal USTBOracle;
    MockToken internal cbETHToken;
    MockToken internal rETHToken;
    MockToken internal USDCToken;
    MockToken internal USDTToken;
    MockToken internal token;
    arcUSDMinter internal arcMinter;
    SigUtils internal sigUtils;
    SigUtils internal sigUtilsarcUSD;

    uint256 internal constant ownerPrivateKey = 0xA11CE;
    uint256 internal constant newOwnerPrivateKey = 0xA14CE;
    uint256 internal constant minterPrivateKey = 0xB44DE;
    uint256 internal constant redeemerPrivateKey = 0xB45DE;
    uint256 internal constant maker1PrivateKey = 0xA13CE;
    uint256 internal constant maker2PrivateKey = 0xA14CE;
    uint256 internal constant adminPrivateKey = 0x1DE;
    uint256 internal constant whitelisterPrivateKey = 0x1DEA;
    uint256 internal constant gatekeeperPrivateKey = 0x1DEA1;
    uint256 internal constant bobPrivateKey = 0x1DEA2;
    uint256 internal constant alicePrivateKey = 0x1DBA2;
    uint256 internal constant randomerPrivateKey = 0x1DECC;
    uint256 internal constant rebaseManagerPrivateKey = 0x1DB11;
    uint256 internal constant gelatoPrivateKey = 0x1AB01;
    uint256 internal constant mainCustodianPrivateKey = 0x1AB02;

    address internal owner;
    address internal newOwner;
    address internal minter;
    address internal redeemer;
    address internal maker1;
    address internal maker2;
    address internal admin;
    address internal whitelister;
    address internal gatekeeper;
    address internal bob;
    address internal alice;
    address internal gelato;
    address internal mainCustodian;
    address internal randomer;
    address internal rebaseManager;

    address internal NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // Roles references
    bytes32 internal minterRole = keccak256("MINTER_ROLE");
    bytes32 internal gatekeeperRole = keccak256("GATEKEEPER_ROLE");
    bytes32 internal adminRole = 0x00;
    bytes32 internal redeemerRole = keccak256("REDEEMER_ROLE");

    // arcUSD error encodings
    bytes internal OnlyMinterErr = abi.encodeWithSelector(IarcUSDDefinitions.OnlyMinter.selector);
    bytes internal ZeroAddressExceptionErr = abi.encodeWithSelector(IarcUSDDefinitions.ZeroAddressException.selector);
    bytes internal CantRenounceOwnershipErr = abi.encodeWithSelector(IarcUSDDefinitions.CantRenounceOwnership.selector);
    bytes internal LimitExceeded = abi.encodeWithSelector(IarcUSDDefinitions.SupplyLimitExceeded.selector);

    uint256 internal _slippageRange = 50000000000000000;
    uint256 internal _amountToDeposit = 50 * 10 ** 18;
    uint256 internal _stETHToWithdraw = 30 * 10 ** 18;
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
        vm.label(admin, "admin");
        vm.label(whitelister, "whitelister");
        vm.label(gatekeeper, "gatekeeper");
        vm.label(bob, "bob");
        vm.label(alice, "alice");
        vm.label(randomer, "randomer");

        address[] memory distributors = new address[](2);
        distributors[0] = address(2);
        distributors[1] = address(3);

        uint256[] memory ratios = new uint256[](2);
        ratios[0] = 1;
        ratios[1] = 1;

        // ~ Deploy Contracts ~

        layerZeroEndpoint = new LZEndpointMock(uint16(block.chainid));

        arcUSDToken = new arcUSD(1, address(layerZeroEndpoint));
        ERC1967Proxy arcUSDTokenProxy = new ERC1967Proxy(
            address(arcUSDToken), abi.encodeWithSelector(arcUSD.initialize.selector, address(this), rebaseManager)
        );
        arcUSDToken = arcUSD(address(arcUSDTokenProxy));

        feeCollector = new arcUSDFeeCollector(owner, address(arcUSDToken), distributors, ratios);

        taxManager = new arcUSDTaxManager(owner, address(arcUSDToken), address(feeCollector));

        arcMinter = new arcUSDMinter(address(arcUSDToken));
        ERC1967Proxy arcanaMintingProxy = new ERC1967Proxy(
            address(arcMinter),
            abi.encodeWithSelector(arcUSDMinter.initialize.selector,
                owner,
                admin,
                whitelister,
                5 days
            )
        );
        arcMinter = arcUSDMinter(payable(address(arcanaMintingProxy)));

        custodian = new CustodianManager(address(arcMinter));
        ERC1967Proxy custodianProxy = new ERC1967Proxy(
            address(custodian),
            abi.encodeWithSelector(CustodianManager.initialize.selector, owner, mainCustodian)
        );
        custodian = CustodianManager(address(custodianProxy));

        arcUSDVault = new arcUSDPointsBoostVault(owner, address(arcUSDToken));

        // ~ Config ~

        vm.startPrank(owner);

        arcMinter.modifyWhitelist(bob, true);
        arcMinter.modifyWhitelist(alice, true);

        // set custodian on minter
        arcMinter.updateCustodian(address(custodian));

        // Add self as approved custodian
        arcMinter.addSupportedAsset(address(USTB), address(USTBOracle));
        arcMinter.addSupportedAsset(address(USDCToken), address(USTBOracle));
        arcMinter.addSupportedAsset(address(USDTToken), address(USTBOracle));

        // Mint stEth to the actor in order to test
        USTB.mint(_amountToDeposit, bob);
        vm.stopPrank();

        arcUSDToken.setMinter(address(arcMinter));

        arcUSDToken.setSupplyLimit(type(uint256).max);

        arcUSDToken.setTaxManager(address(taxManager));
    }

    function _createAddresses() internal {
        owner = vm.addr(ownerPrivateKey);
        newOwner = vm.addr(newOwnerPrivateKey);
        minter = vm.addr(minterPrivateKey);
        redeemer = vm.addr(redeemerPrivateKey);
        maker1 = vm.addr(maker1PrivateKey);
        maker2 = vm.addr(maker2PrivateKey);
        admin = vm.addr(adminPrivateKey);
        whitelister = vm.addr(whitelisterPrivateKey);
        gatekeeper = vm.addr(gatekeeperPrivateKey);
        bob = vm.addr(bobPrivateKey);
        alice = vm.addr(alicePrivateKey);
        randomer = vm.addr(randomerPrivateKey);
        rebaseManager = vm.addr(rebaseManagerPrivateKey);
        gelato = vm.addr(gelatoPrivateKey);
        mainCustodian = vm.addr(mainCustodianPrivateKey);
    }

    function _changeOraclePrice(address oracle, uint256 price) internal {
        vm.store(oracle, 0, bytes32(price));
    }
}
