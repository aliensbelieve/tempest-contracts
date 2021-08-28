// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

interface IYetiMaster {

    function add(
        uint256 _allocPoint,
        address _want,
        bool _withUpdate,
        address _strat,
        uint16 _depositFeeBP
    ) external;

    function xBLZD() external view returns (address);

    function deposit(uint256 _pid,uint256 _wantAmt) external;

    function withdraw(uint256 _pid, uint256 _wantAmt) external;

    function emergencyWithdraw(uint256 _pid) external;

    function userInfo(uint256 _pid, address _account) view external returns(uint256 amount, uint256 rewardDebt);

    function pendingxBLZD(uint256 _pid, address _user) external view returns (uint256);

}
