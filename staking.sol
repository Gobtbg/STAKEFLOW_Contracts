//SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ITokenInfo {
    function name() external view returns (string memory);

    function symbol() external view returns (string memory);

    function decimals() external view returns (uint256);
}

contract StakeFlowStakingPool is Ownable(msg.sender), ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    uint256 public BlockTimeInSec;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.        
        uint256 rewardDebt; // Reward debt. See explanation below.
        uint256 unlockTime;
        uint256 totalEarned;
        uint256 unclaimed;
    }

    struct TokenInfo {
        address tokenAddress;
        string name;
        string symbol;
        uint256 decimals;
    }

    TokenInfo stakingTokenInfo;
    TokenInfo rewardTokenInfo;

    // Info of this pool.
    struct PoolInfo {
        IERC20 stakingToken;
        IERC20 rewardToken;
        string stakeTokenLogo;
        string rewardTokenLogo;
        uint256 lastRewardBlock; // Last block number that Tokens distribution occurs.
        uint256 accRewardPerShare; // Accumulated Tokens per share, times 1e12. See below.
        uint256 rewardPerBlock;
        address poolOwner;
        uint256 lockDuration;
        uint256 createdAt;
        uint256 endTime;
        string contacts;
    }
    PoolInfo public poolInfo;

    struct PoolStats {
        uint256 totalStaked;
        uint256 totalClaimed;
        uint256 totalUnclaimed;
        uint256 rewardBalanceInPool;
        bool isEndedStaking;
    }

    struct UserStats {
        uint256 pending;
        uint256 stakingTokenBalance;
        uint256 allowance;
    }

    uint256 totalStaked;
    uint256 totalClaimed;

    mapping(address => UserInfo) public userInfo;

    address wethAddress;

    address[] stakerAddresses;

    uint256 endedBlockNumber = 0;

    event Stake(address indexed user, uint256 amount);
    event Unstake(address indexed user, uint256 amount);
    event EmergencyUnstake(address indexed user, uint256 amount);
    event Claim(address indexed user, uint256 pending);

    constructor(
        IERC20 _stakingToken,
        IERC20 _rewardToken,
        string memory _stakingTokenLogo,
        string memory _rewardTokenLogo,
        uint256 _lockDuration,
        uint256 _rewardPerBlock,
        address _poolOwner,
        uint256 _endTime,
        string memory _contacts,
        address _wethAddress,
        uint256 _BlockTimeInSec
    ) {
        poolInfo.stakingToken = _stakingToken;
        poolInfo.rewardToken = _rewardToken;
        stakingTokenInfo = TokenInfo(
            address(_stakingToken),
            ITokenInfo(address(_stakingToken)).name(),
            ITokenInfo(address(_stakingToken)).symbol(),
            ITokenInfo(address(_stakingToken)).decimals()
        );
        rewardTokenInfo = TokenInfo(
            address(_rewardToken),
            ITokenInfo(address(_rewardToken)).name(),
            ITokenInfo(address(_rewardToken)).symbol(),
            ITokenInfo(address(_rewardToken)).decimals()
        );
        poolInfo.stakeTokenLogo = _stakingTokenLogo;
        poolInfo.rewardTokenLogo = _rewardTokenLogo;
        poolInfo.lockDuration = _lockDuration;
        poolInfo.rewardPerBlock = _rewardPerBlock;
        poolInfo.poolOwner = _poolOwner;
        poolInfo.createdAt = block.timestamp;
        poolInfo.endTime = _endTime;
        poolInfo.contacts = _contacts;
        wethAddress = _wethAddress;

        BlockTimeInSec = _BlockTimeInSec;
    }

    receive() external payable {}

    modifier onlyAdmin() {
        require(
            msg.sender == poolInfo.poolOwner || msg.sender == owner(),
            "Not allowed"
        );
        _;
    }

    function getBlocksPassed() internal view returns (uint256, uint256) {
        uint256 from = poolInfo.lastRewardBlock;
        uint256 to = block.number;
        if (endedBlockNumber > 0) {
            to = endedBlockNumber;
        } else {
            if (block.timestamp > poolInfo.endTime) {
                to = to - (block.timestamp - poolInfo.endTime) / BlockTimeInSec;
            }
        }

        if (to > from) {
            return (to.sub(from), to);
        } else {
            return (0, to);
        }
    }

    function rewardBalanceInPool() public view returns (uint256) {
        uint256 remainingReward = poolInfo.rewardToken.balanceOf(address(this));
        if (address(poolInfo.rewardToken) == wethAddress) {
            remainingReward = address(this).balance;
        }
        if (address(poolInfo.rewardToken) == address(poolInfo.stakingToken)) {
            if (remainingReward >= totalStaked) {
                remainingReward = remainingReward.sub(totalStaked);
            } else {
                remainingReward = 0;
            }
        }
        return remainingReward;
    }

    // View function to see pending Reward on frontend.
    function pendingReward(address _user) public view returns (uint256) {
        UserInfo storage user = userInfo[_user];

        uint256 _accRewardPerShare = poolInfo.accRewardPerShare;

        uint256 lpSupply = totalStaked;

        if (block.number > poolInfo.lastRewardBlock && lpSupply != 0) {
            (uint256 blocks, ) = getBlocksPassed();

            uint256 reward = blocks.mul(poolInfo.rewardPerBlock);

            _accRewardPerShare = _accRewardPerShare.add(
                reward.mul(1e12).div(lpSupply)
            );
        }
        uint256 pending = user.amount.mul(_accRewardPerShare).div(1e12).sub(
            user.rewardDebt
        );

        return user.unclaimed.add(pending);
    }

    function updatePool() internal {
        if (block.number <= poolInfo.lastRewardBlock) {
            return;
        }

        uint256 lpSupply = totalStaked;

        if (lpSupply == 0) {
            poolInfo.lastRewardBlock = block.number;
            return;
        }
        (uint256 blocks, uint256 toBlockNumber) = getBlocksPassed();
        if (block.number > toBlockNumber) {
            endedBlockNumber = toBlockNumber;
        }
        uint256 reward = blocks.mul(poolInfo.rewardPerBlock);

        poolInfo.accRewardPerShare = poolInfo.accRewardPerShare.add(
            reward.mul(1e12).div(lpSupply)
        );
        poolInfo.lastRewardBlock = toBlockNumber;
    }

    function transferToken(
        IERC20 _token,
        address _receiver,
        uint256 _amount
    ) internal {
        uint256 balance = _token.balanceOf(address(this));
        if (address(_token) == wethAddress) {
            balance = address(this).balance;
        }

        require(_amount <= balance, "Insufficient tokens");

        if (address(_token) == wethAddress) {
            (bool sent, ) = payable(_receiver).call{value: _amount}("");
            require(sent, "Failed to send ETH");
        } else {
            _token.safeTransfer(_receiver, _amount);
        }
    }

    // claim reward tokens from STAKING.
    function claim() public nonReentrant {
        UserInfo storage user = userInfo[msg.sender];

        updatePool();

        uint256 pending = user
            .amount
            .mul(poolInfo.accRewardPerShare)
            .div(1e12)
            .sub(user.rewardDebt);
        pending = pending.add(user.unclaimed);

        require(block.timestamp >= user.unlockTime, "wait until unlock");
        require(pending > 0, "No pending rewards");
        require(pending <= rewardBalanceInPool(), "Insufficient reward tokens");

        transferToken(poolInfo.rewardToken, address(msg.sender), pending);
        user.totalEarned += pending;
        user.unclaimed = 0;
        totalClaimed += pending;

        user.rewardDebt = user.amount.mul(poolInfo.accRewardPerShare).div(1e12);

        emit Claim(msg.sender, pending);
    }

    // Stake primary tokens
    function stake(uint256 _amount) public payable nonReentrant {
        require(block.timestamp < poolInfo.endTime, "Staking's ended!");

        if (poolInfo.lastRewardBlock == 0) {
            poolInfo.lastRewardBlock = block.number;
        }

        UserInfo storage user = userInfo[msg.sender];
        if (user.unlockTime == 0) {
            //new staker
            stakerAddresses.push(msg.sender);
        }

        updatePool();

        uint256 pending = user
            .amount
            .mul(poolInfo.accRewardPerShare)
            .div(1e12)
            .sub(user.rewardDebt);

        user.unclaimed = user.unclaimed + pending;

        uint256 amount = _amount;
        if (address(poolInfo.stakingToken) != wethAddress) {
            poolInfo.stakingToken.safeTransferFrom(
                address(msg.sender),
                address(this),
                amount
            );
        } else {
            amount = msg.value;
        }
        user.amount = user.amount.add(amount);
        totalStaked += amount;

        user.rewardDebt = user.amount.mul(poolInfo.accRewardPerShare).div(1e12);
        user.unlockTime = block.timestamp + poolInfo.lockDuration;

        if (user.unlockTime > poolInfo.endTime) {
            user.unlockTime = poolInfo.endTime;
        }
        
        emit Stake(msg.sender, amount);
    }

    function unstake(uint256 _amount) public nonReentrant {
        UserInfo storage user = userInfo[msg.sender];

        require(user.amount >= _amount, "Wrong unstake amount");
        require(block.timestamp >= user.unlockTime, "Wait until unlock");

        updatePool();

        uint256 pending = user
            .amount
            .mul(poolInfo.accRewardPerShare)
            .div(1e12)
            .sub(user.rewardDebt);
        pending = pending + user.unclaimed;

        if (pending > 0) {
            require(
                pending <= rewardBalanceInPool(),
                "Insufficient reward tokens"
            );

            transferToken(poolInfo.rewardToken, address(msg.sender), pending);
            user.totalEarned += pending;
            user.unclaimed = 0;
            totalClaimed += pending;            
        }
        if (_amount > 0) {
            transferToken(poolInfo.stakingToken, address(msg.sender), _amount);
            user.amount = user.amount.sub(_amount);
            totalStaked -= _amount;
        }
        user.rewardDebt = user.amount.mul(poolInfo.accRewardPerShare).div(1e12);

        emit Unstake(msg.sender, _amount);
    }

    function emergencyUnstake() public nonReentrant {
        UserInfo storage user = userInfo[msg.sender];
        uint256 amount = user.amount;
        require(amount > 0, "Not a staker");

        updatePool();

        user.amount = 0;
        user.rewardDebt = 0;
        user.unclaimed = 0;

        transferToken(poolInfo.stakingToken, address(msg.sender), amount);
        totalStaked -= amount;

        emit EmergencyUnstake(msg.sender, amount);
    }

    function withdrawStuckRewards() external onlyAdmin {
        uint256 _totalUnclaimed = 0;
        for (uint256 i = 0; i < stakerAddresses.length; i++) {
            _totalUnclaimed += pendingReward(stakerAddresses[i]);
        }
        uint256 _stuckRewards = rewardBalanceInPool();
        if (_stuckRewards >= _totalUnclaimed) {
            _stuckRewards = _stuckRewards - _totalUnclaimed;
        }
        require(
            block.timestamp >= poolInfo.endTime + 259200,
            "Wait until withdrawable time"
        );
        require(_stuckRewards > 0, "No stuck rewards");

        transferToken(poolInfo.rewardToken, address(msg.sender), _stuckRewards);
    }

    function getPoolInfo() external view returns (bool, PoolInfo memory) {
        return (block.timestamp >= poolInfo.endTime ? true : false, poolInfo);
    }

    // get status
    function getPoolStatus()
        external
        view
        returns (
            TokenInfo memory,
            TokenInfo memory,
            PoolStats memory,
            PoolInfo memory
        )
    {
        uint256 _rewardBalanceInPool = rewardBalanceInPool();
        uint256 _totalUnclaimed = 0;
        for (uint256 i = 0; i < stakerAddresses.length; i++) {
            _totalUnclaimed += pendingReward(stakerAddresses[i]);
        }
        PoolStats memory _poolStats = PoolStats({
            totalStaked: totalStaked,
            totalClaimed: totalClaimed,
            totalUnclaimed: _totalUnclaimed,
            rewardBalanceInPool: _rewardBalanceInPool,
            isEndedStaking: block.timestamp >= poolInfo.endTime ? true : false
        });
        return (stakingTokenInfo, rewardTokenInfo, _poolStats, poolInfo);
    }

    function getUserStatus(
        address _user
    ) external view returns (UserStats memory, UserInfo memory) {
        uint256 _pending = pendingReward(_user);
        UserInfo memory _userInfo = userInfo[_user];
        uint256 _stakingTokenBalance = _user.balance;
        uint256 _allowance = type(uint256).max;
        if (stakingTokenInfo.tokenAddress != wethAddress) {
            _stakingTokenBalance = IERC20(stakingTokenInfo.tokenAddress)
                .balanceOf(_user);
            _allowance = IERC20(stakingTokenInfo.tokenAddress).allowance(
                _user,
                address(this)
            );
        }
        UserStats memory _userStats = UserStats({
            pending: _pending,
            stakingTokenBalance: _stakingTokenBalance,
            allowance: _allowance
        });
        return (_userStats, _userInfo);
    }

    function updateEndTime(uint256 _endTime) external onlyOwner {
        poolInfo.endTime = _endTime;
    }

    function updatePoolOwner(address _newOwner) external onlyOwner {
        poolInfo.poolOwner = _newOwner;
    }
}
