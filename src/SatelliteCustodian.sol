// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

// oz imports
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

// lz imports
import {ICommonOFT} from "@layerzerolabs/contracts/token/oft/v2/interfaces/ICommonOFT.sol";
import {IOFTV2} from "@layerzerolabs/contracts/token/oft/v2/interfaces/IOFTV2.sol";

// local imports
import {DJUSDMinter} from "./DJUSDMinter.sol";

/**
 * @title SateilliteCustodian
 * @notice Custodian contract for DJUSDMinting on Satellite chains.
 * @dev TODO
 */
contract SatelliteCustodian is OwnableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    
    DJUSDMinter immutable public djUsdMinter;

    uint16 immutable public dstChainId;

    address public gelato;

    address public dstCustodian;

    event FundsBridged(address asset, uint256 amount);
    event FundsWithdrawn(address asset, uint256 amount);

    error InsufficientBalance(uint256 expected, uint256 actual);
    error NotAuthorized(address caller);
    error UnsupportedAsset(address asset);

    modifier onlyGelato() {
        if (msg.sender != gelato && msg.sender != owner()) {
            revert NotAuthorized(msg.sender);
        }
        _;
    }

    constructor(address _djUsdMinter, uint16 _dstChainId) {
        djUsdMinter = DJUSDMinter(_djUsdMinter);
        dstChainId = _dstChainId;
    }

    function initialize(address initialOwner, address initialGelato, address initialDstCustodian) public initializer {
        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();

        gelato = initialGelato;
        dstCustodian = initialDstCustodian;
    }

    function bridgeFunds(address asset, address refundAddress, address zroPaymentAddress, bytes memory adapterParams) external payable onlyGelato {
        uint256 bal = IERC20(asset).balanceOf(address(this));

        ICommonOFT.LzCallParams memory params = ICommonOFT.LzCallParams({
            refundAddress: payable(refundAddress),
            zroPaymentAddress: zroPaymentAddress,
            adapterParams: adapterParams
        });

        IOFTV2(asset).sendFrom{value: msg.value}(address(this), dstChainId, keccak256(abi.encodePacked(dstCustodian)), bal, params);
        emit FundsBridged(asset, bal);
    }

    function withdrawFunds(address asset, uint256 amount) external onlyOwner {
        uint256 bal = IERC20(asset).balanceOf(address(this));
        if (amount > bal) revert InsufficientBalance(amount, bal);

        IERC20(asset).safeTransfer(msg.sender, amount);
        emit FundsWithdrawn(asset, amount);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
