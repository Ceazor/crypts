// SPDX-License-Identifier: MIT

pragma solidity ^0.8.11;
pragma experimental ABIEncoderV2;


import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";


import "../../interfaces/IBeethovenxChef.sol";
import "../../interfaces/IBalancerVault.sol";
import "../../interfaces/IBeetRewarder.sol";
import "../strategies/FeeManager.sol";

contract StrategyBeethovenxDualToBeets is FeeManager, Pausable {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // Tokens used
    address public want;
    address public Beets = address(0xF24Bcf4d1e507740041C9cFd2DddB29585aDCe1e); //beets
    address public native = address(0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83); //wftm
    address public input;
    address public reward;
    address[] public lpTokens;
    address public unirouter = address(0x20dd72Ed959b6147912C2e529F0a0C651c33c9ce); // Beethoven Swap route
    address public vault;                // The vault this strat is for
    address public perFeeRecipient;      // Who gets the performance fee
    address public strategist;           // Who gets the strategy fee
    address public xCheeseRecipient = address(0x699675204aFD7Ac2BB146d60e4E3Ddc243843519); // preset to owner CHANGE ASAP

    // Third party contracts
    address public chef = address(0x8166994d9ebBe5829EC86Bd81258149B87faCfd3); //hard coding this in to start
    uint256 public chefPoolId;
    address public rewarder;
    bytes32 public wantPoolId;
    bytes32 public nativeSwapPoolId;
    bytes32 public rewardSwapPoolId;


    IBalancerVault.SwapKind public swapKind;
    IBalancerVault.FundManagement public funds;

    bool public harvestOnDeposit;
    uint256 public lastHarvest;

    event StratHarvest(address indexed harvester, uint256 wantHarvested, uint256 tvl);
    event Deposit(uint256 tvl);
    event Withdraw(uint256 tvl);

    constructor(
        address _input,             // 0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83 - wFTM
        address _vault,             // ?????????????????????????????????????????? - ceazCRE8RF-Major
        address _unirouter,         // 0x20dd72Ed959b6147912C2e529F0a0C651c33c9ce - "Vault" Beethoven swap
        address _strategist,        // 0x3c5Aac016EF2F178e8699D6208796A2D67557fe2 - ceazor
        address _perFeeRecipient,   // 0x3c5Aac016EF2F178e8699D6208796A2D67557fe2 - ceazor
        address _want,              // 0xbb4607beDE4610e80d35C15692eFcB7807A2d0A6 - CRE8RFMajor BPT
        address _reward,            // 0x2aD402655243203fcfa7dCB62F8A08cc2BA88ae0 - CRE8R here
        address _rewarder,          // 0x1098D1712592Bf4a3d73e5fD29Ae0da6554cd39f - CRE8R token farm
        uint256 _chefPoolId,        //39 CRE8R Gauge
        bytes32 _wantPoolId,        //0xbb4607bede4610e80d35c15692efcb7807a2d0a6000200000000000000000140
        bytes32 _nativeSwapPoolId,  //0xcde5a11a4acb4ee4c805352cec57e236bdbc3837000200000000000000000019
        bytes32 _rewardPoolId       //0xbb4607bede4610e80d35c15692efcb7807a2d0a6000200000000000000000140 - this assumes the reward might be different than the want


    ) {  
        wantPoolId = _wantPoolId;
        nativeSwapPoolId = _nativeSwapPoolId;
        rewardSwapPoolId = _rewardPoolId;
        chefPoolId = _chefPoolId;
        input = _input; //!!!! This is hard coded to wFTM above, so if the pool doesn't have wFTM this will not work
        want = _want;
        lpTokens = [input, reward];  // !!!this may contain more than 2 tokens
        reward = _reward;
        rewarder = _rewarder;
        swapKind = IBalancerVault.SwapKind.GIVEN_IN;
        funds = IBalancerVault.FundManagement(address(this), false, payable(address(this)), false);

        _giveAllowances();
    }

    // puts the funds to work
    function deposit() public whenNotPaused {
        uint256 wantBal = IERC20(want).balanceOf(address(this));

        if (wantBal > 0) {
            IBeethovenxChef(chef).deposit(chefPoolId, wantBal, address(this));
            emit Deposit(balanceOf());
        }
    }

    function withdraw(uint256 _amount) external {
        require(msg.sender == vault, "ask the vault to withdraw ser!");  //makes sure only the vault can withdraw from the chef

        uint256 wantBal = IERC20(want).balanceOf(address(this));

        if (wantBal < _amount) {
            IBeethovenxChef(chef).withdrawAndHarvest(chefPoolId, _amount.sub(wantBal), address(this));
            wantBal = IERC20(want).balanceOf(address(this));
        }

        if (wantBal > _amount) {
            wantBal = _amount;
        }

        if (tx.origin != owner() && !paused()) {
            uint256 withdrawalFeeAmount = wantBal.mul(withdrawalFee).div(WITHDRAWAL_MAX);
            wantBal = wantBal.sub(withdrawalFeeAmount);
        }

        IERC20(want).safeTransfer(vault, wantBal);

        emit Withdraw(balanceOf());
    }

    function beforeDeposit() external {
        if (harvestOnDeposit) {
            require(msg.sender == vault, "!vault");  //makes sure the vault is the only one that can do quick preDeposit Harvest
            _harvest(tx.origin);
        }
    }

    function harvest() external virtual {
        _harvest(tx.origin);
    }

    function harvest(address callFeeRecipient) external virtual {
        _harvest(callFeeRecipient);
    }

    function managerHarvest() external onlyOwner {
        _harvest(tx.origin);
    }

    // compounds earnings and charges performance fee
    function _harvest(address callFeeRecipient) internal whenNotPaused {
        IBeethovenxChef(chef).harvest(chefPoolId, address(this));
        uint256 BeetsBal = IERC20(Beets).balanceOf(address(this));   // beets harvest
        uint256 rewardBal = IERC20(reward).balanceOf(address(this));   // cre8r harvest
        if (BeetsBal > 0 || rewardBal > 0) {
            chargeFees(callFeeRecipient);
            addLiquidity();
            uint256 wantHarvested = balanceOfWant();
            deposit();

            lastHarvest = block.timestamp;
            emit StratHarvest(msg.sender, wantHarvested, balanceOf()); //tells everyone who did the harvest (they need be paid)
        }
    }

    // performance fees
    function chargeFees(address callFeeRecipient) internal {
        uint256 BeetsBal = IERC20(Beets).balanceOf(address(this));
        if (BeetsBal > 0) {
            balancerSwap(nativeSwapPoolId, Beets, native, BeetsBal);  // swaps all the beets for wftm
        }

        uint256 rewardBal = IERC20(reward).balanceOf(address(this));
        if (rewardBal > 0) {
            balancerSwap(rewardSwapPoolId, reward, native, rewardBal);  //swaps all the cre8r for wftm
        }
        // ceazor made total fee variable
        uint256 nativeBal = IERC20(native).balanceOf(address(this)).mul(totalFee).div(1000); //assigns balance of wftm

        uint256 callFeeAmount = nativeBal.mul(callFee).div(MAX_FEE); 
        IERC20(native).safeTransfer(callFeeRecipient, callFeeAmount); //calcs callfee and transfers

        uint256 perFeeAmount = nativeBal.mul(perFee).div(MAX_FEE);
        IERC20(native).safeTransfer(perFeeRecipient, perFeeAmount);  //calcs perFee and transfers

        uint256 strategistFee = nativeBal.mul(STRATEGIST_FEE).div(MAX_FEE);
        IERC20(native).safeTransfer(strategist, strategistFee);      // calcs strategist fee and transfers

        //ceazor added swap some back to Beets
        uint256 forXCheese = IERC20(native).balanceOf(address(this));
        if (forXCheese > 0) {
            balancerSwap(nativeSwapPoolId, native, Beets, (forXCheese).div(xCheeseRate));    // swaps % to the remaining wtfm for Beets 
            IERC20(Beets).safeTransfer(xCheeseRecipient, forXCheese);              // and send them to xCheese
        }
    }

    // Sets the xCheeseRecipient address to recieve the BEETs rewards
    function setxCheeseRecipient(address _xCheeseRecipient) external onlyOwner {
        xCheeseRecipient = _xCheeseRecipient;
    }

    // Adds liquidity to AMM and gets more LP tokens.
    function addLiquidity() internal {
        if (input != native) {
            uint256 BeetsBal = IERC20(Beets).balanceOf(address(this));
            balancerSwap(nativeSwapPoolId, Beets, input, BeetsBal);
        }

        uint256 inputBal = IERC20(input).balanceOf(address(this));
        balancerJoin(wantPoolId, input, inputBal);
    }

    function balancerSwap(bytes32 _poolId, address _tokenIn, address _tokenOut, uint256 _amountIn) internal returns (uint256) {
        IBalancerVault.SingleSwap memory singleSwap = IBalancerVault.SingleSwap(_poolId, swapKind, _tokenIn, _tokenOut, _amountIn, "");
        return IBalancerVault(unirouter).swap(singleSwap, funds, 1, block.timestamp);
    }

    function balancerJoin(bytes32 _poolId, address _tokenIn, uint256 _amountIn) internal {
        uint256[] memory amounts = new uint256[](lpTokens.length);
        for (uint256 i = 0; i < amounts.length; i++) {
            amounts[i] = lpTokens[i] == _tokenIn ? _amountIn : 0;
        }
        bytes memory userData = abi.encode(1, amounts, 1);

        IBalancerVault.JoinPoolRequest memory request = IBalancerVault.JoinPoolRequest(lpTokens, amounts, userData, false);
        IBalancerVault(unirouter).joinPool(_poolId, address(this), address(this), request);
    }

    // calculate the total underlaying 'want' held by the strat.
    function balanceOf() public view returns (uint256) {
        return balanceOfWant().add(balanceOfPool());
    }

    // it calculates how much 'want' this contract holds.
    function balanceOfWant() public view returns (uint256) {
        return IERC20(want).balanceOf(address(this));
    }

    // it calculates how much 'want' the strategy has working in the farm.
    function balanceOfPool() public view returns (uint256) {
        (uint256 _amount,) = IBeethovenxChef(chef).userInfo(chefPoolId, address(this));
        return _amount;
    }

    // returns rewards unharvested
    function rewardsAvailable() public view returns (uint256, uint256) {
        uint256 BeetsBal = IBeethovenxChef(chef).pendingBeets(chefPoolId, address(this));
        uint256 rewardBal = IBeetRewarder(rewarder).pendingToken(chefPoolId, address(this));
        return (BeetsBal, rewardBal);
    }

    // native reward amount for calling harvest
    function callReward() public returns (uint256) {
        (uint256 BeetsBal, uint256 rewardBal) = rewardsAvailable();
        uint256 nativeOut;
        if (BeetsBal > 0) {
            nativeOut = balancerSwap(nativeSwapPoolId, Beets, native, BeetsBal);
        }
        if (rewardBal > 0) {
            nativeOut += balancerSwap(rewardSwapPoolId, reward, native, rewardBal);
        }

        return nativeOut.mul(totalFee).div(1000).mul(callFee).div(MAX_FEE);
    }

    function setHarvestOnDeposit(bool _harvestOnDeposit) external onlyOwner {
        harvestOnDeposit = _harvestOnDeposit;

        if (harvestOnDeposit) {
            setWithdrawalFee(0);
        } else {
            setWithdrawalFee(10);
        }
    }

    // called as part of strat migration. Sends all the available funds back to the vault.
    function retireStrat() external {
        require(msg.sender == vault, "anon, you not the vault!"); //makes sure that only the vault can retire a strat

        IBeethovenxChef(chef).emergencyWithdraw(chefPoolId, address(this));

        uint256 wantBal = IERC20(want).balanceOf(address(this));
        IERC20(want).transfer(vault, wantBal);
    }

    // pauses deposits and withdraws all funds from third party systems.
    function panic() public onlyOwner {
        pause();
        IBeethovenxChef(chef).emergencyWithdraw(chefPoolId, address(this));
    }

    function pause() public onlyOwner {
        _pause();

        _removeAllowances();
    }

    function unpause() external onlyOwner {
        _unpause();

        _giveAllowances();

        deposit();
    }



    /**
     * @dev Updates address where strategist fee earnings will go.
     * @param _strategist new strategist address.
     */
    function setStrategist(address _strategist) external {
        require(msg.sender == strategist, "!strategist");
        strategist = _strategist;
    }

    /**
     * @dev Updates router that will be used for swaps.
     * @param _unirouter new unirouter address.
     */
    function setUnirouter(address _unirouter) external onlyOwner {
        unirouter = _unirouter;
    }

    /**
     * @dev Updates parent vault.
     * @param _vault new vault address.
     */
    function setVault(address _vault) external onlyOwner {
        vault = _vault;
    }

    /**
     * @dev Updates fee recipient.
     * @param _perFeeRecipient new performance fee recipient address.
     */
    function setperFeeRecipient(address _perFeeRecipient) external onlyOwner {
        perFeeRecipient = _perFeeRecipient;
    }


    function _giveAllowances() internal {
        IERC20(want).safeApprove(chef, type(uint256).max);
        IERC20(Beets).safeApprove(unirouter, type(uint256).max);
        IERC20(reward).safeApprove(unirouter, type(uint256).max);

        IERC20(input).safeApprove(unirouter, 0);
        IERC20(input).safeApprove(unirouter, type(uint256).max);
    }

    function _removeAllowances() internal {
        IERC20(want).safeApprove(chef, 0);
        IERC20(Beets).safeApprove(unirouter, 0);
        IERC20(reward).safeApprove(unirouter, 0);
        IERC20(input).safeApprove(unirouter, 0);
    }
}