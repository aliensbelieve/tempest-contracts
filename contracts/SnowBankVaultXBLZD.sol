// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

// Inheritance
import "./interfaces/IStakingReward.sol";
import "./interfaces/IPancakeRouter02.sol";
import "./interfaces/IBank.sol";
import "./interfaces/ISnowBank.sol";
import "./interfaces/IYetiMaster.sol";

contract SnowBankVaultXBLZD is IStakingReward, Ownable , ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    /* ========== CONSTANTS ============= */

    // team 1.5%
    // each 0.75%
    address private constant teamYetiA = 0xCe059E8af96a654d4afe630Fa325FBF70043Ab11;
    address private constant teamYetiB = 0x1EE101AC64BcE7F6DD85C0Ad300C4BBC2cc8272B;

    // 3% BUSD
    address private constant blizzardPool = 0x2Dcf7FB5F83594bBD13C781f5b8b2a9F55a4cdbb;

    IYetiMaster private constant YETIMASTER = IYetiMaster(0x367CdDA266ADa588d380C7B970244434e4Dde790);
    address private constant XBLZD = 0x9a946c3Cb16c08334b69aE249690C236Ebd5583E;
    address private constant BUSD = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;
    address private constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address[] public xBLZDToBusdPath = [XBLZD,BUSD];
    address[] public xBLZDToWbnbPath = [XBLZD,BUSD,WBNB];
    uint256 public slippageFactor = 950;

    IPancakeRouter02 public constant ROUTER = IPancakeRouter02(0x10ED43C718714eb63d5aA57B78B54704E256024E);

    /* ========== STATE VARIABLES ========== */

    IERC20 public immutable stakingToken;

    address public immutable TEMPEST;
    address public immutable snowBank;

    uint256 public rewardRate;
    uint256 public rewardPerTokenStored;
    uint256 public rewardsDuration;

    uint256 public lastUpdateTime;
    uint256 public periodFinish;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;


    uint256 private _totalSupply;

    mapping (address => bool) public whitelisted;

    mapping (address => bool) public rewardsDistributions;

    mapping(address => uint256) private _balances;

    bool public emergencyStop;
    uint256 public pid;

    uint256 public constant deadline = 2 ** 256 - 1;

    /* ========== CONSTRUCTOR ========== */

    constructor(
        uint256 _pid,
        address _snowBank,
        address _stakingToken
    ) public {

        pid = _pid;

        snowBank = _snowBank;

        TEMPEST = ISnowBank(_snowBank).tempest();

        IERC20(_stakingToken).safeApprove(address(YETIMASTER), uint256(-1));

        stakingToken = IERC20(_stakingToken);

        IERC20(XBLZD).safeApprove(address(ROUTER), uint256(-1));
        IERC20(BUSD).safeApprove(address(ROUTER), uint256(-1));
        IERC20(_stakingToken).safeApprove(address(_snowBank), uint256(-1));

        rewardsDuration = 4 hours;
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
    function stake(uint256 amount) external override nonReentrant updateReward(msg.sender)
     onlyWhitelistOrEOA
     isNotEmergencyStop
     {
        require(amount > 0, "Cannot stake 0");
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
         // fee 0.1% go to blizzardPool
        uint256 depositFee = amount.div(1000);
        stakingToken.safeTransfer(blizzardPool, depositFee);
        uint256 amounAfterFee =  amount.sub(depositFee);
        _totalSupply = _totalSupply.add(amounAfterFee);
        _balances[msg.sender] = _balances[msg.sender].add(amounAfterFee);
        YETIMASTER.deposit(pid, amounAfterFee);
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) public override nonReentrant updateReward(msg.sender) {
        require(amount > 0, "Cannot withdraw 0");
        _totalSupply = _totalSupply.sub(amount);
        _balances[msg.sender] = _balances[msg.sender].sub(amount);
        if(emergencyStop != true){
            YETIMASTER.withdraw(pid, amount);
        }
        stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function getReward() public override nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            IERC20 rewardsToken = IERC20(TEMPEST);

            rewardsToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function exit(uint256 amount) external override {
        withdraw(amount);
        getReward();
    }

    function harvest() public onlyRewardsDistribution isNotEmergencyStop {
        // harvest reward from yeti
        YETIMASTER.deposit(pid, 0);

        _harvest();
    }

    function notifyRewardAmount(uint256 reward) public onlyRewardsDistribution {
        IERC20 rewardsToken = IERC20(TEMPEST);

        IERC20(rewardsToken).safeTransferFrom(msg.sender, address(this), reward);
        _notifyRewardAmount(reward);
    }


    receive () external payable {}

    /* ========== RESTRICTED FUNCTIONS ========== */

    function _safeSwap(
        address _uniRouterAddress,
        uint256 _amountIn,
        uint256 _slippageFactor,
        address[] memory _path,
        address _to,
        uint256 _deadline
    ) internal virtual {
        uint256[] memory amounts =
            IPancakeRouter02(_uniRouterAddress).getAmountsOut(_amountIn, _path);
        uint256 amountOut = amounts[amounts.length.sub(1)];

        IPancakeRouter02(_uniRouterAddress)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(
            _amountIn,
            amountOut.mul(_slippageFactor).div(1000),
            _path,
            _to,
            _deadline
        );
    }

    function _safeAddLiquidity() internal virtual {
      // Get want tokens, ie. add liquidity
      uint256 token0Amt = IERC20(XBLZD).balanceOf(address(this));
      uint256 token1Amt = IERC20(BUSD).balanceOf(address(this));

      if (token0Amt > 0 && token1Amt > 0) {
          ROUTER.addLiquidity(
              XBLZD,
              BUSD,
              token0Amt,
              token1Amt,
              0,
              0,
              address(this),
              deadline
          );
      }

    }


    function _harvest() private {

        uint256 xBLZDAmount = IERC20(XBLZD).balanceOf(address(this));

        // 98.5% swap to XBLZD-BUSD
        uint256 xBLZDForTEMPEST = xBLZDAmount.mul(985).div(1000);

        // swap 50% of xBLZDForTEMPEST to busd
        if(xBLZDForTEMPEST > 0){
          _safeSwap(
              address(ROUTER),
              xBLZDForTEMPEST.div(2),
              slippageFactor,
              xBLZDToBusdPath,
              address(this),
              deadline
          );
        }

        uint256 lpForTEMPESTBefore = IERC20(stakingToken).balanceOf(address(this));
        // addLiquidity for XBLZD-BUSD
        _safeAddLiquidity();
        uint256 lpForTEMPEST = IERC20(stakingToken).balanceOf(address(this)).sub(lpForTEMPESTBefore);

        uint256 TempestBefore = IERC20(TEMPEST).balanceOf(address(this));
        // invest to snowbank for get TEMPEST
        ISnowBank(snowBank).invest(lpForTEMPEST);
        uint256 amountTempest = IERC20(TEMPEST).balanceOf(address(this)).sub(TempestBefore);

        if (amountTempest > 0) {
          _notifyRewardAmount(amountTempest);
        }

        // remaining go to bot 1.5%
        uint256 gasBefore = IERC20(WBNB).balanceOf(address(this));
        if(xBLZDAmount.sub(xBLZDForTEMPEST) > 0){
          _safeSwap(
              address(ROUTER),
              xBLZDAmount.sub(xBLZDForTEMPEST),
              slippageFactor,
              xBLZDToWbnbPath,
              address(this),
              deadline
          );
        }
        IERC20(WBNB).transfer(msg.sender,
            (IERC20(WBNB).balanceOf(address(this))).sub(gasBefore)
        );

        emit Harvested(xBLZDAmount);
    }

    function _notifyRewardAmount(uint256 reward) internal updateReward(address(0)) {
        if (block.timestamp >= periodFinish) {
            rewardRate= reward.div(rewardsDuration);
        } else {
            uint256 remaining = periodFinish.sub(block.timestamp);
            uint256 leftover = remaining.mul(rewardRate);
            rewardRate = reward.add(leftover).div(rewardsDuration);
        }

        // Ensure the provided reward amount is not more than the balance in the contract.
        // This keeps the reward rate in the right range, preventing overflows due to
        // very high values of rewardRate in the earned and rewardsPerToken functions;
        // Reward + leftover must be less than 2^256 / 10^18 to avoid overflow.
        IERC20 rewardsToken = IERC20(TEMPEST);

        uint256 balance = rewardsToken.balanceOf(address(this));
        require(rewardRate <= balance.div(rewardsDuration), "Provided reward too high");

        lastUpdateTime= block.timestamp;
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

    function addWhiteList(address _whitelistAddress) public onlyOwner
    {
        whitelisted[_whitelistAddress] = true;
        emit AddWhiteListAddress(_whitelistAddress);
    }

    function removeWhiteList(address _whitelistAddress) public onlyOwner
    {
        whitelisted[_whitelistAddress] = false;
        emit RemoveWhiteListAddress(_whitelistAddress);
    }

    function setRewardsDuration(uint256 _rewardsDuration) external onlyOwner {
        require(periodFinish == 0 || block.timestamp > periodFinish, "Reward duration can only be updated after the period ends");
        rewardsDuration = _rewardsDuration;
        emit RewardsDurationUpdated(rewardsDuration);
    }

    function panic() public onlyOwner {
        emergencyStop = true;
        YETIMASTER.emergencyWithdraw(pid);
        emit EmergencyWithdrawLp(emergencyStop);
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

    modifier onlyWhitelistOrEOA() {
        require(msg.sender == tx.origin || whitelisted[msg.sender] , "Caller is not EOA or whitelisted contract");
        _;
    }

    modifier isNotEmergencyStop() {
        require(!emergencyStop , "Emergency Stop");
        _;
    }

    /* ========== EVENTS ========== */

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event Harvested(uint256 amount);
    event RewardsDurationUpdated(uint256 newDuration);
    event AddRewardsDistribution(address indexed distributor);
    event RemoveRewardsDistribution(address indexed distributor);
    event AddWhiteListAddress(address indexed whitelistAddress);
    event RemoveWhiteListAddress(address indexed whitelistAddress);
    event EmergencyWithdrawLp(bool _emergencyStop);

}
