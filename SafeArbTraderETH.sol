// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

interface IUniswapV2Router {
    function WETH() external pure returns (address);
    
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
    
    function swapExactETHForTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable returns (uint[] memory amounts);
    
    function swapExactTokensForETH(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    
    function swapETHForExactTokens(
        uint amountOut,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable returns (uint[] memory amounts);
}

contract SafeArbTraderETH is Ownable, ReentrancyGuard, Pausable {
    // State variables
    uint256 public minProfitMargin = 1; // 0.1% minimum profit margin
    uint256 public minETHBalance = 0.1 ether; // Minimum ETH balance to keep
    mapping(address => bool) public approvedRouters;
    mapping(address => bool) public approvedTokens;
    
    // Events
    event ArbExecuted(
        address indexed token,
        uint256 ethIn,
        uint256 ethOut,
        uint256 profit
    );
    event RouterUpdated(address router, bool approved);
    event TokenUpdated(address token, bool approved);
    event AutoTradeEnabled(bool enabled);
    
    bool public autoTradeEnabled;
    uint256 public lastExecutionTime;
    uint256 public constant MIN_EXECUTION_DELAY = 1 minutes;

    constructor() Ownable(msg.sender) {
        // Initialize with common DEX routers
        approvedRouters[address(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D)] = true; // Uniswap V2
        approvedRouters[address(0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F)] = true; // Sushiswap
    }

    // Receive function to accept ETH
    receive() external payable {}

    // Admin functions
    function setMinProfitMargin(uint256 _margin) external onlyOwner {
        require(_margin > 0, "Margin must be greater than 0");
        minProfitMargin = _margin;
    }

    function setMinETHBalance(uint256 _minBalance) external onlyOwner {
        minETHBalance = _minBalance;
    }

    function setAutoTradeEnabled(bool _enabled) external onlyOwner {
        autoTradeEnabled = _enabled;
        emit AutoTradeEnabled(_enabled);
    }

    function setRouterApproval(address _router, bool _approved) external onlyOwner {
        require(_router != address(0), "Invalid router address");
        approvedRouters[_router] = _approved;
        emit RouterUpdated(_router, _approved);
    }

    function setTokenApproval(address _token, bool _approved) external onlyOwner {
        require(_token != address(0), "Invalid token address");
        approvedTokens[_token] = _approved;
        emit TokenUpdated(_token, _approved);
    }

    // View functions
    function checkETHArbitrageProfitability(
        address router1,
        address router2,
        address token,
        uint256 ethAmount
    ) public view returns (bool profitable, uint256 potentialProfit) {
        require(approvedRouters[router1] && approvedRouters[router2], "Unapproved routers");
        require(approvedTokens[token], "Unapproved token");

        address weth = IUniswapV2Router(router1).WETH();
        
        // Calculate ETH -> Token path
        address[] memory path1 = new address[](2);
        path1[0] = weth;
        path1[1] = token;
        uint256[] memory amountsOut1 = IUniswapV2Router(router1).getAmountsOut(ethAmount, path1);

        // Calculate Token -> ETH path
        address[] memory path2 = new address[](2);
        path2[0] = token;
        path2[1] = weth;
        uint256[] memory amountsOut2 = IUniswapV2Router(router2).getAmountsOut(amountsOut1[1], path2);

        // Check if profitable
        if (amountsOut2[1] > ethAmount) {
            potentialProfit = amountsOut2[1] - ethAmount;
            uint256 profitPercentage = (potentialProfit * 1000) / ethAmount;
            profitable = profitPercentage >= minProfitMargin;
        }

        return (profitable, potentialProfit);
    }

    // Main arbitrage execution function
    function executeETHArbitrage(
        address router1,
        address router2,
        address token,
        uint256 minProfit
    ) internal nonReentrant whenNotPaused returns (bool) {
        require(address(this).balance > minETHBalance, "Insufficient ETH balance");
        require(approvedRouters[router1] && approvedRouters[router2], "Unapproved routers");
        require(approvedTokens[token], "Unapproved token");
        require(block.timestamp >= lastExecutionTime + MIN_EXECUTION_DELAY, "Too soon to execute");

        uint256 ethToTrade = address(this).balance;
        address weth = IUniswapV2Router(router1).WETH();
        uint256 deadline = block.timestamp + 300; // 5 minutes deadline

        // First swap: ETH -> Token
        address[] memory path1 = new address[](2);
        path1[0] = weth;
        path1[1] = token;

        uint256[] memory amounts1 = IUniswapV2Router(router1).swapExactETHForTokens{value: ethToTrade}(
            0, // Accept any amount of tokens
            path1,
            address(this),
            deadline
        );

        // Get token balance after first swap
        uint256 tokenBalance = IERC20(token).balanceOf(address(this));
        
        // Approve second router to spend tokens
        IERC20(token).approve(router2, tokenBalance);

        // Second swap: Token -> ETH
        address[] memory path2 = new address[](2);
        path2[0] = token;
        path2[1] = weth;

        uint256[] memory amounts2 = IUniswapV2Router(router2).swapExactTokensForETH(
            tokenBalance,
            ethToTrade + minProfit, // Ensure minimum profit
            path2,
            address(this),
            deadline
        );

        // Calculate profit
        uint256 finalBalance = address(this).balance;
        require(finalBalance > ethToTrade, "No profit made");
        uint256 profit = finalBalance - ethToTrade;
        require(profit >= minProfit, "Insufficient profit");

        lastExecutionTime = block.timestamp;
        
        emit ArbExecuted(token, ethToTrade, finalBalance, profit);
        return true;
    }

    // Function to check and execute arbitrage opportunities automatically
    function checkAndExecuteArbitrage(
        address router1,
        address router2,
        address token
    ) external payable {
        require(autoTradeEnabled, "Auto-trade is disabled");
        require(msg.value >= minETHBalance, "Insufficient ETH sent");

        (bool profitable, uint256 potentialProfit) = checkETHArbitrageProfitability(
            router1,
            router2,
            token,
            msg.value
        );

        if (profitable) {
            require(executeETHArbitrage(router1, router2, token, potentialProfit), "Arbitrage execution failed");
            
            // Return profits to the caller
            (bool success, ) = msg.sender.call{value: address(this).balance}("");
            require(success, "ETH transfer failed");
        } else {
            // Return ETH if no profitable opportunity
            (bool success, ) = msg.sender.call{value: msg.value}("");
            require(success, "ETH return failed");
        }
    }

    // Emergency functions
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // Emergency ETH recovery
    function recoverETH() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }

    // Emergency token recovery
    function recoverToken(address token) external onlyOwner {
        uint256 balance = IERC20(token).balanceOf(address(this));
        IERC20(token).transfer(owner(), balance);
    }
} 