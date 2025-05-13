// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

/**
 * @title Advanced Yield Aggregator with Auto-Compounding
 * @notice Automatically compounds rewards from multiple DeFi protocols
 * @dev Supports multiple vault strategies with fee management
 */
contract YieldAggregator is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // Structs
    struct Vault {
        uint256 pid;
        address strategy;
        address want;
        string name;
        bool active;
        uint256 totalShares;
        uint256 lastCompound;
        uint256 totalCompound;
        uint256 performanceFee;
        uint256 withdrawalFee;
    }

    struct UserInfo {
        uint256 shares;
        uint256 lastDeposit;
        uint256 rewardDebt;
    }

    // Constants
    uint256 public constant FEE_DENOMINATOR = 10000;
    uint256 public constant MAX_PERFORMANCE_FEE = 2000; // 20%
    uint256 public constant MAX_WITHDRAWAL_FEE = 100;   // 1%
    uint256 public constant MIN_COMPOUND_INTERVAL = 30 minutes;

    // State variables
    Vault[] public vaults;
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    address public feeRecipient;
    uint256 public totalUsers;

    // Events
    event Deposit(address indexed user, uint256 vaultId, uint256 amount);
    event Withdraw(address indexed user, uint256 vaultId, uint256 amount);
    event Compound(uint256 vaultId, uint256 amount);
    event VaultAdded(uint256 vaultId, address strategy, address want);
    event VaultUpdated(uint256 vaultId, bool active);
    event FeesUpdated(uint256 vaultId, uint256 performanceFee, uint256 withdrawalFee);
    event EmergencyWithdraw(address indexed user, uint256 vaultId, uint256 amount);

    constructor(address _feeRecipient) {
        require(_feeRecipient != address(0), "Invalid fee recipient");
        feeRecipient = _feeRecipient;
    }

    /**
     * @notice Deposit funds into a vault
     * @param _vaultId The ID of the vault
     * @param _amount The amount of tokens to deposit
     */
    function deposit(uint256 _vaultId, uint256 _amount) external nonReentrant {
        require(_vaultId < vaults.length, "Invalid vault ID");
        Vault storage vault = vaults[_vaultId];
        require(vault.active, "Vault not active");

        _compound(_vaultId);

        IERC20 want = IERC20(vault.want);
        uint256 before = want.balanceOf(address(this));
        want.safeTransferFrom(msg.sender, address(this), _amount);
        uint256 after_ = want.balanceOf(address(this));
        _amount = after_.sub(before); // Additional check for deflationary tokens

        UserInfo storage user = userInfo[_vaultId][msg.sender];
        if (user.shares == 0) {
            totalUsers = totalUsers.add(1);
        }

        uint256 sharesAdded = _amount;
        if (vault.totalShares > 0) {
            sharesAdded = _amount.mul(vault.totalShares).div(want.balanceOf(vault.strategy));
        }

        user.shares = user.shares.add(sharesAdded);
        user.lastDeposit = block.timestamp;
        vault.totalShares = vault.totalShares.add(sharesAdded);

        want.safeTransfer(vault.strategy, _amount);

        emit Deposit(msg.sender, _vaultId, _amount);
    }

    /**
     * @notice Withdraw funds from a vault
     * @param _vaultId The ID of the vault
     * @param _shares The number of shares to withdraw
     */
    function withdraw(uint256 _vaultId, uint256 _shares) external nonReentrant {
        require(_vaultId < vaults.length, "Invalid vault ID");
        Vault storage vault = vaults[_vaultId];
        UserInfo storage user = userInfo[_vaultId][msg.sender];

        require(_shares > 0 && _shares <= user.shares, "Invalid share amount");

        _compound(_vaultId);

        uint256 wantAmount = _shares.mul(IERC20(vault.want).balanceOf(vault.strategy)).div(vault.totalShares);
        vault.totalShares = vault.totalShares.sub(_shares);
        user.shares = user.shares.sub(_shares);

        uint256 withdrawalFee = 0;
        if (block.timestamp < user.lastDeposit.add(1 days) {
            withdrawalFee = wantAmount.mul(vault.withdrawalFee).div(FEE_DENOMINATOR);
            wantAmount = wantAmount.sub(withdrawalFee);
        }

        IStrategy(vault.strategy).withdraw(wantAmount);

        IERC20 want = IERC20(vault.want);
        if (withdrawalFee > 0) {
            want.safeTransfer(feeRecipient, withdrawalFee);
        }
        want.safeTransfer(msg.sender, wantAmount);

        emit Withdraw(msg.sender, _vaultId, wantAmount);
    }

    /**
     * @notice Compound rewards for a specific vault
     * @param _vaultId The ID of the vault to compound
     */
    function compound(uint256 _vaultId) external nonReentrant {
        require(_vaultId < vaults.length, "Invalid vault ID");
        _compound(_vaultId);
    }

    /**
     * @notice Internal compound function
     * @param _vaultId The ID of the vault to compound
     */
    function _compound(uint256 _vaultId) internal {
        Vault storage vault = vaults[_vaultId];
        if (block.timestamp < vault.lastCompound.add(MIN_COMPOUND_INTERVAL)) {
            return;
        }

        uint256 before = IERC20(vault.want).balanceOf(vault.strategy);
        IStrategy(vault.strategy).harvest();
        uint256 after_ = IERC20(vault.want).balanceOf(vault.strategy);

        if (after_ > before) {
            uint256 profit = after_.sub(before);
            uint256 feeAmount = profit.mul(vault.performanceFee).div(FEE_DENOMINATOR);
            if (feeAmount > 0) {
                IStrategy(vault.strategy).withdraw(feeAmount);
                IERC20(vault.want).safeTransfer(feeRecipient, feeAmount);
            }
            vault.lastCompound = block.timestamp;
            vault.totalCompound = vault.totalCompound.add(1);
            emit Compound(_vaultId, profit);
        }
    }

    // Admin functions
    /**
     * @notice Add a new vault
     * @param _strategy The strategy contract address
     * @param _want The want token address
     * @param _name The name of the vault
     * @param _performanceFee The performance fee (0-2000)
     * @param _withdrawalFee The withdrawal fee (0-100)
     */
    function addVault(
        address _strategy,
        address _want,
        string memory _name,
        uint256 _performanceFee,
        uint256 _withdrawalFee
    ) external onlyOwner {
        require(_strategy != address(0), "Invalid strategy");
        require(_want != address(0), "Invalid want token");
        require(_performanceFee <= MAX_PERFORMANCE_FEE, "Performance fee too high");
        require(_withdrawalFee <= MAX_WITHDRAWAL_FEE, "Withdrawal fee too high");

        vaults.push(Vault({
            pid: vaults.length,
            strategy: _strategy,
            want: _want,
            name: _name,
            active: true,
            totalShares: 0,
            lastCompound: block.timestamp,
            totalCompound: 0,
            performanceFee: _performanceFee,
            withdrawalFee: _withdrawalFee
        }));

        emit VaultAdded(vaults.length - 1, _strategy, _want);
    }

    /**
     * @notice Update vault status
     * @param _vaultId The ID of the vault
     * @param _active The new active status
     */
    function updateVault(uint256 _vaultId, bool _active) external onlyOwner {
        require(_vaultId < vaults.length, "Invalid vault ID");
        vaults[_vaultId].active = _active;
        emit VaultUpdated(_vaultId, _active);
    }

    /**
     * @notice Update vault fees
     * @param _vaultId The ID of the vault
     * @param _performanceFee The new performance fee
     * @param _withdrawalFee The new withdrawal fee
     */
    function updateFees(
        uint256 _vaultId,
        uint256 _performanceFee,
        uint256 _withdrawalFee
    ) external onlyOwner {
        require(_vaultId < vaults.length, "Invalid vault ID");
        require(_performanceFee <= MAX_PERFORMANCE_FEE, "Performance fee too high");
        require(_withdrawalFee <= MAX_WITHDRAWAL_FEE, "Withdrawal fee too high");

        vaults[_vaultId].performanceFee = _performanceFee;
        vaults[_vaultId].withdrawalFee = _withdrawalFee;

        emit FeesUpdated(_vaultId, _performanceFee, _withdrawalFee);
    }

    /**
     * @notice Update fee recipient
     * @param _feeRecipient The new fee recipient address
     */
    function updateFeeRecipient(address _feeRecipient) external onlyOwner {
        require(_feeRecipient != address(0), "Invalid fee recipient");
        feeRecipient = _feeRecipient;
    }

    /**
     * @notice Emergency withdraw from a vault without caring about rewards
     * @param _vaultId The ID of the vault
     */
    function emergencyWithdraw(uint256 _vaultId) external nonReentrant {
        require(_vaultId < vaults.length, "Invalid vault ID");
        Vault storage vault = vaults[_vaultId];
        UserInfo storage user = userInfo[_vaultId][msg.sender];

        uint256 wantAmount = user.shares.mul(IERC20(vault.want).balanceOf(vault.strategy)).div(vault.totalShares);
        vault.totalShares = vault.totalShares.sub(user.shares);
        user.shares = 0;

        IStrategy(vault.strategy).withdraw(wantAmount);
        IERC20(vault.want).safeTransfer(msg.sender, wantAmount);

        emit EmergencyWithdraw(msg.sender, _vaultId, wantAmount);
    }

    // View functions
    /**
     * @notice Get vault count
     * @return The number of vaults
     */
    function vaultCount() external view returns (uint256) {
        return vaults.length;
    }

    /**
     * @notice Get user shares in a vault
     * @param _vaultId The ID of the vault
     * @param _user The user address
     * @return The number of shares
     */
    function getUserShares(uint256 _vaultId, address _user) external view returns (uint256) {
        return userInfo[_vaultId][_user].shares;
    }

    /**
     * @notice Calculate pending rewards for a user
     * @param _vaultId The ID of the vault
     * @param _user The user address
     * @return The pending reward amount
     */
    function pendingReward(uint256 _vaultId, address _user) external view returns (uint256) {
        require(_vaultId < vaults.length, "Invalid vault ID");
        Vault memory vault = vaults[_vaultId];
        UserInfo memory user = userInfo[_vaultId][_user];

        if (user.shares == 0) return 0;

        uint256 totalWant = IERC20(vault.want).balanceOf(vault.strategy);
        uint256 sharesTotal = vault.totalShares;
        if (sharesTotal == 0) return 0;

        return user.shares.mul(totalWant).div(sharesTotal).sub(user.rewardDebt);
    }
}

interface IStrategy {
    function harvest() external;
    function withdraw(uint256) external;
    function balanceOf() external view returns (uint256);
}
