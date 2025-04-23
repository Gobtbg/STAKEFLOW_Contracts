//SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./staking.sol";

contract StakeFlowStakingClub is Ownable(msg.sender), ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    uint256 public BlockTimeInSec = 3; //3s
    address[] public createdPoolCAs;
    mapping(address => address) public poolOwners;

    struct BasicPoolInfo {
        address poolAddress;
        address stakingToken;
        string stakingTokenName;
        string stakingTokenSymbol;
        address rewardToken;
        string rewardTokenName;
        string rewardTokenSymbol;
        uint256 createdAt;
        uint256 endTime;
        bool isEndedStaking;
    }

    struct DetailedPoolInfo {
        address poolAddress;
        uint256 totalStaked;
        uint256 totalClaimed;
        uint256 totalUnclaimed;
        uint256 rewardBalanceInPool;
        bool isEndedStaking;
        StakeFlowStakingPool.TokenInfo stakingTokenInfo;
        StakeFlowStakingPool.TokenInfo rewardTokenInfo;
        StakeFlowStakingPool.PoolInfo poolInfo;
    }

    struct DetailedPoolAndUserInfo {
        address poolAddress;
        uint256 totalStaked;
        uint256 totalClaimed;
        uint256 totalUnclaimed;
        uint256 rewardBalanceInPool;
        bool isEndedStaking;
        StakeFlowStakingPool.TokenInfo stakingTokenInfo;
        StakeFlowStakingPool.TokenInfo rewardTokenInfo;
        StakeFlowStakingPool.PoolInfo poolInfo;
        uint256 userPending;
        uint256 userStakingTokenBalance;
        uint256 userAllowance;
        StakeFlowStakingPool.UserInfo userInfo;
    }

    struct CreatePoolParams {
        IERC20 stakingToken;
        IERC20 rewardToken;
        string stakingTokenLogo;
        string rewardTokenLogo;
        uint256 rewardSupply;
        uint256 payAmount;
        uint256 lockDuration;
        uint256 rewardPerBlock;
        uint256 endTime;
        string contacts;
    }

    IERC20 public payToken; //token needed to create pool
    uint256 public payAmount; //amount of payToken needed to create pool

    address public noNeedChargeFeeToken =
        0x876785eC8010c20a52dDef059D313B4d9189ACD1; //if user use this token as a stake token or reward token to create a pool, he/she will not be charged with creation fee
    mapping(address => bool) public exemptFromFee;
    address wethAddress = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c; // bsc mainnet

    event CreatedNewPool(address indexed user, address indexed poolAddress);

    constructor(IERC20 _payToken, uint256 _payAmount) {
        require(address(_payToken) != address(0), "Invalid pay token!");
        payToken = _payToken;
        payAmount = _payAmount;
    }

    receive() external payable {}

    function _checkManager(
        StakeFlowStakingPool _pool,
        address _sender
    ) internal view virtual {
        require(
            _sender == owner() || poolOwners[address(_pool)] == _sender,
            "Not allowed to call"
        );
    }

    function createNewPool(CreatePoolParams memory params) public payable {
        bool _isExemptedFromFee = isNoNeedChargePool(
            address(params.stakingToken),
            address(params.rewardToken)
        );
        if (exemptFromFee[msg.sender]) {
            _isExemptedFromFee = true;
        }

        if (!_isExemptedFromFee) {
            if (address(payToken) != wethAddress) {
                require(
                    params.payAmount >= payAmount,
                    "Insufficient pay tokens"
                );
            } else {
                require(msg.value >= payAmount, "Insufficient pay tokens");
            }
        }
        uint256 _rewardAmount = params.rewardSupply;
        if (address(params.rewardToken) == wethAddress) {
            uint256 value = msg.value;
            if (address(payToken) != wethAddress) {
                _rewardAmount = msg.value;
            } else {
                if (!_isExemptedFromFee) {
                    _rewardAmount = value.sub(payAmount);
                }
            }
        }

        require(
            address(params.stakingToken) != address(0),
            "Invalid staking token"
        );
        require(
            address(params.rewardToken) != address(0),
            "Invalid reward token"
        );
        require(params.rewardPerBlock > 0, "Invalid reward per block");
        require(
            params.rewardSupply > 0 && _rewardAmount >= params.rewardSupply,
            "Insufficient reward supply"
        );

        if (!_isExemptedFromFee) {
            if (address(payToken) != wethAddress) {
                payToken.safeTransferFrom(msg.sender, address(this), payAmount);
            }
        }
        uint256 beforeBalance = params.rewardToken.balanceOf(address(this));
        if (address(params.rewardToken) != wethAddress) {
            params.rewardToken.safeTransferFrom(
                msg.sender,
                address(this),
                params.rewardSupply
            );
        }

        StakeFlowStakingPool pool = new StakeFlowStakingPool(
            params.stakingToken,
            params.rewardToken,
            params.stakingTokenLogo,
            params.rewardTokenLogo,
            params.lockDuration,
            params.rewardPerBlock,
            msg.sender,
            params.endTime,
            params.contacts,
            wethAddress,
            BlockTimeInSec
        );

        uint256 sending = params.rewardToken.balanceOf(address(this));
        sending = sending.sub(beforeBalance);

        if (address(params.rewardToken) != wethAddress) {
            params.rewardToken.safeTransfer(address(pool), sending);
        } else {
            (bool sent, ) = payable(address(pool)).call{value: _rewardAmount}(
                ""
            );
            require(sent, "Failed to send ETH");
        }

        createdPoolCAs.push(address(pool));

        poolOwners[address(pool)] = msg.sender;

        emit CreatedNewPool(msg.sender, address(pool));
    }

    function isNoNeedChargePool(
        address stakingToken,
        address rewardToken
    ) private view returns (bool) {
        if (
            stakingToken == noNeedChargeFeeToken ||
            rewardToken == noNeedChargeFeeToken
        ) return true;
        return false;
    }

    function updatePoolOwner(
        StakeFlowStakingPool _pool,
        address _newOwner
    ) external {
        _checkManager(_pool, msg.sender);

        poolOwners[address(_pool)] = _newOwner;

        _pool.updatePoolOwner(_newOwner);
    }

    function updateEndTime(
        StakeFlowStakingPool _pool,
        uint256 _endTime
    ) external {
        _checkManager(_pool, msg.sender);

        _pool.updateEndTime(_endTime);
    }

    function getBasicPoolInfos(
        uint256 _countsFromLatest
    ) external view returns (BasicPoolInfo[] memory, uint256) {
        uint256 _pool_cnt = _countsFromLatest;
        if (_countsFromLatest == 0 || _countsFromLatest > createdPoolCAs.length)
            _pool_cnt = createdPoolCAs.length;

        BasicPoolInfo[] memory pools = new BasicPoolInfo[](_pool_cnt);

        if (_pool_cnt > 0) {
            uint256 _index = createdPoolCAs.length - 1;
            for (uint256 i = 0; i < _pool_cnt; i++) {
                (
                    bool _isEndedStaking,
                    StakeFlowStakingPool.PoolInfo memory _pool_detail
                ) = StakeFlowStakingPool(payable(createdPoolCAs[_index - i]))
                        .getPoolInfo();

                pools[i] = BasicPoolInfo({
                    poolAddress: createdPoolCAs[_index - i],
                    stakingToken: address(_pool_detail.stakingToken),
                    stakingTokenName: ITokenInfo(
                        address(_pool_detail.stakingToken)
                    ).name(),
                    stakingTokenSymbol: ITokenInfo(
                        address(_pool_detail.stakingToken)
                    ).symbol(),
                    rewardToken: address(_pool_detail.rewardToken),
                    rewardTokenName: ITokenInfo(
                        address(_pool_detail.rewardToken)
                    ).name(),
                    rewardTokenSymbol: ITokenInfo(
                        address(_pool_detail.rewardToken)
                    ).symbol(),
                    createdAt: _pool_detail.createdAt,
                    endTime: _pool_detail.endTime,
                    isEndedStaking: _isEndedStaking
                });
            }
        }
        return (pools, block.timestamp);
    }

    function getDetailedPoolAndUserInfos(
        address[] memory _poolCAs,
        address _user
    ) external view returns (DetailedPoolAndUserInfo[] memory) {
        DetailedPoolAndUserInfo[] memory pools = new DetailedPoolAndUserInfo[](
            _poolCAs.length
        );

        for (uint256 i = 0; i < _poolCAs.length; i++) {
            (
                StakeFlowStakingPool.TokenInfo memory _stakingTokenInfo,
                StakeFlowStakingPool.TokenInfo memory _rewardTokenInfo,
                StakeFlowStakingPool.PoolStats memory _poolStats,
                StakeFlowStakingPool.PoolInfo memory _poolInfo
            ) = StakeFlowStakingPool(payable(_poolCAs[i])).getPoolStatus();

            (
                StakeFlowStakingPool.UserStats memory _userStats,
                StakeFlowStakingPool.UserInfo memory _userInfo
            ) = StakeFlowStakingPool(payable(_poolCAs[i])).getUserStatus(_user);

            pools[i] = DetailedPoolAndUserInfo({
                poolAddress: _poolCAs[i],
                totalStaked: _poolStats.totalStaked,
                totalClaimed: _poolStats.totalClaimed,
                totalUnclaimed: _poolStats.totalUnclaimed,
                rewardBalanceInPool: _poolStats.rewardBalanceInPool,
                isEndedStaking: _poolStats.isEndedStaking,
                stakingTokenInfo: _stakingTokenInfo,
                rewardTokenInfo: _rewardTokenInfo,
                poolInfo: _poolInfo,
                userPending: _userStats.pending,
                userStakingTokenBalance: _userStats.stakingTokenBalance,
                userAllowance: _userStats.allowance,
                userInfo: _userInfo
            });
        }

        return (pools);
    }

    function getDetailedPoolInfos(
        address[] memory _poolCAs
    ) external view returns (DetailedPoolInfo[] memory) {
        DetailedPoolInfo[] memory pools = new DetailedPoolInfo[](
            _poolCAs.length
        );

        for (uint256 i = 0; i < _poolCAs.length; i++) {
            (
                StakeFlowStakingPool.TokenInfo memory _stakingTokenInfo,
                StakeFlowStakingPool.TokenInfo memory _rewardTokenInfo,
                StakeFlowStakingPool.PoolStats memory _poolStats,
                StakeFlowStakingPool.PoolInfo memory _poolInfo
            ) = StakeFlowStakingPool(payable(_poolCAs[i])).getPoolStatus();

            pools[i] = DetailedPoolInfo({
                poolAddress: _poolCAs[i],
                totalStaked: _poolStats.totalStaked,
                totalClaimed: _poolStats.totalClaimed,
                totalUnclaimed: _poolStats.totalUnclaimed,
                rewardBalanceInPool: _poolStats.rewardBalanceInPool,
                isEndedStaking: _poolStats.isEndedStaking,
                stakingTokenInfo: _stakingTokenInfo,
                rewardTokenInfo: _rewardTokenInfo,
                poolInfo: _poolInfo
            });
        }

        return (pools);
    }

    function updatePayToken(IERC20 _payToken) external onlyOwner {
        payToken = _payToken;
    }

    function updateNoNeedChargeToken(IERC20 _token) external onlyOwner {
        noNeedChargeFeeToken = address(_token);
    }

    function updatePayAmount(uint256 _payAmount) external onlyOwner {
        payAmount = _payAmount;
    }

    function updateBlockTimeInSec(uint256 _BlockTimeInSec) external onlyOwner {
        BlockTimeInSec = _BlockTimeInSec;
    }

    function setExemptFromFee(
        address _creator,
        bool _state
    ) external onlyOwner {
        exemptFromFee[_creator] = _state;
    }

    function ownerWithdrawPayTokens() public nonReentrant onlyOwner {
        uint256 bal = 0;
        if (address(payToken) == wethAddress) {
            //eth
            bal = address(this).balance;
            require(bal > 0, "No ETH to withdraw.");
            (bool sent, ) = payable(owner()).call{value: bal}("");
            require(sent, "Failed to send ETH");
        } else {
            bal = payToken.balanceOf(address(this));
            require(bal > 0, "No tokens to withdraw.");
            payToken.safeTransfer(msg.sender, bal);
        }
    }
}
