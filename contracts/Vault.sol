// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';
import '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import "@openzeppelin/contracts/access/Ownable.sol";

import './interfaces/IVault.sol';
import './interfaces/IYetiMaster.sol';
import "./interfaces/IPancakeRouter02.sol";

contract Vault is IVault, Ownable ,ReentrancyGuard {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  /// @notice xBlzd-busd lp address.
  address public override reserve;

  /// @notice address of yetimaster Vault contract.
  address public yetiMasterAddress;

  /// @notice Balance tracker of accounts who have deposited funds.
  mapping(address => uint256) balance;

  /// @notice Is SnowBank
  mapping(address => bool) snowBank;

  uint256 public pid;
  address public earnAddress; //xBlzd

  address private constant BUSD = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;
  address[] public earnToBusdPath;

  IPancakeRouter02 public constant ROUTER = IPancakeRouter02(0x10ED43C718714eb63d5aA57B78B54704E256024E);

  uint256 public constant deadline = 2 ** 256 - 1;

  event AddSnowBank(address indexed snowBank);
  event RemoveSnowBank(address indexed snowBank);

  constructor(
    address _reserve,
    address _yetiMasterAddress,
    uint256 _pid,
    address _earnAddress
  ) public {
    reserve = _reserve;
    yetiMasterAddress = _yetiMasterAddress;
    pid = _pid;
    earnAddress = _earnAddress;
    earnToBusdPath = [earnAddress, BUSD];
    _approveMax(reserve, _yetiMasterAddress);
    _approveMax(earnAddress, address(ROUTER));
    _approveMax(BUSD, address(ROUTER));
  }

  modifier onlySnowBank() {
      require(snowBank[msg.sender] , "Caller is not SnowBank Contract");
      _;
  }

  /// @notice Deposits reserve into savingsAccount.
  /// @dev It is part of Vault's interface.
  /// @param amount Value to be deposited.
  /// @return True if successful.
  function deposit(uint256 amount) external override onlySnowBank returns (bool) {
    require(amount > 0, 'Amount must be greater than 0');

    IERC20(reserve).safeTransferFrom(msg.sender, address(this), amount);
    balance[msg.sender] = balance[msg.sender].add(amount);

    _sendToSavings(amount);

    _compound();

    return true;
  }

  /// @notice Redeems reserve from savingsAccount.
  /// @dev It is part of Vault's interface.
  /// @param amount Value to be redeemed.
  /// @return True if successful.
  function redeem(uint256 amount) external override nonReentrant onlySnowBank returns (bool) {
    require(amount > 0, 'Amount must be greater than 0');
    require(amount <= balance[msg.sender], 'Not enough funds');

    balance[msg.sender] = balance[msg.sender].sub(amount);

    _redeemFromSavings(msg.sender, amount);

    _compound();

    return true;
  }

  function compound() external override nonReentrant {
      _compound();
  }

  /// @notice Returns balance in reserve from the savings contract.
  /// @dev It is part of Vault's interface.
  /// @return _balance Reserve amount in the savings contract.
  function getBalance() public override view returns (uint256 _balance) {
    (uint256 totalBal, ) = IYetiMaster(yetiMasterAddress).userInfo(pid, address(this));
    _balance = totalBal;
  }

  function _compound() internal {

    // harvest
    IYetiMaster(yetiMasterAddress).deposit(pid, 0);
    uint256 reward = IERC20(earnAddress).balanceOf(address(this));

    if(reward > 0){

      _safeSwap(
          address(ROUTER),
          reward.div(2),
          950,
          earnToBusdPath,
          address(this),
          deadline
      );

      _safeAddLiquidity();
    }

    uint256 compLP = IERC20(reserve).balanceOf(address(this));
    if(compLP > 0){
      IYetiMaster(yetiMasterAddress).deposit(pid, compLP);
    }

  }

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
    uint256 token0Amt = IERC20(earnAddress).balanceOf(address(this));
    uint256 token1Amt = IERC20(BUSD).balanceOf(address(this));

    if (token0Amt > 0 && token1Amt > 0) {
        ROUTER.addLiquidity(
            earnAddress,
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

  function _approveMax(address token, address spender) internal {
    uint256 max = uint256(-1);
    IERC20(token).safeApprove(spender, max);
  }

  // @notice Worker function to send funds to savings account.
  // @param _amount The amount to send.
  function _sendToSavings(uint256 _amount) internal {
    if (IERC20(reserve).allowance(address(this), yetiMasterAddress) < _amount) {
      _approveMax(reserve, yetiMasterAddress);
    }

    IYetiMaster(yetiMasterAddress).deposit(pid, _amount);
  }

  // @notice Worker function to redeems funds from savings account.
  // @param _account The account to redeem to.
  // @param _amount The amount to redeem.
  function _redeemFromSavings(address _account, uint256 _amount) internal {

    (uint256 totalBal, ) = IYetiMaster(yetiMasterAddress).userInfo(pid, address(this));
    uint256 shareAmount = _amount.mul(totalBal).div(balance[msg.sender]);

    IYetiMaster(yetiMasterAddress).withdraw(pid, shareAmount);
    IERC20(reserve).safeTransfer(_account, IERC20(reserve).balanceOf(address(this)));
  }

 function addSnowBank(address _snowBank) public onlyOwner {
    snowBank[_snowBank] = true;
    emit AddSnowBank(_snowBank);
  }

  function removeSnowBank(address _snowBank) public onlyOwner {
    snowBank[_snowBank] = false;
    emit RemoveSnowBank(_snowBank);
  }

}
