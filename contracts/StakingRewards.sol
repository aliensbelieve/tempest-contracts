// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

// Inheritance
import "./interfaces/IRewardRate.sol";

contract StakingRewards is IRewardRate, Ownable , ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    /* ========== STATE VARIABLES ========== */

    IERC20 public immutable stakingToken;
    IERC20 public immutable rewardToken;

    uint256 public rewardRate;
    uint256 public rewardPerTokenStored;
    uint256 public rewardsDuration;
    uint256 public lastUpdateTime;
    uint256 public periodFinish;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    uint256 private _totalSupply;

    mapping (address => bool) public rewardsDistributions;
    mapping(address => uint256) private _balances;

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _stakingToken,
        address _earnToken
    ) public {

        rewardToken = IERC20(_earnToken);
        stakingToken = IERC20(_stakingToken);

        rewardsDuration = 30 days;

    }

    /* ========== VIEWS ========== */

    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function lastTimeRewardApplicable() public view override returns (uint256) {
        return Math.min(block.timestamp, periodFinish);
    }

    function rewardPerToken() public view override returns (uint256) {
        if (_totalSupply == 0) {
            return rewardPerTokenStored;
        }
        return
            rewardPerTokenStored.add(
                lastTimeRewardApplicable().sub(lastUpdateTime).mul(rewardRate).mul(1e18).div(_totalSupply)
            );
    }

    function earned(address account) public view override returns (uint256) {
        return _balances[account].mul(rewardPerToken().sub(userRewardPerTokenPaid[account])).div(1e18).add(rewards[account]);
    }

    function getRewardForDuration() external view override returns (uint256) {
        return rewardRate.mul(rewardsDuration);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */
    function deposit(uint256 amount) external override nonReentrant updateReward(msg.sender) {
        require(amount > 0, "Cannot stake 0");

        stakingToken.safeTransferFrom(msg.sender, address(this), amount);

        _totalSupply = _totalSupply.add(amount);
        _balances[msg.sender] = _balances[msg.sender].add(amount);

        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) public override nonReentrant updateReward(msg.sender) {
        require(amount > 0, "Cannot withdraw 0");

        _totalSupply = _totalSupply.sub(amount);
        _balances[msg.sender] = _balances[msg.sender].sub(amount);

        stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function getReward() public override nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;

            uint256 rewardTotal = IERC20(rewardToken).balanceOf(address(this));
            if(rewardTotal >= reward){
              IERC20(rewardToken).safeTransfer(msg.sender, reward);
              emit RewardPaid(msg.sender, reward);
            }
        }
    }

    function notifyRewardAmount(uint256 reward) public onlyRewardsDistribution {
        IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), reward);
        _notifyRewardAmount(reward);

    }


    receive () external payable {}

    /* ========== RESTRICTED FUNCTIONS ========== */

    function _notifyRewardAmount(uint256 reward) internal updateReward(address(0)) {
        if (block.timestamp >= periodFinish) {
            rewardRate = reward.div(rewardsDuration);
        } else {
            uint256 remaining = periodFinish.sub(block.timestamp);
            uint256 leftover = remaining.mul(rewardRate);
            rewardRate = reward.add(leftover).div(rewardsDuration);
        }

        // Ensure the provided reward amount is not more than the balance in the contract.
        // This keeps the reward rate in the right range, preventing overflows due to
        // very high values of rewardRate in the earned and rewardsPerToken functions;
        // Reward + leftover must be less than 2^256 / 10^18 to avoid overflow.
        uint256 balance = IERC20(rewardToken).balanceOf(address(this));
        require(rewardRate <= balance.div(rewardsDuration), "Provided reward too high");

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp.add(rewardsDuration);
        emit RewardAdded(reward);
    }

    function addRewardsDistribution(address _distributor) public onlyOwner
    {
        rewardsDistributions[_distributor] = true;
        emit AddRewardsDistribution(_distributor);
    }

    function removeRewardsDistribution(address _distributor) public onlyOwner
    {
        rewardsDistributions[_distributor] = false;
        emit RemoveRewardsDistribution(_distributor);
    }

    function setRewardsDuration(uint256 _rewardsDuration) external onlyOwner {
        require(periodFinish == 0 || block.timestamp > periodFinish, "Reward duration can only be updated after the period ends");
        rewardsDuration = _rewardsDuration;
        emit RewardsDurationUpdated(rewardsDuration);
    }

    /* ========== SALVAGE PURPOSE ONLY ========== */

    function recoverToken(address _tokenAddress, uint256 _tokenAmount) external onlyOwner {
        require(_tokenAddress != address(stakingToken), "Cannot recover deposit token");
        IERC20(_tokenAddress).safeTransfer(msg.sender, _tokenAmount);
        emit Recovered(_tokenAddress, _tokenAmount);
    }

    /* ========== MODIFIERS ========== */

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    modifier onlyRewardsDistribution() {
        require(rewardsDistributions[msg.sender] , "Caller is not RewardsDistribution contract");
        _;
    }

    /* ========== EVENTS ========== */

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardsDurationUpdated(uint256 newDuration);
    event AddRewardsDistribution(address indexed distributor);
    event RemoveRewardsDistribution(address indexed distributor);
    event Recovered(address tokenAddress, uint256 tokenAmount);

}
