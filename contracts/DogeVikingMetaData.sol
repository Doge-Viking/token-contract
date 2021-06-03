// SPDX-License-Identifier: MIT

pragma solidity ^0.8.4;

import "./interfaces/IERC20MetaData.sol";

abstract contract DogeVikingMetaData is IERC20Metadata {
    /**
     *@dev The name of the token managed by the this smart contract.
     */
    string private constant _name = "Doge Viking";

    /**
     *@dev The symbol of the token managed by the this smart contract.
     */
    string private constant _symbol = "DVK";

    /**
     *@dev The decimals of the token managed by the this smart contract.
     */
    uint8 private constant _decimals = 9;

    /**
     *@dev It returns the name of the token.
     */
    function name() external pure override returns (string memory) {
        return _name;
    }

    /**
     *@dev It returns the symbol of the token.
     */
    function symbol() external pure override returns (string memory) {
        return _symbol;
    }

    /**
     *@dev It returns the decimal of the token.
     */
    function decimals() external pure override returns (uint8) {
        return _decimals;
    }
}
