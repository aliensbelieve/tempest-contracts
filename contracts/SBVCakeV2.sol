// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

// Inheritance
import "./interfaces/IMasterChef.sol";
import "./interfaces/IStakingRewards.sol";
import "./interfaces/IPancakeRouter02.sol";
import "./interfaces/IBank.sol";
import "./interfaces/ISnowBank.sol";

contract SBVCakeV2 is IStakingRewards, Ownable , ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    /* ========== CONSTANTS ============= */
    // team 1.5%
    // each 1.5%
    address public constant teamYetiA = 0xCe059E8af96a654d4afe630Fa325FBF70043Ab11;
    address public constant teamYetiB = 0x1EE101AC64BcE7F6DD85C0Ad300C4BBC2cc8272B;

    // deposit fee
    address public constant blizzardPool = 0x2Dcf7FB5F83594bBD13C781f5b8b2a9F55a4cdbb;

    IMasterChef public constant CAKE_MASTER_CHEF = IMasterChef(0x73feaa1eE314F8c655E354234017bE2193C9E24E);
    address private constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;
    address private constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address private constant BUSD = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;
    address private constant xBLZD = 0x9a946c3Cb16c08334b69aE249690C236Ebd5583E;
    address[] public busdToBnbPath = [BUSD,WBNB];
    address[] public cakeToBusdPath = [CAKE,WBNB,BUSD];
    address[] public cakeToXBlzdPath = [CAKE,WBNB,BUSD,xBLZD];

    IPancakeRouter02 public constant ROUTER = IPancakeRouter02(0x10ED43C718714eb63d5aA57B78B54704E256024E);

    /* ========== STATE VARIABLES ========== */

    IERC20 public immutable stakingToken;

    // Reward ID 0 TEMPEST 1 GALE
    address public immutable TEMPEST;
    address public immutable GALE;
    address public immutable snowBankGALE;
    address public immutable snowBankTEMP;
    address public immutable xBLZDBusdLP;

    mapping(uint256 => uint256) public rewardRate;
    mapping(uint256 => uint256) public rewardPerTokenStored;
    mapping(uint256 => uint256) public rewardsDuration;

    mapping(uint256 => uint256) public lastUpdateTime;
    mapping(uint256 => uint256) public periodFinish;

    uint256 public pid;

    mapping(uint256 => mapping(address => uint256)) public userRewardPerTokenPaid;
    mapping(uint256 => mapping(address => uint256)) public rewards;


    uint256 private _totalSupply;

    mapping (address => bool) public whitelisted;

    mapping (address => bool) public rewardsDistributions;

    mapping(address => uint256) private _balances;

    bool public emergencyStop;

    uint256 public constant deadline = 2 ** 256 - 1;

    uint256 public slippageFactor = 950;

    /* ========== CONSTRUCTOR ========== */

    constructor(
        uint256 _pid,
        address _snowBankGale,
        address _snowBankTemp,
        address _xBLZDBusdLP,
        address _GALE
    ) public {
        (address _stakingToken,,,) = CAKE_MASTER_CHEF.poolInfo(_pid);

        pid = _pid;

        snowBankGALE = _snowBankGale;
        snowBankTEMP = _snowBankTemp;

        GALE = _GALE;
        TEMPEST = ISnowBank(_snowBankTemp).tempest();
        xBLZDBusdLP = _xBLZDBusdLP;

        IERC20(_stakingToken).safeApprove(address(CAKE_MASTER_CHEF), uint256(-1));
        stakingToken = IERC20(_stakingToken);

        IERC20(CAKE).safeApprove(address(ROUTER), uint256(-1));
        IERC20(xBLZD).safeApprove(address(ROUTER), uint256(-1));
        IERC20(BUSD).safeApprove(address(ROUTER), uint256(-1));
        IERC20(BUSD).safeApprove(address(_snowBankGale), uint256(-1));
        IERC20(_xBLZDBusdLP).safeApprove(address(_snowBankTemp), uint256(-1));

        rewardsDuration[0] = 4 hours;
        rewardsDuration[1] = 4 hours;

    }

    /* ========== VIEWS ========== */

    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function lastTimeRewardApplicable(uint256 rewardId) public view override returns (uint256) {
        return Math.min(block.timestamp, periodFinish[rewardId]);
    }

    function rewardPerToken(uint256 rewardId) public view override returns (uint256) {
        if (_totalSupply == 0) {
            return rewardPerTokenStored[rewardId];
        }
        return
            rewardPerTokenStored[rewardId].add(
                lastTimeRewardApplicable(rewardId).sub(lastUpdateTime[rewardId]).mul(rewardRate[rewardId]).mul(1e18).div(_totalSupply)
            );
    }

    function earned(address account,uint256 rewardId) public view override returns (uint256) {
        return _balances[account].mul(rewardPerToken(rewardId).sub(userRewardPerTokenPaid[rewardId][account])).div(1e18).add(rewards[rewardId][account]);
    }

    function getRewardForDuration(uint256 rewardId) external view override returns (uint256) {
        return rewardRate[rewardId].mul(rewardsDuration[rewardId]);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */
    function stake(uint256 amount) external override nonReentrant
     updateReward(msg.sender,0)
     updateReward(msg.sender,1)
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
        CAKE_MASTER_CHEF.deposit(pid, amounAfterFee);
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) public override nonReentrant updateReward(msg.sender,0) updateReward(msg.sender,1) {
        require(amount > 0, "Cannot withdraw 0");
        _totalSupply = _totalSupply.sub(amount);
        _balances[msg.sender] = _balances[msg.sender].sub(amount);
        if(emergencyStop != true){
            CAKE_MASTER_CHEF.withdraw(pid, amount);
        }
        stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function getReward(uint256 rewardId) public override nonReentrant updateReward(msg.sender,rewardId) {
        require(rewardId <= 1 ,"wrong rewardId");
        uint256 reward = rewards[rewardId][msg.sender];
        if (reward > 0) {
            rewards[rewardId][msg.sender] = 0;
            IERC20 rewardsToken;
            if(rewardId  == 0){
                rewardsToken = IERC20(TEMPEST);
            }
            else {
                rewardsToken = IERC20(GALE);
            }

            rewardsToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward , rewardId);
        }
    }

    function exit(uint256 amount) external override {
        withdraw(amount);
        getAllReward();
    }

    function getAllReward() public override {
        getReward(0);
        getReward(1);
    }

    function harvest() public onlyRewardsDistribution isNotEmergencyStop {
        CAKE_MASTER_CHEF.withdraw(pid, 0);
        _harvest();
    }

    function notifyRewardAmount(uint256 reward,uint256 rewardId) public onlyRewardsDistribution {
        IERC20 rewardsToken;
        if(rewardId  == 0){
            rewardsToken = IERC20(TEMPEST);
        }
        else {
            rewardsToken = IERC20(GALE);
        }

        IERC20(rewardsToken).safeTransferFrom(msg.sender, address(this), reward);
        _notifyRewardAmount(reward,rewardId);
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
      uint256 token0Amt = IERC20(xBLZD).balanceOf(address(this));
      uint256 token1Amt = IERC20(BUSD).balanceOf(address(this));

      if (token0Amt > 0 && token1Amt > 0) {
          ROUTER.addLiquidity(
              xBLZD,
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

        uint256 cakeAmount = IERC20(CAKE).balanceOf(address(this));

        // 47% for TEMPEST
        uint256 cakeAmountForTEMPEST = cakeAmount.mul(470).div(1000);
        if(cakeAmountForTEMPEST > 0){
          // 50% for XBLZD
          _safeSwap(
              address(ROUTER),
              cakeAmountForTEMPEST.div(2),
              slippageFactor,
              cakeToBusdPath,
              address(this),
              deadline
          );

          // 50% for BUSD
          _safeSwap(
              address(ROUTER),
              cakeAmountForTEMPEST.div(2),
              slippageFactor,
              cakeToXBlzdPath,
              address(this),
              deadline
          );
        }
        // addLiquidity for XBLZD-BUSD
        _safeAddLiquidity();
        uint256 TempestBefore = IERC20(TEMPEST).balanceOf(address(this));
        // invest to snowbank for get TEMPEST
        ISnowBank(snowBankTEMP).invest(IERC20(xBLZDBusdLP).balanceOf(address(this)));
        uint256 amountTempest = IERC20(TEMPEST).balanceOf(address(this)).sub(TempestBefore);

        if (amountTempest > 0) {
          _notifyRewardAmount(amountTempest, 0);
        }

        // 47% for GALE
        uint256 cakeAmountForGALE = cakeAmount.mul(470).div(1000);
        if(cakeAmountForGALE > 0){
          // for BUSD
          _safeSwap(
              address(ROUTER),
              cakeAmountForGALE,
              slippageFactor,
              cakeToBusdPath,
              address(this),
              deadline
          );
        }
        uint256 GaleBefore = IERC20(GALE).balanceOf(address(this));
        // invest to snowbank for get GALE
        ISnowBank(snowBankGALE).invest(IERC20(BUSD).balanceOf(address(this)));
        uint256 amountGALE = IERC20(GALE).balanceOf(address(this)).sub(GaleBefore);

        if (amountGALE > 0) {
          _notifyRewardAmount(amountGALE, 1);
        }

        // 3% for Pool#1
        uint256 busdBlizzardPool = cakeAmount.mul(30).div(1000);
        if(busdBlizzardPool > 0){
          // for BUSD
          _safeSwap(
              address(ROUTER),
              busdBlizzardPool,
              slippageFactor,
              cakeToBusdPath,
              address(this),
              deadline
          );
        }
        uint256 busdForPool = IERC20(BUSD).balanceOf(address(this));
        IERC20(BUSD).safeTransfer(blizzardPool, busdForPool);

        // 1.5% to bot + 1.5% to team
        uint256 busdTeamBot = cakeAmount.sub(cakeAmountForTEMPEST).sub(cakeAmountForGALE).sub(busdBlizzardPool);
        uint256 beforeTeamBot = IERC20(BUSD).balanceOf(address(this));
        if(busdTeamBot > 0){
          // for BUSD
          _safeSwap(
              address(ROUTER),
              busdTeamBot,
              slippageFactor,
              cakeToBusdPath,
              address(this),
              deadline
          );
        }

        uint256 tokenTeam = (IERC20(BUSD).balanceOf(address(this))).sub(beforeTeamBot);
        uint256 halfTeam = tokenTeam.div(2);
        IERC20(BUSD).safeTransfer(teamYetiA, halfTeam.div(2)); // teamA
        IERC20(BUSD).safeTransfer(teamYetiB, halfTeam.sub(halfTeam.div(2))); // teamB

        uint256 gasBefore = IERC20(WBNB).balanceOf(address(this));
        if(tokenTeam.sub(halfTeam) > 0){
          // bnb for gas
          _safeSwap(
              address(ROUTER),
              tokenTeam.sub(halfTeam),
              slippageFactor,
              busdToBnbPath,
              address(this),
              deadline
          );
        }

        IERC20(WBNB).safeTransfer(msg.sender, (IERC20(WBNB).balanceOf(address(this))).sub(gasBefore)); // bot

        emit Harvested(cakeAmount);
    }

    function _notifyRewardAmount(uint256 reward,uint256 rewardId) internal updateReward(address(0),rewardId) {
        require(rewardId <= 1 ,"wrong reward id");
        if (block.timestamp >= periodFinish[rewardId]) {
            rewardRate[rewardId] = reward.div(rewardsDuration[rewardId]);
        } else {
            uint256 remaining = periodFinish[rewardId].sub(block.timestamp);
            uint256 leftover = remaining.mul(rewardRate[rewardId]);
            rewardRate[rewardId] = reward.add(leftover).div(rewardsDuration[rewardId]);
        }

        // Ensure the provided reward amount is not more than the balance in the contract.
        // This keeps the reward rate in the right range, preventing overflows due to
        // very high values of rewardRate in the earned and rewardsPerToken functions;
        // Reward + leftover must be less than 2^256 / 10^18 to avoid overflow.
        IERC20 rewardsToken;
        if(rewardId  == 0){
            rewardsToken = IERC20(TEMPEST);
        }
        else {
            rewardsToken = IERC20(GALE);
        }
        uint256 balance = rewardsToken.balanceOf(address(this));
        require(rewardRate[rewardId] <= balance.div(rewardsDuration[rewardId]), "Provided reward too high");

        lastUpdateTime[rewardId] = block.timestamp;
        periodFinish[rewardId] = block.timestamp.add(rewardsDuration[rewardId]);
        emit RewardAdded(reward,rewardId);
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

    function setRewardsDuration(uint256 _rewardsDuration,uint256 rewardId) external onlyOwner {
        require(periodFinish[rewardId] == 0 || block.timestamp > periodFinish[rewardId], "Reward duration can only be updated after the period ends");
        rewardsDuration[rewardId] = _rewardsDuration;
        emit RewardsDurationUpdated(rewardsDuration[rewardId],rewardId);
    }

    function panic() public onlyOwner {
        emergencyStop = true;
        CAKE_MASTER_CHEF.emergencyWithdraw(pid);
        emit EmergencyWithdrawLp(emergencyStop);
    }

    /* ========== MODIFIERS ========== */

    modifier updateReward(address account,uint256 rewardId) {
        rewardPerTokenStored[rewardId] = rewardPerToken(rewardId);
        lastUpdateTime[rewardId] = lastTimeRewardApplicable(rewardId);
        if (account != address(0)) {
            rewards[rewardId][account] = earned(account,rewardId);
            userRewardPerTokenPaid[rewardId][account] = rewardPerTokenStored[rewardId];
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

    event RewardAdded(uint256 reward,uint256 rewardId);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward ,uint256 rewardId);
    event Harvested(uint256 amount);
    event RewardsDurationUpdated(uint256 newDuration,uint256 rewardId);
    event AddRewardsDistribution(address indexed distributor);
    event RemoveRewardsDistribution(address indexed distributor);
    event AddWhiteListAddress(address indexed whitelistAddress);
    event RemoveWhiteListAddress(address indexed whitelistAddress);
    event EmergencyWithdrawLp(bool _emergencyStop);

}
