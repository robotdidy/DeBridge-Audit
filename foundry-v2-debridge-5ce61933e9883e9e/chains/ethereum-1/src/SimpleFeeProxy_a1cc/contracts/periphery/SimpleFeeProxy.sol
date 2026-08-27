// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.7;

import "../../@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "../../@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "../../@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "../../@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "../../@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "../transfers/DeBridgeGate.sol";

/// @dev Helper to withdraw fees from DeBridgeGate.
contract SimpleFeeProxy is Initializable, AccessControlUpgradeable, PausableUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    /* ========== STATE VARIABLES ========== */

    /// @dev Role for fee withdrawal
    bytes32 public constant FEE_COLLECTOR_ROLE = keccak256("FEE_COLLECTOR_ROLE");

    /// @dev DeBridgeGate address
    DeBridgeGate public debridgeGate;
    /// @dev Treasury address
    address private treasury; // deprecated since v4.1.0

    /* ========== ERRORS ========== */

    error AdminBadRole();
    error FeeCollectorBadRole();
    error EthTransferFailed();

    /* ========== MODIFIERS ========== */

    modifier onlyAdmin() {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert AdminBadRole();
        _;
    }

    modifier onlyFeeCollector() {
        if (!hasRole(FEE_COLLECTOR_ROLE, msg.sender)) revert FeeCollectorBadRole();
        _;
    }

    /* ========== CONSTRUCTOR  ========== */

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {
    }

    function initialize(DeBridgeGate _debridgeGate) public initializer {
        debridgeGate = _debridgeGate;
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /* ========== FUNCTIONS  ========== */

    function pause() external onlyAdmin {
        _pause();
    }

    function unpause() external onlyAdmin {
        _unpause();
    }

    function setDebridgeGate(DeBridgeGate _debridgeGate) external onlyAdmin {
        debridgeGate = _debridgeGate;
    }

    /// @dev Transfer collected fees for specified tokens to the fee collector (caller).
    /// @param _tokens Array of token addresses to withdraw fees for.
    /// If the address is zero, it will withdraw fees for the native token.
    function withdrawFees(address[] calldata _tokens)
        external
        onlyFeeCollector
        whenNotPaused
    {
        address tokenAddress;
        for (uint256 i; i < _tokens.length; ++i) {
            tokenAddress = _tokens[i];
            if (tokenAddress == address(0)) {
                _withdrawNativeFee();
            } else {
                _withdrawTokenFee(tokenAddress);
            }
        }
    }

    // accept ETH
    receive() external payable {}

    /* ========== VIEW FUNCTIONS  ========== */

    /// @dev Calculates asset identifier.
    /// @param _chainId Current chain id.
    /// @param _tokenAddress Address of the asset on the other chain.
    function getbDebridgeId(uint256 _chainId, bytes memory _tokenAddress)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(_chainId, _tokenAddress));
    }

    /// @dev Calculates asset identifier.
    /// @param _chainId Current chain id.
    /// @param _tokenAddress Address of the asset on the other chain.
    function getDebridgeId(uint256 _chainId, address _tokenAddress) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(_chainId, _tokenAddress));
    }
    /* ========== PRIVATE FUNCTIONS  ========== */

    /// @dev Transfer collected fees for a token to the caller.
    function _withdrawTokenFee(address _tokenAddress) private {
        (uint256 nativeChainId, bytes memory nativeAddress) = debridgeGate.getNativeInfo(
            _tokenAddress
        );
        bytes32 debridgeId = getbDebridgeId(nativeChainId, nativeAddress);
        debridgeGate.withdrawFee(debridgeId);

        uint256 amount = IERC20Upgradeable(_tokenAddress).balanceOf(address(this));
        IERC20Upgradeable(_tokenAddress).safeTransfer(msg.sender, amount);
    }

    /// @dev Transfer collected fees for a native token to the caller.
    function _withdrawNativeFee() private {
        bytes32 debridgeId = getDebridgeId(debridgeGate.getChainId(), address(0));
        debridgeGate.withdrawFee(debridgeId);

        uint256 amount = address(this).balance;
         _safeTransferETH(msg.sender, amount);
    }

    /// @dev transfer ETH to an address, revert if it fails.
    /// @param to recipient of the transfer
    /// @param value the amount to send
    function _safeTransferETH(address to, uint256 value) internal {
        (bool success, ) = to.call{value: value}(new bytes(0));
        if (!success) revert EthTransferFailed();
    }

    // ============ Version Control ============
    /// @dev Get this contract's version
    function version() external pure returns (uint256) {
        return 410; // 4.1.0
    }
}
