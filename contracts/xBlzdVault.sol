// SPDX-License-Identifier: MIT

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';

import './interfaces/IYetiMaster.sol';

pragma solidity 0.6.12;

contract xBlzdVault is Ownable, Pausable {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    struct UserInfo {
        uint256 shares; // number of shares for a user
        uint256 xBlzdAtLastUserAction; // keeps track of xBlzd deposited at the last user action
    }

    IERC20 public immutable token; // xBlzd token

    IYetiMaster public immutable yetiMaster;
    uint256 public pid;

    mapping(address => UserInfo) public userInfo;

    uint256 public totalShares;
    uint256 public lastHarvestedTime;
    address public admin;
    address public treasury; // bot

    uint256 public constant MAX_CALL_FEE = 500; // 5%
    uint256 public callFee = 150; // 1.5%

    event Deposit(address indexed sender, uint256 amount, uint256 shares);
    event Withdraw(address indexed sender, uint256 amount, uint256 shares);
    event Harvest(address indexed sender, uint256 callFee);
    event Pause();
    event Unpause();

    event AdminSet(address admin);
    event TreasurySet(address treasury);
    event CallFeeSet(uint256 callFee);
    event InCaseTokensGetStuck(address token);

    /**
     * @notice Constructor
     * @param _token: xBlzd token contract
     * @param _yetiMaster: YetiMaster contract
     * @param _admin: address of the admin
     * @param _treasury: address of the treasury (collects fees)
     */
    constructor(
        IERC20 _token,
        address _yetiMaster,
        uint256 _pid,
        address _admin,
        address _treasury
    ) public {
        token = _token;
        yetiMaster = IYetiMaster(_yetiMaster);
        pid = _pid;
        admin = _admin;
        treasury = _treasury;

        // Infinite approve
        IERC20(_token).safeApprove(_yetiMaster, uint256(-1));
    }

    /**
     * @notice Checks if the msg.sender is the admin address
     */
    modifier onlyAdmin() {
        require(msg.sender == admin, "admin: wut?");
        _;
    }

    /**
     * @notice Checks if the msg.sender is a contract or a proxy
     */
    modifier notContract() {
        require(!_isContract(msg.sender), "contract not allowed");
        require(msg.sender == tx.origin, "proxy contract not allowed");
        _;
    }

    /**
     * @notice Deposits funds into the xBlzd Vault
     * @dev Only possible when contract not paused.
     * @param _amount: number of tokens to deposit (in xBlzd)
     */
    function deposit(uint256 _amount) external whenNotPaused notContract {
        require(_amount > 0, "Nothing to deposit");

        uint256 pool = balanceOf();
        token.safeTransferFrom(msg.sender, address(this), _amount);

        uint256 currentShares = 0;
        if (totalShares != 0) {
            currentShares = (_amount.mul(totalShares)).div(pool);
        } else {
            currentShares = _amount;
        }
        UserInfo storage user = userInfo[msg.sender];

        user.shares = user.shares.add(currentShares);

        totalShares = totalShares.add(currentShares);

        user.xBlzdAtLastUserAction = user.shares.mul(balanceOf()).div(totalShares);

        _earn();

        emit Deposit(msg.sender, _amount, currentShares);
    }

    /**
     * @notice Withdraws all funds for a user
     */
    function withdrawAll() external notContract {
        withdraw(userInfo[msg.sender].shares);
    }

    /**
     * @notice Reinvests xBlzd tokens into yetiMaster
     * @dev Only possible when contract not paused.
     */
    function harvest() external notContract whenNotPaused {
        // get reward
        uint256 balBefore = available();
        IYetiMaster(yetiMaster).withdraw(pid, 0);
        uint256 bal = available().sub(balBefore);

        uint256 currentCallFee = bal.mul(callFee).div(10000);
        token.safeTransfer(treasury, currentCallFee);

        _earn();

        lastHarvestedTime = block.timestamp;

        emit Harvest(msg.sender, currentCallFee);
    }

    /**
     * @notice Sets admin address
     * @dev Only callable by the contract owner.
     */
    function setAdmin(address _admin) external onlyOwner {
        require(_admin != address(0), "Cannot be zero address");
        admin = _admin;
        emit AdminSet(_admin);
    }

    /**
     * @notice Sets treasury address
     * @dev Only callable by the contract owner.
     */
    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "Cannot be zero address");
        treasury = _treasury;
        emit TreasurySet(_treasury);
    }

    /**
     * @notice Sets call fee
     * @dev Only callable by the contract admin.
     */
    function setCallFee(uint256 _callFee) external onlyAdmin {
        require(_callFee <= MAX_CALL_FEE, "callFee cannot be more than MAX_CALL_FEE");
        callFee = _callFee;
        emit CallFeeSet(_callFee);
    }

    /**
     * @notice Withdraw unexpected tokens sent to the xBlzd Vault
     */
    function inCaseTokensGetStuck(address _token) external onlyAdmin {
        require(_token != address(token), "Token cannot be same as deposit token");

        uint256 amount = IERC20(_token).balanceOf(address(this));
        IERC20(_token).safeTransfer(msg.sender, amount);
        emit InCaseTokensGetStuck(_token);
    }

    /**
     * @notice Triggers stopped state
     * @dev Only possible when contract not paused.
     */
    function pause() external onlyAdmin whenNotPaused {
        _pause();
        emit Pause();
    }

    /**
     * @notice Returns to normal state
     * @dev Only possible when contract is paused.
     */
    function unpause() external onlyAdmin whenPaused {
        _unpause();
        emit Unpause();
    }

    /**
     * @notice Calculates the expected harvest reward from third party
     * @return Expected reward to collect in xBlzd
     */
    function calculateHarvestXBlzdRewards() external view returns (uint256) {
        uint256 amount = IYetiMaster(yetiMaster).pendingxBLZD(0, address(this));
        amount = amount.add(available());
        uint256 currentCallFee = amount.mul(callFee).div(10000);

        return currentCallFee;
    }

    /**
     * @notice Calculates the total pending rewards that can be restaked
     * @return Returns total pending xBlzd rewards
     */
    function calculateTotalPendingXBlzdRewards() external view returns (uint256) {
        uint256 amount = IYetiMaster(yetiMaster).pendingxBLZD(0, address(this));
        amount = amount.add(available());

        return amount;
    }

    /**
     * @notice Calculates the price per share
     */
    function getPricePerFullShare() external view returns (uint256) {
        return totalShares == 0 ? 1e18 : balanceOf().mul(1e18).div(totalShares);
    }

    /**
     * @notice Withdraws from funds from the xBlzd Vault
     * @param _shares: Number of shares to withdraw
     */
    function withdraw(uint256 _shares) public notContract {
        UserInfo storage user = userInfo[msg.sender];
        require(_shares > 0, "Nothing to withdraw");
        require(_shares <= user.shares, "Withdraw amount exceeds balance");

        uint256 currentAmount = (balanceOf().mul(_shares)).div(totalShares);
        user.shares = user.shares.sub(_shares);
        totalShares = totalShares.sub(_shares);

        uint256 bal = available();
        if (bal < currentAmount) {
            uint256 balWithdraw = currentAmount.sub(bal);
            IYetiMaster(yetiMaster).withdraw(pid, balWithdraw);
            currentAmount = available();
        }

        if (user.shares > 0) {
            user.xBlzdAtLastUserAction = user.shares.mul(balanceOf()).div(totalShares);
        } else {
            user.xBlzdAtLastUserAction = 0;
        }

        token.safeTransfer(msg.sender, currentAmount);

        emit Withdraw(msg.sender, currentAmount, _shares);
    }

    /**
     * @notice Custom logic for how much the vault allows to be borrowed
     * @dev The contract puts 100% of the tokens to work.
     */
    function available() public view returns (uint256) {
        return token.balanceOf(address(this));
    }

    /**
     * @notice Calculates the total underlying tokens
     * @dev It includes tokens held by the contract and held in yetiMaster
     */
    function balanceOf() public view returns (uint256) {
        (uint256 amount, ) = IYetiMaster(yetiMaster).userInfo(pid, address(this));
        return token.balanceOf(address(this)).add(amount);
    }

    /**
     * @notice Deposits tokens into yetiMaster to earn staking rewards
     */
    function _earn() internal {
        uint256 bal = available();
        if (bal > 0) {
            IYetiMaster(yetiMaster).deposit(pid, bal);
        }
    }

    /**
     * @notice Checks if address is a contract
     * @dev It prevents contract from being targetted
     */
    function _isContract(address addr) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(addr)
        }
        return size > 0;
    }
}
