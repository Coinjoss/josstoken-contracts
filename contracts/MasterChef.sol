// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "./Token.sol";

contract MasterChef is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        uint256 rewardSharesDebt; // Reward debt. See explanation below.
        uint256 nextHarvestUntil; // When can the user harvest again.
        uint256 rewardKept;
    }

    // Info of each pool.
    struct PoolInfo {
        uint256 amount;
        IERC20 lpToken; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. SHs to distribute per block.
        uint256 lastRewardBlock; // Last block number that Shs distribution occurs.
        uint256 accjossPerPower; // Accumulated Shs per share, times 1e12. See below.
        uint16 depositFeeBP; // Deposit fee in basis points
    }

    Token public jossToken;

    // joss tokens created per block.
    uint256 public jossPerBlock = 5e17;
    // Deposit Fee address
    address public feeAddress;
    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when joss mining starts.
    uint256 public startBlock;
    uint256 public constant HARVEST_INTERVAL = 1 minutes; //8 hours;

    // Referrers
    mapping(address => address) public referrer;
    mapping(address => mapping(uint8 => uint256)) public referrals;
    mapping(address => uint256) public referrerReward;
    uint16[] public referrerRewardRate = [600, 300, 100];

    mapping(IERC20 => bool) public poolExistence;
    modifier nonDuplicated(IERC20 _lpToken) {
        require(poolExistence[_lpToken] == false, "nonDuplicated:duplicated");
        _;
    }

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event Claim(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );

    event AddPool(
        uint256 _allocPoint,
        IERC20 _lpToken,
        uint16 _depositFeeBP,
        bool _withUpdate
    );
    event SetPool(
        uint256 _pid,
        uint256 _allocPoint,
        uint16 _depositFeeBP,
        bool _withUpdate
    );

    event SetDev(address dev);
    event SetFee(address fee);
    event UpdateEmissionRate(uint256 _shPerBlock);

    constructor(
        Token _jossToken,
        address _feeAddress,
        uint256 _startBlock
    ) {
        require(_feeAddress != address(0), "address can't be 0");

        jossToken = _jossToken;
        feeAddress = _feeAddress;
        startBlock = _startBlock;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(
        uint256 _allocPoint,
        IERC20 _lpToken,
        uint16 _depositFeeBP,
        bool _withUpdate
    ) external nonDuplicated(_lpToken) onlyOwner {
        require(_depositFeeBP <= 500, "add: invalid deposit fee basis points");
        if (_withUpdate) {
            _massUpdatePools();
        }

        poolExistence[_lpToken] = true;

        _lpToken.balanceOf(address(this));

        uint256 lastRewardBlock = block.number > startBlock
            ? block.number
            : startBlock;
        totalAllocPoint += _allocPoint;
        poolInfo.push(
            PoolInfo({
                amount: 0,
                lpToken: _lpToken,
                allocPoint: _allocPoint,
                lastRewardBlock: lastRewardBlock,
                accjossPerPower: 0,
                depositFeeBP: _depositFeeBP
            })
        );

        emit AddPool(_allocPoint, _lpToken, _depositFeeBP, _withUpdate);
    }

    // Update the given pool's SH allocation point and deposit fee. Can only be called by the owner.
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        uint16 _depositFeeBP,
        bool _withUpdate
    ) external onlyOwner {
        require(_depositFeeBP <= 500, "set: invalid deposit fee basis points");
        if (_withUpdate) {
            _massUpdatePools();
        }
        totalAllocPoint =
            totalAllocPoint -
            poolInfo[_pid].allocPoint +
            _allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;

        emit SetPool(_pid, _allocPoint, _depositFeeBP, _withUpdate);
    }

    function setFeeAddress(address _feeAddress) external {
        require(msg.sender == feeAddress, "setFeeAddress: FORBIDDEN");
        require(_feeAddress != address(0), "!nonzero");

        feeAddress = _feeAddress;

        emit SetFee(_feeAddress);
    }

    //Pancake has to add hidden dummy pools inorder to alter the emission, here we make it simple and transparent to all.
    function updateEmissionRate(uint256 _emissionsPerBlock) external onlyOwner {
        require(_emissionsPerBlock <= 10 * 1e18, "Too high");

        _massUpdatePools();
        jossPerBlock = _emissionsPerBlock;

        emit UpdateEmissionRate(_emissionsPerBlock);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function _massUpdatePools() internal {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            _updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function _updatePool(uint256 _pid) internal {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }

        if (pool.amount == 0 || pool.allocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }

        uint256 blockAmount = block.number - pool.lastRewardBlock;
        uint256 jossReward = (blockAmount * jossPerBlock * pool.allocPoint) /
            totalAllocPoint;

        jossToken.mint(address(this), jossReward);
        pool.accjossPerPower += (jossReward * 1e12) / pool.amount;
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to MasterChef for joss allocation.
    function deposit(
        uint256 _pid,
        uint256 _amount,
        address _ref
    ) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        _updatePool(_pid);
        _keepPending(_pid, msg.sender);

        if (_amount > 0) {
            if (user.nextHarvestUntil == 0) {
                user.nextHarvestUntil = block.timestamp + HARVEST_INTERVAL;
            }

            uint256 balance = pool.lpToken.balanceOf(address(this));

            pool.lpToken.safeTransferFrom(
                address(msg.sender),
                address(this),
                _amount
            );

            uint256 amount = pool.lpToken.balanceOf(address(this)) - balance;

            if (pool.depositFeeBP > 0) {
                uint256 depositFee = (amount * pool.depositFeeBP) / 10000;
                pool.lpToken.safeTransfer(feeAddress, depositFee);
                amount -= depositFee;
            }

            user.amount += amount;
            pool.amount += amount;
        }

        user.rewardDebt = (user.amount * pool.accjossPerPower) / 1e12;

        if (
            _ref != address(0) &&
            _ref != msg.sender &&
            referrer[msg.sender] == address(0)
        ) {
            referrer[msg.sender] = _ref;

            // direct ref
            referrals[_ref][0] += 1;
            referrals[_ref][1] += referrals[msg.sender][0];
            referrals[_ref][2] += referrals[msg.sender][1];

            // direct refs from direct ref
            address ref1 = referrer[_ref];
            if (ref1 != address(0)) {
                referrals[ref1][1] += 1;
                referrals[ref1][2] += referrals[msg.sender][0];

                // their refs
                address ref2 = referrer[ref1];
                if (ref2 != address(0)) {
                    referrals[ref2][2] += 1;
                }
            }
        }

        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");

        _updatePool(_pid);
        _keepPending(_pid, msg.sender);

        if (_amount > 0) {
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
            user.amount -= _amount;
            pool.amount -= _amount;
        }

        user.rewardDebt = (user.amount * pool.accjossPerPower) / 1e12;

        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        pool.amount -= user.amount;
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        user.rewardKept = 0;
        user.nextHarvestUntil = 0;

        pool.lpToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    function _rewardReferrers(uint256 baseAmount) internal {
        address ref = msg.sender;
        for (uint8 i = 0; i < referrerRewardRate.length; i++) {
            ref = referrer[ref];
            if (ref == address(0)) {
                break;
            }

            uint256 reward = (baseAmount * referrerRewardRate[i]) / 10000;
            jossToken.mint(ref, reward);
            referrerReward[ref] += reward;
        }
    }

    function claim(uint256 _pid) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        require(block.timestamp >= user.nextHarvestUntil, "too soon");

        _updatePool(_pid);

        uint256 pending = user.rewardKept + _pendingjoss(_pid, msg.sender);

        require(pending > 0, "Nothing to claim");

        _rewardReferrers(pending);

        uint256 harvest = pending / 10;
        _safejossTransfer(msg.sender, harvest);

        emit Claim(msg.sender, _pid, pending);

        user.rewardKept = 0;
        user.rewardDebt = (user.amount * pool.accjossPerPower) / 1e12;

        user.nextHarvestUntil = block.timestamp + HARVEST_INTERVAL;
    }

    function _keepPending(uint256 _pid, address _user) internal {
        UserInfo storage user = userInfo[_pid][_user];
        user.rewardKept += pendingjoss(_pid, _user);
    }

    function pendingjoss(uint256 _pid, address _user)
        internal
        view
        returns (uint256)
    {
        UserInfo storage user = userInfo[_pid][_user];

        return user.rewardKept + _pendingjoss(_pid, msg.sender);
    }

    // DO NOT include kept reward
    function _pendingjoss(uint256 _pid, address _user)
        internal
        view
        returns (uint256)
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accShPerPower = pool.accjossPerPower;

        if (
            block.number > pool.lastRewardBlock &&
            pool.amount != 0 &&
            totalAllocPoint > 0
        ) {
            uint256 blockAmount = block.number - pool.lastRewardBlock;
            uint256 jossReward = (blockAmount *
                jossPerBlock *
                pool.allocPoint) / totalAllocPoint;
            accShPerPower += (jossReward * 1e12) / pool.amount;
        }

        return (user.amount * accShPerPower) / 1e12 - user.rewardDebt;
    }

    // Safe sh transfer function, just in case if rounding error causes pool to not have enough josss.
    function _safejossTransfer(address _to, uint256 _amount) internal {
        uint256 jossBal = jossToken.balanceOf(address(this));
        if (_amount > jossBal) {
            jossToken.transfer(_to, jossBal);
        } else {
            jossToken.transfer(_to, _amount);
        }
    }
}
