// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { ITransferAllowlist } from "./interfaces/ITransferAllowlist.sol";

/// @title Strands Digital Asset Custodial Account Proxy
contract StrandsDACAP is ERC20, AccessControl, Initializable, ITransferAllowlist {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    uint8 private immutable _decimals;

    mapping(address destination => bool) public override allowedDestination;

    event Retracted(address indexed retractedBy, address indexed from, uint256 amount);

    error SupplyMismatch(uint256 actualSupply, uint256 estimatedSupply);

    constructor(uint8 decimals_, string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        require(bytes(name_).length != 0, "name=0");
        require(bytes(symbol_).length != 0, "symbol=0");
        _decimals = decimals_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function initialize(address admin, address encoder) external onlyRole(DEFAULT_ADMIN_ROLE) initializer {
        require(admin != address(0), "admin=0");
        require(encoder != address(0), "encoder=0");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, encoder);

        if (msg.sender != admin) _revokeRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function initialized() external view returns (bool) {
        return _getInitializedVersion() != 0;
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    function encode(address to, uint256 amount) external onlyRole(OPERATOR_ROLE) {
        _mint(to, amount);
    }

    function guardEncode(address to, uint256 amount, uint256 estimatedSupply) external onlyRole(OPERATOR_ROLE) {
        uint256 actual = totalSupply();
        if (actual != estimatedSupply) revert SupplyMismatch(actual, estimatedSupply);
        _mint(to, amount);
    }

    function guardRetract(address from, uint256 amount, uint256 estimatedSupply) external onlyRole(OPERATOR_ROLE) {
        uint256 actual = totalSupply();
        if (actual != estimatedSupply) revert SupplyMismatch(actual, estimatedSupply);
        _burn(from, amount);
        emit Retracted(msg.sender, from, amount);
    }

    function adminRetract(address from, uint256 amount) external onlyRole(OPERATOR_ROLE) {
        _burn(from, amount);
        emit Retracted(msg.sender, from, amount);
    }

    function setDestinationAllowed(address destination, bool allowed) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        allowedDestination[destination] = allowed;
        emit DestinationAllowedSet(destination, allowed);
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        _requireDestinationAllowed(to);
        return super.transfer(to, value);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        _requireDestinationAllowed(to);
        return super.transferFrom(from, to, value);
    }

    function _requireDestinationAllowed(address destination) private view {
        if (!allowedDestination[destination]) revert TransferDestinationNotAllowed(destination);
    }
}
