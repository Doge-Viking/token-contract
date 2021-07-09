// SPDX-License-Identifier: MIT

pragma solidity ^0.8.4;

import "./DogeVikingMetaData.sol";
import "./lib/Ownable.sol";
import "./interfaces/IUniswapV2Router02.sol";
import "./interfaces/IUniswapV2Factory.sol";
import "./interfaces/IUniswapV2Pair.sol";

struct Exceptions {
    bool noHoldingLimit;
    bool noFees;
    bool noMaxTxAmount;
}

enum Token {ZERO, ONE}

contract DogeViking is DogeVikingMetaData, Ownable {
    // Supply *************************************************************

    uint256 private constant MAX_INT_VALUE = type(uint256).max;

    uint256 private constant _tokenSupply = 1e6 ether;

    uint256 private _reflectionSupply = (MAX_INT_VALUE -
        (MAX_INT_VALUE % _tokenSupply));

    // Taxes *************************************************************

    uint8 public liquidityFee = 20;

    uint8 private _previousLiquidityFee = liquidityFee;

    uint8 public dogeVikingPoolFee = 2;

    uint8 private _previousDogeVikingPoolFee = dogeVikingPoolFee;

    uint8 public txFee = 3;

    uint8 private _previousTxFee = txFee;

    uint256 private _totalTokenFees;

    // Wallets *************************************************************

    mapping(address => uint256) private _reflectionBalance;

    mapping(address => mapping(address => uint256)) private _allowances;

    mapping(address => uint256) public previousSale;

    // Privileges *************************************************************

    mapping(address => Exceptions) public exceptions;

    // Constraints *************************************************************

    // 0.5% of the total supply
    uint256 public constant maxTxAmount = 5 * 1e3 ether;

    // 0.05% of the total supply
    uint256 public numberTokensSellToAddToLiquidity = 5 * 1e2 ether;

    // Starts at a very high value for the pre sale. Then it needs to be updated to 5 * 1e2 ether
    uint256 public sellLimitThreshold = 1e6 ether;

    // 0.1% of the total supply
    uint256 public maxHoldingAmount = 1 * 1e3 ether;

    uint256 public sellDelay = 3 days;

    uint256 public liquidityRatioBps = 50;

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

    // Addresses *************************************************************

    address public vikingPool;

    IUniswapV2Router02 public uniswapV2Router;

    address public uniswapV2WETHPair;

    constructor(address routerAddress, address vikingPoolAddress) {
        _reflectionBalance[_msgSender()] = _reflectionSupply;

        IUniswapV2Router02 _uniswapV2Router = IUniswapV2Router02(routerAddress);

        uniswapV2WETHPair = IUniswapV2Factory(_uniswapV2Router.factory())
            .createPair(address(this), _uniswapV2Router.WETH());

        uniswapV2Router = _uniswapV2Router;

        vikingPool = vikingPoolAddress;

        exceptions[owner()].noFees = true;
        exceptions[address(this)].noFees = true;
        exceptions[vikingPoolAddress].noFees = true;

        exceptions[owner()].noHoldingLimit = true;
        exceptions[address(this)].noHoldingLimit = true;
        exceptions[vikingPoolAddress].noHoldingLimit = true;
        exceptions[uniswapV2WETHPair].noHoldingLimit = true;

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
        return exceptions[account].noFees;
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

    function balanceOf(address account) public view override returns (uint256) {
        return _tokenFromReflection(_reflectionBalance[account]);
    }

    function totalFees() external view returns (uint256) {
        return _totalTokenFees;
    }

    function _removeAllFees() private {
        if (liquidityFee == 0 && dogeVikingPoolFee == 0 && txFee == 0) return;

        _previousLiquidityFee = liquidityFee;
        _previousDogeVikingPoolFee = dogeVikingPoolFee;
        _previousTxFee = txFee;

        liquidityFee = 0;
        dogeVikingPoolFee = 0;
        txFee = 0;
    }

    function _restoreAllFees() private {
        liquidityFee = _previousLiquidityFee;
        dogeVikingPoolFee = _previousDogeVikingPoolFee;
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

    function _calculatePoolFee(uint256 amount) private view returns (uint256) {
        return _calculateFee(amount, dogeVikingPoolFee);
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

        _reflectionBalance[sender] = _reflectionBalance[sender] - rAmount;

        // Holders retribution
        uint256 rTax = _reflectionFromToken(_calculateTxFee(amount));

        // Pool retribution
        uint256 rPoolTax = _reflectionFromToken(_calculatePoolFee(amount));

        // Liquidity retribution
        uint256 rLiquidityTax =
            _reflectionFromToken(_calculateLiquidityFee(amount));

        // Since the recipient is also  excluded. We need to update his reflections and tokens.
        _reflectionBalance[recipient] =
            _reflectionBalance[recipient] +
            rAmount -
            rTax -
            rPoolTax -
            rLiquidityTax;

        _reflectionBalance[vikingPool] =
            _reflectionBalance[vikingPool] +
            rPoolTax;

        _takeLiquidity(rLiquidityTax);
        _reflectFee(
            rTax,
            _calculateTxFee(amount) +
                _calculatePoolFee(amount) +
                _calculateLiquidityFee(amount)
        );

        previousSale[sender] = block.timestamp;
        emit Transfer(
            sender,
            recipient,
            amount -
                _calculateLiquidityFee(amount) -
                _calculatePoolFee(amount) -
                _calculateTxFee(amount)
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
            owner(),
            block.timestamp
        );
    }

    function _swapAndLiquefy() private lockTheSwap {
        // split the contract token balance into halves
        uint256 half = numberTokensSellToAddToLiquidity / 2;
        uint256 otherHalf = numberTokensSellToAddToLiquidity - half;

        uint256 initialETHContractBalance = address(this).balance;

        // Buys ETH at current token price
        _swapTokensForEth(half);

        // This is to make sure we are only using ETH derived from the liquidity fee
        uint256 ethBought = address(this).balance - initialETHContractBalance;

        // Add liquidity to the pool
        _addLiquidity(otherHalf, ethBought);

        emit SwapAndLiquefy(half, ethBought, otherHalf);
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

        // Owner has no limits
        if (sender != owner() && recipient != owner()) {
            // Future utility contracts might need conduct large TXs.
            if (!exceptions[sender].noMaxTxAmount)
                require(
                    amount <= maxTxAmount,
                    "Transfer amount exceeds the maxTxAmount."
                );

            // Future utility contracts and EOA like exchanges should not have a holding limit
            if (!exceptions[recipient].noHoldingLimit) {
                require(
                    balanceOf(recipient) + amount <= maxHoldingAmount,
                    "Your holdings will pass the limit."
                );
            }

            // Should be limited to selling on pancake swap to protect holders or when it is this contract selling for the liquidity event
            if (
                recipient == address(uniswapV2Router) ||
                (recipient == address(uniswapV2WETHPair) &&
                    sender != address(this))
            ) {
                // Only whales get triggered
                if (balanceOf(sender) > sellLimitThreshold) {
                    address pair =
                        IUniswapV2Factory(uniswapV2Router.factory()).getPair(
                            address(this),
                            uniswapV2Router.WETH()
                        );

                    // If the pair with WETH exists. Sell orders above a certain percentage of the total liquidity will be refused.
                    if (pair != address(0)) {
                        address token0 = IUniswapV2Pair(pair).token0();

                        Token ourToken =
                            address(this) == token0 ? Token.ZERO : Token.ONE;

                        (uint256 reserve0, uint256 reserve1, ) =
                            IUniswapV2Pair(pair).getReserves();

                        if (
                            ourToken == Token.ZERO &&
                            reserve0 * liquidityRatioBps >= 10000
                        ) {
                            require(
                                (reserve0 * liquidityRatioBps) / 10000 >=
                                    amount,
                                "High price impact on PCS liquidity"
                            );
                        }

                        if (
                            ourToken == Token.ONE &&
                            reserve1 * liquidityRatioBps >= 10000
                        ) {
                            require(
                                (reserve1 * liquidityRatioBps) / 10000 >=
                                    amount,
                                "High price impact on PCS liquidity"
                            );
                        }
                    }

                    require(
                        block.timestamp - previousSale[sender] > sellDelay,
                        "You must wait to sell again."
                    );
                }
            }
        }

        // Condition 1: Make sure the contract has the enough tokens to liquefy
        // Condition 2: We are not in a liquefication event
        // Condition 3: Liquification is enabled
        // Condition 4: It is not the uniswapPair that is sending tokens

        if (
            balanceOf(address(this)) >= numberTokensSellToAddToLiquidity &&
            !_swapAndLiquifyingInProgress &&
            isSwapAndLiquifyingEnabled &&
            sender != address(uniswapV2WETHPair)
        ) _swapAndLiquefy();

        _transferToken(
            sender,
            recipient,
            amount,
            exceptions[sender].noFees || exceptions[recipient].noFees
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

    // ********************************* SETTERS *********************************

    function setLiquidityFee(uint8 amount) external onlyOwner() {
        require(amount <= 20, "The maximum amount allowed is 20%");
        liquidityFee = amount;
    }

    function setDogeVikingFundFee(uint8 amount) external onlyOwner() {
        require(amount <= 2, "The maximum amount allowed is 3%");
        dogeVikingPoolFee = amount;
    }

    function setTxFee(uint8 amount) external onlyOwner() {
        require(amount <= 10, "The maximum amount allowed is 5%");
        txFee = amount;
    }

    function setPoolAddress(address _address) external onlyOwner() {
        exceptions[vikingPool].noFees = false;
        exceptions[_address].noFees = true;
        vikingPool = _address;
    }

    function setNumberTokensSellToAddToLiquidity(uint256 _amount)
        external
        onlyOwner()
    {
        numberTokensSellToAddToLiquidity = _amount;
    }

    function updateRouter(address _router) external onlyOwner() {
        IUniswapV2Router02 _uniswapV2Router = IUniswapV2Router02(_router);

        address pair =
            IUniswapV2Factory(_uniswapV2Router.factory()).getPair(
                address(this),
                _uniswapV2Router.WETH()
            );

        if (pair == address(0)) {
            pair = IUniswapV2Factory(_uniswapV2Router.factory()).createPair(
                address(this),
                _uniswapV2Router.WETH()
            );
        }

        uniswapV2WETHPair = pair;
        uniswapV2Router = _uniswapV2Router;
    }

    function excludeFromFees(address account) external onlyOwner() {
        exceptions[account].noFees = true;
    }

    function includeInFees(address account) external onlyOwner() {
        exceptions[account].noFees = false;
    }

    function removeHoldingLimit(address account) external onlyOwner() {
        exceptions[account].noHoldingLimit = true;
    }

    function addHoldinglimit(address account) external onlyOwner() {
        exceptions[account].noHoldingLimit = false;
    }

    function removeMaxTxAmount(address account) external onlyOwner() {
        exceptions[account].noMaxTxAmount = true;
    }

    function addMaxTxAmount(address account) external onlyOwner() {
        exceptions[account].noMaxTxAmount = false;
    }

    function setMaxHoldingAmount(uint256 _amount) external onlyOwner() {
        // 0.05% of total supply
        require(_amount >= 5 * 1e2 ether, "Please set a higher amount");
        // 0.5% of total supply
        require(_amount <= 5 * 1e3 ether, "Please set a lower amount");
        maxHoldingAmount = _amount;
    }

    function setSellLimitThreshold(uint256 _amount) external onlyOwner() {
        // 0.05% of total supply
        require(_amount >= 5 * 1e2 ether, "Please set a higher amount");
        // 0.5% of total supply
        require(_amount <= 5 * 1e3 ether, "Please set a lower amount");
        sellLimitThreshold = _amount;
    }

    function setSellDelay(uint256 _delay) external onlyOwner() {
        require(_delay <= 5 days, "The maximum delay is 5 days");
        require(_delay >= 30 minutes, "The minimum delay is 30 minutes");
        sellDelay = _delay;
    }

    function setliquidityRatioBps(uint256 _amount) external onlyOwner() {
        require(_amount >= 50, "The minimum bpd is 0.5%");
        require(_amount <= 200, "The maximum bpd is 2%");
        liquidityRatioBps = _amount;
    }

    // ********************************* Withdrawals *********************************

    function withdrawETH() external onlyOwner() {
        (bool success, ) =
            payable(owner()).call{value: address(this).balance}("");
        require(success, "Error withdrawing ETH");
    }

    function withdrawERC20(address _token, address _to)
        external
        onlyOwner()
        returns (bool sent)
    {
        require(
            _token != address(this),
            "You cannot withdraw this contract tokens."
        );
        uint256 _contractBalance = IERC20(_token).balanceOf(address(this));
        sent = IERC20(_token).transfer(_to, _contractBalance);
    }
}


