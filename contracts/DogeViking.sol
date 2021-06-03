// SPDX-License-Identifier: MIT

pragma solidity ^0.8.4;

import "./DogeVikingMetaData.sol";
import "./lib/Ownable.sol";
import "./interfaces/IUniswapV2Router02.sol";
import "./interfaces/IUniswapV2Factory.sol";

contract DogeViking is DogeVikingMetaData, Ownable {
    // Supply *************************************************************

    uint256 private constant MAX_INT_VALUE = type(uint256).max;

    uint256 private constant _tokenSupply = 1e6 ether;

    uint256 private _reflectionSupply = (MAX_INT_VALUE -
        (MAX_INT_VALUE % _tokenSupply));

    // Taxes *************************************************************

    uint8 public liquidityFee = 5;

    uint8 private _previousLiquidityFee = liquidityFee;

    uint8 public dogeVikingFundFee = 2;

    uint8 private _previousDogeVikingFundFee = dogeVikingFundFee;

    uint8 public txFee = 3;

    uint8 private _previousTxFee = txFee;

    uint8 public vestingFee = 50;

    uint256 private _previousVestingFee = vestingFee;

    uint256 private _totalTokenFees;

    // Wallets *************************************************************

    mapping(address => uint256) private _reflectionBalance;

    mapping(address => uint256) private _tokenBalance;

    mapping(address => mapping(address => uint256)) private _allowances;

    // Privileges *************************************************************

    mapping(address => bool) private _isExcludedFromFees;

    // Tx Data *************************************************************

    uint256 public constant maxTxAmount = 5 * 1e3 ether;

    uint256 private constant _numberTokensSellToAddToLiquidity = 5 * 1e2 ether;

    // Events *************************************************************

    event SwapAndLiquefy(
        uint256 tokensSwapped,
        uint256 ethReceived,
        uint256 tokensIntoLiqudity
    );

    event SwapAndLiquefyStateUpdate(bool state);

    // State *************************************************************

    bool public isSwapAndLiquifyingEnabled;

    bool private _swapAndLiquifyingInProgress;

    bool public allowTrading;

    bool public catchWhales = true;

    // Addresses *************************************************************

    address public immutable vikingFund;

    IUniswapV2Router02 public immutable uniswapV2Router;

    address public immutable uniswapV2WETHPair;

    constructor(address routerAddress, address vikingFundAddress) {
        _reflectionBalance[_msgSender()] = _reflectionSupply;

        IUniswapV2Router02 _uniswapV2Router = IUniswapV2Router02(routerAddress);

        uniswapV2WETHPair = IUniswapV2Factory(_uniswapV2Router.factory())
            .createPair(address(this), _uniswapV2Router.WETH());

        uniswapV2Router = _uniswapV2Router;

        vikingFund = vikingFundAddress;

        _isExcludedFromFees[owner()] = true;
        _isExcludedFromFees[address(this)] = true;
        _isExcludedFromFees[vikingFundAddress] = true;

        emit Transfer(address(0), _msgSender(), _tokenSupply);
    }

    modifier lockTheSwap {
        _swapAndLiquifyingInProgress = true;
        _;
        _swapAndLiquifyingInProgress = false;
    }

    function totalSupply() external pure override returns (uint256) {
        return _tokenSupply;
    }

    function isExcludedFromFees(address account) external view returns (bool) {
        return _isExcludedFromFees[account];
    }

    function _getRate() private view returns (uint256) {
        return _reflectionSupply / _tokenSupply;
    }

    function _reflectionFromToken(uint256 amount)
        private
        view
        returns (uint256)
    {
        require(
            _tokenSupply >= amount,
            "You cannot own more tokens than the total token supply"
        );
        return amount * _getRate();
    }

    function _tokenFromReflection(uint256 reflectionAmount)
        private
        view
        returns (uint256)
    {
        require(
            _reflectionSupply >= reflectionAmount,
            "Cannot have a personal reflection amount larger than total reflection"
        );
        return reflectionAmount / _getRate();
    }

    function balanceOf(address account)
        external
        view
        override
        returns (uint256)
    {
        uint256 rVestingTax =
            _calculatingVestingFee(_reflectionBalance[account]);
        return _tokenFromReflection(_reflectionBalance[account] - rVestingTax);
    }

    function fullBalanceOf(address account) public view returns (uint256) {
        return _tokenFromReflection(_reflectionBalance[account]);
    }

    function vestedBalanceOf(address account) external view returns (uint256) {
        return
            _tokenFromReflection(
                _calculatingVestingFee(_reflectionBalance[account])
            );
    }

    function totalFees() external view returns (uint256) {
        return _totalTokenFees;
    }

    function deliver(uint256 amount) public {
        address sender = _msgSender();
        uint256 reflectionAmount = _reflectionFromToken(amount);
        _reflectionBalance[sender] =
            _reflectionBalance[sender] -
            reflectionAmount;
        _reflectionSupply -= reflectionAmount;
        _totalTokenFees += amount;
    }

    function excludeFromFees(address account) external onlyOwner() {
        _isExcludedFromFees[account] = true;
    }

    function includeInFees(address account) external onlyOwner() {
        _isExcludedFromFees[account] = false;
    }

    function _removeAllFees() private {
        if (liquidityFee == 0 && dogeVikingFundFee == 0 && txFee == 0) return;

        _previousLiquidityFee = liquidityFee;
        _previousDogeVikingFundFee = dogeVikingFundFee;
        _previousTxFee = txFee;

        liquidityFee = 0;
        dogeVikingFundFee = 0;
        txFee = 0;
    }

    function _restoreAllFees() private {
        liquidityFee = _previousLiquidityFee;
        dogeVikingFundFee = _previousDogeVikingFundFee;
        txFee = _previousTxFee;
    }

    function setSwapAndLiquifyingState(bool state) external onlyOwner() {
        isSwapAndLiquifyingEnabled = state;
        emit SwapAndLiquefyStateUpdate(state);
    }

    function _calculateFee(uint256 amount, uint8 fee)
        private
        pure
        returns (uint256)
    {
        return (amount * fee) / 100;
    }

    function _calculateTxFee(uint256 amount) private view returns (uint256) {
        return _calculateFee(amount, txFee);
    }

    function _calculateLiquidityFee(uint256 amount)
        private
        view
        returns (uint256)
    {
        return _calculateFee(amount, liquidityFee);
    }

    function _calculateFundFee(uint256 amount) private view returns (uint256) {
        return _calculateFee(amount, dogeVikingFundFee);
    }

    function _calculatingVestingFee(uint256 amount)
        private
        view
        returns (uint256)
    {
        return _calculateFee(amount, vestingFee);
    }

    function _reflectFee(uint256 rfee, uint256 fee) private {
        _reflectionSupply -= rfee;
        _totalTokenFees += fee;
    }

    function _takeLiquidity(uint256 amount) private {
        _reflectionBalance[address(this)] =
            _reflectionBalance[address(this)] +
            _reflectionFromToken(amount);
    }

    receive() external payable {}

    function _transferToken(
        address sender,
        address recipient,
        uint256 amount,
        bool removeFees
    ) private {
        if (removeFees) _removeAllFees();

        uint256 rAmount = _reflectionFromToken(amount);

        if (
            catchWhales &&
            recipient != address(uniswapV2WETHPair) &&
            sender != owner() &&
            recipient != owner()
        ) {
            require(
                _tokenFromReflection(_reflectionBalance[recipient] + rAmount) <=
                    maxTxAmount,
                "No whales allowed right now :)"
            );
        }

        _reflectionBalance[sender] = _reflectionBalance[sender] - rAmount;

        // Holders retribution
        uint256 tax = _calculateTxFee(amount);
        uint256 rTax = _reflectionFromToken(tax);

        // Fund retribution
        uint256 fundTax = _calculateFundFee(amount);
        uint256 rFundTax = _reflectionFromToken(fundTax);

        // Liquidity retribution
        uint256 liquidityTax = _calculateLiquidityFee(amount);
        uint256 rLiquidityTax = _reflectionFromToken(liquidityTax);

        // Vesting Fee
        uint256 vestingTax = _calculatingVestingFee(amount);
        uint256 rVestingTax = _reflectionFromToken(vestingTax);

        // Since the recipient is also  excluded. We need to update his reflections and tokens.
        _reflectionBalance[recipient] =
            _reflectionBalance[recipient] +
            rAmount -
            rTax -
            rFundTax -
            rLiquidityTax -
            rVestingTax;

        _reflectionBalance[vikingFund] =
            _reflectionBalance[vikingFund] +
            rFundTax;

        _takeLiquidity(rLiquidityTax + rVestingTax);
        _reflectFee(rTax, tax + fundTax + liquidityTax + vestingTax);

        emit Transfer(
            sender,
            recipient,
            amount - vestingTax - liquidityTax - fundTax - tax
        );

        // Restores all fees if they were disabled.
        if (removeFees) _restoreAllFees();
    }

    function _swapTokensForEth(uint256 tokenAmount) private {
        // generate the uniswap pair path of token -> weth
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapV2Router.WETH();

        _approve(address(this), address(uniswapV2Router), tokenAmount);

        // make the swap
        uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of ETH
            path,
            address(this),
            block.timestamp
        );
    }

    function _addLiquidity(uint256 tokenAmount, uint256 ethAmount) private {
        // approve token transfer to cover all possible scenarios
        _approve(address(this), address(uniswapV2Router), tokenAmount);

        // add the liquidity
        uniswapV2Router.addLiquidityETH{value: ethAmount}(
            address(this),
            tokenAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            address(0),
            block.timestamp
        );
    }

    function _swapAndLiquefy() private lockTheSwap {
        // split the contract token balance into halves
        uint256 half = _numberTokensSellToAddToLiquidity / 2;
        uint256 otherHalf = _numberTokensSellToAddToLiquidity - half;

        uint256 initialETHContractBalance = address(this).balance;

        // Buys ETH at current token price
        _swapTokensForEth(half);

        // This is to make sure we are only using ETH derived from the liquidity fee
        uint256 ethBought = address(this).balance - initialETHContractBalance;

        // Add liquidity to the pool
        _addLiquidity(otherHalf, ethBought);

        emit SwapAndLiquefy(half, ethBought, otherHalf);
    }

    function enableTrading() external onlyOwner() {
        allowTrading = true;
    }

    function freeWhales() external onlyOwner() {
        catchWhales = false;
    }

    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) private {
        require(
            sender != address(0),
            "ERC20: Sender cannot be the zero address"
        );
        require(
            recipient != address(0),
            "ERC20: Recipient cannot be the zero address"
        );
        require(amount > 0, "Transfer amount must be greater than zero");
        if (sender != owner() && recipient != owner()) {
            require(
                amount <= maxTxAmount,
                "Transfer amount exceeds the maxTxAmount."
            );

            require(allowTrading, "Nice try :)");
        }

        // Condition 1: Make sure the contract has the enough tokens to liquefy
        // Condition 2: We are not in a liquefication event
        // Condition 3: Liquification is enabled
        // Condition 4: It is not the uniswapPair that is sending tokens

        if (
            fullBalanceOf(address(this)) >= _numberTokensSellToAddToLiquidity &&
            !_swapAndLiquifyingInProgress &&
            isSwapAndLiquifyingEnabled &&
            sender != address(uniswapV2WETHPair)
        ) _swapAndLiquefy();

        _transferToken(
            sender,
            recipient,
            amount,
            _isExcludedFromFees[sender] || _isExcludedFromFees[recipient]
        );
    }

    function _approve(
        address owner,
        address beneficiary,
        uint256 amount
    ) private {
        require(
            beneficiary != address(0),
            "The burn address is not allowed to receive approval for allowances."
        );
        require(
            owner != address(0),
            "The burn address is not allowed to approve allowances."
        );

        _allowances[owner][beneficiary] = amount;
        emit Approval(owner, beneficiary, amount);
    }

    // Events *************************************************************

    function setLiquidityFee(uint8 amount) external onlyOwner() {
        require(amount <= 10, "The maximum amount allowed is 10%");
        liquidityFee = amount;
    }

    function setDogeVikingFundFee(uint8 amount) external onlyOwner() {
        require(amount <= 5, "The maximum amount allowed is 5%");
        dogeVikingFundFee = amount;
    }

    function setTxFee(uint8 amount) external onlyOwner() {
        require(amount <= 5, "The maximum amount allowed is 5%");
        txFee = amount;
    }

    function setVestingFee(uint8 amount) external onlyOwner() {
        require(amount <= 60, "The maximum amount allowed is 60%");
        vestingFee = amount;
    }

    function transfer(address recipient, uint256 amount)
        external
        override
        returns (bool)
    {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    function approve(address beneficiary, uint256 amount)
        external
        override
        returns (bool)
    {
        _approve(_msgSender(), beneficiary, amount);
        return true;
    }

    function transferFrom(
        address provider,
        address beneficiary,
        uint256 amount
    ) external override returns (bool) {
        _transfer(provider, beneficiary, amount);
        _approve(
            provider,
            _msgSender(),
            _allowances[provider][_msgSender()] - amount
        );
        return true;
    }

    function allowance(address owner, address beneficiary)
        external
        view
        override
        returns (uint256)
    {
        return _allowances[owner][beneficiary];
    }

    function increaseAllowance(address beneficiary, uint256 amount)
        external
        returns (bool)
    {
        _approve(
            _msgSender(),
            beneficiary,
            _allowances[_msgSender()][beneficiary] + amount
        );
        return true;
    }

    function decreaseAllowance(address beneficiary, uint256 amount)
        external
        returns (bool)
    {
        _approve(
            _msgSender(),
            beneficiary,
            _allowances[_msgSender()][beneficiary] - amount
        );
        return true;
    }
}
