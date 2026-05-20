// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IReputationSystem {
    function updateReputation(address user, bool correct) external;
    function getReputation(address user) external view returns (uint256);
}

/**
 * @title WorldCupBetting
 * @notice Assessment implementation for World Cup prediction market
 */
contract WorldCupBetting is ReentrancyGuard, Ownable {
    enum MarketStatus {
        Open,
        Closed,
        Resolved,
        Cancelled
    }

    struct Market {
        uint256 id;
        string title;
        string description;
        string[] outcomes;
        uint256 resolutionTime;
        address arbitrator;
        address tokenAddress;
        MarketStatus status;
        uint256 winningOutcome;
        address creator;
    }

    struct Bet {
        uint256 id;
        uint256 marketId;
        address bettor;
        uint256 outcome;
        uint256 amount;
        uint256 shares;
        bool claimed;
        bool listed;
        uint256 listPrice;
    }

    IReputationSystem public reputationSystem;

    uint256 public marketCount;
    uint256 public betCount;

    uint256 public constant PLATFORM_FEE_BPS = 200; // 2%
    uint256 public constant BPS_DENOMINATOR = 10000;

    mapping(uint256 => Market) public markets;
    mapping(uint256 => Bet) public bets;

    mapping(uint256 => uint256[]) public marketBetIds;
    mapping(address => uint256[]) public userBetIds;

    // marketId => outcome => amount
    mapping(uint256 => mapping(uint256 => uint256)) public outcomePools;

    // token => fee amount
    mapping(address => uint256) private availableFees;

    constructor(address _reputationSystem) Ownable(msg.sender) {
        reputationSystem = IReputationSystem(_reputationSystem);
    }

    function createMarket(
        string memory title,
        string memory description,
        string[] memory outcomes,
        uint256 resolutionTime,
        address arbitrator,
        address tokenAddress
    ) external returns (uint256) {
        require(resolutionTime > block.timestamp, "Invalid resolution");

        marketCount++;

        Market storage m = markets[marketCount];

        m.id = marketCount;
        m.title = title;
        m.description = description;
        m.resolutionTime = resolutionTime;
        m.arbitrator = arbitrator;
        m.tokenAddress = tokenAddress;
        m.status = MarketStatus.Open;
        m.creator = msg.sender;
        m.winningOutcome = 0;

        for (uint256 i = 0; i < outcomes.length; i++) {
            m.outcomes.push(outcomes[i]);
        }

        return marketCount;
    }

    function placeBet(
        uint256 marketId,
        uint256 outcome,
        uint256 amount,
        uint256 minShares
    ) external payable returns (uint256) {
        Market storage m = markets[marketId];

        require(m.id != 0, "Invalid market");
        require(block.timestamp < m.resolutionTime, "Market closed");
        require(m.status == MarketStatus.Open, "Market closed");

        uint256 shares = calculateShares(marketId, outcome, amount);

        require(shares >= minShares, "Slippage exceeded");

        if (m.tokenAddress == address(0)) {
            require(msg.value == amount, "Invalid ETH amount");
        } else {
            require(msg.value == 0, "ETH not accepted");

            IERC20(m.tokenAddress).transferFrom(
                msg.sender,
                address(this),
                amount
            );
        }

        betCount++;

        bets[betCount] = Bet({
            id: betCount,
            marketId: marketId,
            bettor: msg.sender,
            outcome: outcome,
            amount: amount,
            shares: shares,
            claimed: false,
            listed: false,
            listPrice: 0
        });

        marketBetIds[marketId].push(betCount);
        userBetIds[msg.sender].push(betCount);

        outcomePools[marketId][outcome] += amount;

        return betCount;
    }

    function resolveMarket(uint256 marketId, uint256 winningOutcome) external {
        Market storage m = markets[marketId];

        require(msg.sender == m.arbitrator, "Only arbitrator");
        require(block.timestamp >= m.resolutionTime, "Too early");
        require(m.status != MarketStatus.Resolved, "Already resolved");

        m.status = MarketStatus.Resolved;
        m.winningOutcome = winningOutcome;
    }

    function claimWinnings(uint256 betId) external nonReentrant {
        Bet storage b = bets[betId];
        Market storage m = markets[b.marketId];

        require(!b.claimed, "Already claimed");
        require(m.status == MarketStatus.Resolved, "Not resolved");

        b.claimed = true;

        bool won = b.outcome == m.winningOutcome;

        reputationSystem.updateReputation(b.bettor, won);

        // Losing bets can still settle reputation
        if (!won) {
            return;
        }

        uint256 totalPool = getTotalPool(b.marketId);
        uint256 winningPool = outcomePools[b.marketId][m.winningOutcome];

        require(winningPool > 0, "No winners");

        uint256 grossPayout = (b.amount * totalPool) / winningPool;

        uint256 fee = (grossPayout * PLATFORM_FEE_BPS) /
            BPS_DENOMINATOR;

        uint256 payout = grossPayout - fee;

        availableFees[m.tokenAddress] += fee;

        if (m.tokenAddress == address(0)) {
            payable(msg.sender).transfer(payout);
        } else {
            IERC20(m.tokenAddress).transfer(msg.sender, payout);
        }
    }

    function listPosition(uint256 betId, uint256 price) external {
        Bet storage b = bets[betId];

        require(msg.sender == b.bettor, "Not owner");
        require(!b.claimed, "Already claimed");

        b.listed = true;
        b.listPrice = price;
    }

    function cancelListing(uint256 betId) external {
        Bet storage b = bets[betId];

        require(msg.sender == b.bettor, "Not owner");

        b.listed = false;
        b.listPrice = 0;
    }

    function buyPosition(uint256 betId) external payable nonReentrant {
        Bet storage b = bets[betId];
        Market storage m = markets[b.marketId];

        require(b.listed, "Not listed");

        address seller = b.bettor;
        uint256 price = b.listPrice;

        if (m.tokenAddress == address(0)) {
            require(msg.value == price, "Invalid payment");

            payable(seller).transfer(price);
        } else {
            require(msg.value == 0, "ETH not accepted");

            IERC20(m.tokenAddress).transferFrom(
                msg.sender,
                seller,
                price
            );
        }

        b.bettor = msg.sender;
        b.listed = false;
        b.listPrice = 0;

        userBetIds[msg.sender].push(betId);
    }

    function withdrawFees(address token)
        external
        onlyOwner
        nonReentrant
    {
        uint256 amount = availableFees[token];

        require(amount > 0, "No fees");

        availableFees[token] = 0;

        if (token == address(0)) {
            payable(owner()).transfer(amount);
        } else {
            IERC20(token).transfer(owner(), amount);
        }
    }

    function getAvailableFees(address token)
        external
        view
        returns (uint256)
    {
        return availableFees[token];
    }

    function calculateShares(
        uint256,
        uint256,
        uint256 amount
    ) public pure returns (uint256) {
        return amount;
    }

    function getPrice(
        uint256,
        uint256
    ) public pure returns (uint256) {
        return 1e18;
    }

    function getTotalPool(
        uint256 marketId
    ) public view returns (uint256) {
        uint256 total = 0;

        uint256[] memory ids = marketBetIds[marketId];

        for (uint256 i = 0; i < ids.length; i++) {
            total += bets[ids[i]].amount;
        }

        return total;
    }

    function getUserBets(
        address user
    ) external view returns (uint256[] memory) {
        return userBetIds[user];
    }

    function getMarketBets(
        uint256 marketId
    ) external view returns (uint256[] memory) {
        return marketBetIds[marketId];
    }

    function getMarket(uint256 marketId)
        external
        view
        returns (
            uint256 id,
            string memory title,
            string memory description,
            string[] memory outcomes,
            uint256 resolutionTime,
            address arbitrator,
            address tokenAddress,
            MarketStatus status,
            uint256 winningOutcome,
            address creator
        )
    {
        Market storage m = markets[marketId];

        return (
            m.id,
            m.title,
            m.description,
            m.outcomes,
            m.resolutionTime,
            m.arbitrator,
            m.tokenAddress,
            m.status,
            m.winningOutcome,
            m.creator
        );
    }
}