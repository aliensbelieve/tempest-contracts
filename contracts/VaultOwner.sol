// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

import './interfaces/IYetiMaster.sol';
import './xBlzdVault.sol';

contract VaultOwner is Ownable {
    using SafeERC20 for IERC20;

    xBlzdVault public immutable xBLZDvault;

    constructor(address _xBLZDvaultAddress) public {
        xBLZDvault = xBlzdVault(_xBLZDvaultAddress);
    }

    /**
     * @notice Sets admin address to this address
     * @dev Only callable by the contract owner.
     * It makes the admin == owner.
     */
    function setAdmin() external onlyOwner {
        xBLZDvault.setAdmin(address(this));
    }

    /**
     * @notice Sets treasury address
     * @dev Only callable by the contract owner.
     */
    function setTreasury(address _treasury) external onlyOwner {
        xBLZDvault.setTreasury(_treasury);
    }

    /**
     * @notice Sets call fee
     * @dev Only callable by the contract owner.
     */
    function setCallFee(uint256 _callFee) external onlyOwner {
        xBLZDvault.setCallFee(_callFee);
    }

    /**
     * @notice Withdraw unexpected tokens sent to the Cake Vault
     */
    function inCaseTokensGetStuck(address _token) external onlyOwner {
        xBLZDvault.inCaseTokensGetStuck(_token);
        uint256 amount = IERC20(_token).balanceOf(address(this));
        IERC20(_token).safeTransfer(msg.sender, amount);
    }

    /**
     * @notice Triggers stopped state
     * @dev Only possible when contract not paused.
     */
    function pause() external onlyOwner {
        xBLZDvault.pause();
    }

    /**
     * @notice Returns to normal state
     * @dev Only possible when contract is paused.
     */
    function unpause() external onlyOwner {
        xBLZDvault.unpause();
    }
}
