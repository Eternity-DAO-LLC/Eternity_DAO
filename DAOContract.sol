// SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;

// @title RetireDAO 1.0
// @Dev Ethernity - DAO
// @author Cristian F. Taborda <tabordacristianfernando@gmail.com>


contract RetireDAO {
    struct User {
        uint256 balance;
        uint256 latestContribution;
        uint256 ageRegistration;
        bool enableToWithdraw;
    }

    mapping(address => User) public users;
    address public admin;
    uint256 public retirementAge = 60; // configurable por la DAO y/o por el Usuario al Registrarse para el 1º aporte
    uint256 public minimunContribution = 50 * 1e18; // USDC/DAI en formato de 18 decimales

    constructor() {
        admin = msg.sender;
    }

    function registerUser(uint256 currentAge) public {
        require(users[msg.sender].ageRegistration == 0, "Already registered");
        users[msg.sender] = User(0, block.timestamp, currentAge, false);
    }

    function contribute() public payable {
        require(msg.value >= minimunContribution, "Contribution is Not Enough");
        users[msg.sender].balance += msg.value;
        users[msg.sender].latestContribution = block.timestamp;
    }

    function habilitarRetiro(address user, uint256 currentAge) public {
        require(msg.sender == admin, "Only Admin can do this operation");
        require(currentAge >= retirementAge, "Underage");
        users[user].enableToWithdraw = true;
    }

    function retirar(uint256 amount) public {
        User storage u = users[msg.sender];
        require(u.enableToWithdraw, "Not Enable");
        require(u.balance >= amount, "Insufficient Founds");

        u.balance -= amount;
        payable(msg.sender).transfer(amount);
    }
}
