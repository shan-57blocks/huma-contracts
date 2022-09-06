//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import "./interfaces/ICredit.sol";
import {BaseStructs as BS} from "./libraries/BaseStructs.sol";

import "./BaseFeeManager.sol";
import "./BasePool.sol";

import "hardhat/console.sol";

contract BaseCreditPool is ICredit, BasePool, IERC721Receiver {
    // Divider to get monthly interest rate from APR BPS. 10000 * 12
    uint256 public constant BPS_DIVIDER = 120000;
    uint256 public constant HUNDRED_PERCENT_IN_BPS = 10000;
    uint256 public constant SECONDS_IN_A_YEAR = 31536000;

    using SafeERC20 for IERC20;
    using ERC165Checker for address;
    using BS for BS.CreditRecord;

    /// mapping from wallet address to the credit record
    mapping(address => BS.CreditRecord) public creditRecordMapping;
    /// mapping from wallet address to the receivable supplied by this wallet
    mapping(address => BS.ReceivableInfo) internal receivableInfoMapping;

    constructor(
        address _underlyingToken,
        address _humaConfig,
        address _feeManagerAddress,
        string memory _poolName
    ) BasePool(_underlyingToken, _humaConfig, _feeManagerAddress, _poolName) {}

    /**
     * @notice accepts a credit request from msg.sender
     * @param _creditLimit the credit line (number of pool token)
     * @param _intervalInDays duration of a payment cycle, typically 30 days
     * @param _numOfPayments number of cycles for the credit line to be valid.
     */
    function requestCredit(
        uint256 _creditLimit,
        uint256 _intervalInDays,
        uint256 _numOfPayments
    ) external virtual override {
        // todo _internalInDays and _numOfPayments are set by the pool owner.
        // Need to add these two in pool settings and remove them from the constructor parameter.

        // Open access to the borrower
        // Parameter and condition validation happens in initiate()
        initiate(
            msg.sender,
            _creditLimit,
            address(0),
            0,
            0,
            poolAprInBps,
            _intervalInDays,
            _numOfPayments
        );
    }

    /**
     * @notice initiation of a credit line
     * @param _borrower the address of the borrower
     * @param _creditLimit the amount of the liquidity asset that the borrower obtains
     * @param _receivableAsset the address of the receivable asset.
     * @param _receivableAmount the amount of the receivable asset
     */
    function initiate(
        address _borrower,
        uint256 _creditLimit,
        address _receivableAsset,
        uint256 _receivableParam,
        uint256 _receivableAmount,
        uint256 _aprInBps,
        uint256 _intervalInDays,
        uint256 _remainingPeriods
    ) internal virtual {
        protocolAndPoolOn();
        // Borrowers cannot have two credit lines in one pool. They can request to increase line.
        // todo add a test for this check
        require(creditRecordMapping[_borrower].creditLimit == 0, "CREDIT_LINE_ALREADY_EXIST");

        // Borrowing amount needs to be lower than max for the pool.
        require(maxCreditLine >= _creditLimit, "GREATER_THAN_LIMIT");

        // Populates basic credit info fields
        BS.CreditRecord memory cr;
        cr.creditLimit = uint96(_creditLimit);
        // note, leaving balance at the default 0, update balance only after drawdown
        cr.aprInBps = uint16(_aprInBps);
        cr.intervalInDays = uint16(_intervalInDays);
        cr.remainingPeriods = uint16(_remainingPeriods);
        cr.state = BS.CreditState.Requested;
        creditRecordMapping[_borrower] = cr;

        // Populates fields related to receivable
        if (_receivableAsset != address(0)) {
            BS.ReceivableInfo memory ci;
            ci.receivableAsset = _receivableAsset;
            ci.receivableParam = _receivableParam;
            ci.receivableAmount = uint88(_receivableAmount);
            receivableInfoMapping[_borrower] = ci;
        }
    }

    /**
     * Approves the credit request with the terms on record.
     * @dev only Evaluation Agent can call
     */
    function approveCredit(address _borrower) public virtual override {
        protocolAndPoolOn();
        onlyEvaluationAgents();

        BS.CreditRecord memory cr = creditRecordMapping[_borrower];
        require(cr.creditLimit <= maxCreditLine, "GREATER_THAN_LIMIT");

        creditRecordMapping[_borrower].state = BS.CreditState.Approved;
    }

    /**
     * @notice changes the limit of the borrower's credit line
     * @param _borrower the owner of the credit line
     * @param _newLine the new limit of the line in the unit of pool token
     * @dev only Evaluation Agent can call
     */
    function changeCreditLine(address _borrower, uint256 _newLine) external {
        protocolAndPoolOn();
        onlyEvaluationAgents();
        // Borrowing amount needs to be lower than max for the pool.
        require(maxCreditLine >= _newLine, "GREATER_THAN_LIMIT");
        require(_newLine >= minBorrowAmount, "SMALLER_THAN_LIMIT");

        require(creditRecordMapping[_borrower].creditLimit == 0, "CREDIT_LINE_NOT_EXIST");
        creditRecordMapping[_borrower].creditLimit = uint96(_newLine);
    }

    /**
     * @notice Invalidate the credit line
     * @dev If the credit limit is 0, we treat the line as deleted.
     */
    function invalidateApprovedCredit(address _borrower) external virtual override {
        protocolAndPoolOn();
        onlyEvaluationAgents();
        BS.CreditRecord memory cr = creditRecordMapping[_borrower];
        cr.state = BS.CreditState.Deleted;
        cr.creditLimit = 0;
        creditRecordMapping[_borrower] = cr;
    }

    function isApproved(address _borrower) external view virtual override returns (bool) {
        if ((creditRecordMapping[_borrower].state >= BS.CreditState.Approved)) return true;
        else return false;
    }

    /**
     * @notice allows the borrower to borrow against an approved credit line
     * The borrower can borrow and pay back as many times as they would like.
     * @param borrowAmount the amount to borrow
     */
    function drawdown(uint256 borrowAmount) external virtual override {
        // Open access to the borrower
        // Condition validation happens in drawdownWithReceivable()
        return drawdownWithReceivable(msg.sender, borrowAmount, address(0), 0, 0);
    }

    /**
     * @notice allows the borrower to borrow using a receivable / covenant
     * @param _borrower the borrower
     * @param _borrowAmount the amount to borrow
     * @param _receivableAsset the contract address of the receivable
     * @param _receivableParam is additional parameter of the receivable asset, such as NFT Tokenid
     * @param _receivableAmount the amount of the receivable asset
     */
    function drawdownWithReceivable(
        address _borrower,
        uint256 _borrowAmount,
        address _receivableAsset,
        uint256 _receivableParam,
        uint256 _receivableAmount
    ) public virtual override {
        protocolAndPoolOn();

        ///msg.sender needs to be the borrower themselvers or the EA.
        if (msg.sender != _borrower) onlyEvaluationAgents();

        // Borrowing amount needs to be higher than min for the pool.
        // 8/23 need to move some tests from requestCredit() to drawdown()
        require(_borrowAmount >= minBorrowAmount, "SMALLER_THAN_LIMIT");

        BS.CreditRecord memory cr = creditRecordMapping[_borrower];

        require(
            cr.state == BS.CreditState.Approved || cr.state == BS.CreditState.GoodStanding,
            "NOT_APPROVED_OR_IN_GOOD_STANDING"
        );

        // todo 8/23 add a test for this check
        // review cr.unbilledPrincipal is not all principal,
        // all principal is cr.unbilledPrincipal + cr.totalDue - cr.feesAndInterestDue
        require(_borrowAmount <= cr.creditLimit - cr.unbilledPrincipal, "EXCEEDED_CREDIT_LMIIT");

        // For the first drawdown, set the first due date exactly one billing cycle away
        // For existing credit line, the account might have been dormant for months.
        // Bring the account current by moving forward cycles to allow the due date of
        // the current cycle to be ahead of block.timestamp.
        if (cr.dueDate == 0) {
            cr.dueDate = uint64(block.timestamp + uint256(cr.intervalInDays) * SECONDS_IN_A_DAY);
        } else if (block.timestamp > cr.dueDate) {
            uint256 periodsPassed;
            (periodsPassed, , cr) = _updateDueInfo(_borrower);

            require(cr.remainingPeriods > 0, "CREDIT_LINE_EXPIRED");

            // review check if state is delayed? and credit limit again?
        }

        cr.unbilledPrincipal = uint96(uint256(cr.unbilledPrincipal) + _borrowAmount);

        // With drawdown, balance increases, interest charge will be higher than it should be,
        // thus record a negative correction to compensate it at the end of the period
        cr.correction -= int96(
            uint96(IFeeManager(feeManagerAddress).calcCorrection(cr, _borrowAmount))
        );

        // Set account status in good standing
        cr.state = BS.CreditState.GoodStanding;

        creditRecordMapping[_borrower] = cr;

        (uint256 amtToBorrower, uint256 protocolFee, uint256 poolIncome) = IFeeManager(
            feeManagerAddress
        ).distBorrowingAmount(_borrowAmount, humaConfig);

        if (poolIncome > 0) distributeIncome(poolIncome);

        // Record the receivable info.
        if (_receivableAsset != address(0)) {
            BS.ReceivableInfo memory ci = receivableInfoMapping[_borrower];
            if (ci.receivableAsset != address(0)) {
                // review remove _receivableAsset, _receivableParam and _receivableAmount parameters,
                // use data in cr directly
                require(_receivableAsset == ci.receivableAsset, "COLLATERAL_MISMATCH");
            }

            // todo only do this at the first time,
            // Need to add periodForFirstDrawn(), if not completed, the credit line is invalidated.
            if (_receivableAsset.supportsInterface(type(IERC721).interfaceId)) {
                IERC721(_receivableAsset).safeTransferFrom(
                    _borrower,
                    address(this),
                    _receivableParam
                );
            } else if (_receivableAsset.supportsInterface(type(IERC20).interfaceId)) {
                IERC20(_receivableAsset).safeTransferFrom(
                    _borrower,
                    address(this),
                    _receivableAmount
                );
            } else {
                revert("COLLATERAL_ASSET_NOT_SUPPORTED");
            }

            // todo check to make sure the receivable amount meets the requirements
            ci.receivableAmount = uint88(_receivableAmount);
            ci.receivableParam = _receivableParam;
            receivableInfoMapping[_borrower] = ci;
        }

        // Transfer protocole fee and funds the _borrower
        address treasuryAddress = HumaConfig(humaConfig).humaTreasury();
        underlyingToken.safeTransfer(treasuryAddress, protocolFee);
        underlyingToken.safeTransfer(_borrower, amtToBorrower);
    }

    /**
     * @notice Borrower makes one payment. If this is the final payment,
     * it automatically triggers the payoff process.
     * @dev "WRONG_ASSET" reverted when asset address does not match
     * @dev "AMOUNT_TOO_LOW" reverted when the asset is short of the scheduled payment and fees
     */
    function makePayment(
        address _borrower,
        address _asset,
        uint256 _amount
    ) external virtual override {
        protocolAndPoolOn();

        require(_asset == address(underlyingToken), "WRONG_ASSET");
        require(_amount > 0, "CANNOT_BE_ZERO_AMOUNT");

        // Bring the account current. This is necessary since the account might have been dormant for
        // several cycles.
        (uint256 periodsPassed, uint96 payoffAmount, BS.CreditRecord memory cr) = _updateDueInfo(
            _borrower
        );

        // How many amount will be applied towards principal
        uint256 principalPayment = 0;

        // The amount to be collected from the borrower. When _amount is more than what is needed
        // for payoff, only the payoff amount will be transferred
        uint256 amountToCollect;

        if (_amount < cr.totalDue) {
            amountToCollect = _amount;
            cr.totalDue = uint96(cr.totalDue - _amount);

            if (_amount <= cr.feesAndInterestDue) {
                cr.feesAndInterestDue = uint96(cr.feesAndInterestDue - _amount);
            } else {
                principalPayment = _amount - cr.feesAndInterestDue;
                cr.feesAndInterestDue = 0;
            }
        } else {
            if (_amount < payoffAmount) {
                amountToCollect = _amount;
                principalPayment = _amount - cr.feesAndInterestDue;
                cr.unbilledPrincipal = uint96(cr.unbilledPrincipal - (_amount - cr.totalDue));
            } else {
                amountToCollect = payoffAmount;
                principalPayment = cr.unbilledPrincipal + cr.totalDue - cr.feesAndInterestDue;
                cr.unbilledPrincipal = 0;
            }
            cr.feesAndInterestDue = 0;
            cr.totalDue = 0;
            cr.missedPeriods = 0;
            cr.state = BS.CreditState.GoodStanding;
        }

        // Correction is used when moving to a new payment cycle, ready for reset.
        // However, correction has not been used if it is still the same cycle, cannot reset
        if (periodsPassed > 0) cr.correction = 0;

        // If there is principal payment, calcuate new correction
        if (principalPayment > 0) {
            cr.correction += int96(
                uint96(IFeeManager(feeManagerAddress).calcCorrection(cr, principalPayment))
            );
        }

        // `payoffAmount` includes interest for the final billing period.
        // If the user pays off before the end of the cycle, we will subtract
        // the `correction` amount in the transfer.
        if (amountToCollect == payoffAmount) {
            // review this logic seems not right
            // correction is for multiple drawdowns or payments, different from payoff interest

            // todo fix issue if there is any, and at least find a cleaner solution
            amountToCollect = amountToCollect - uint256(uint96(cr.correction));
            cr.correction = 0;
        }

        creditRecordMapping[_borrower] = cr;

        // Distribute income
        // todo need to apply logic for protocol fee
        if (cr.feesAndInterestDue > amountToCollect) distributeIncome(cr.feesAndInterestDue);
        else distributeIncome(amountToCollect);

        if (amountToCollect > 0) {
            // Transfer assets from the _borrower to pool locker
            underlyingToken.safeTransferFrom(msg.sender, address(this), amountToCollect);
        }
    }

    /**
     * @notice updates CreditRecord for `_borrower` using the most up to date information.
     * @dev this is used in both makePayment() and drawdown() to bring the account current
     * @dev getDueInfo() gets the due information of the most current cycle. This function
     * updates the record in creditRecordMapping for `_borrower`
     */
    function _updateDueInfo(address _borrower)
        internal
        virtual
        returns (
            uint256 periodsPassed,
            uint96 payoffAmount,
            BS.CreditRecord memory cr
        )
    {
        cr = creditRecordMapping[_borrower];

        // Gets the up-to-date due information for the borrower. If the account has been
        // late or dormant for multiple cycles, getDueInfo() will bring it current and
        // return the most up-to-date due information.
        (
            periodsPassed,
            cr.feesAndInterestDue,
            cr.totalDue,
            payoffAmount,
            cr.unbilledPrincipal
        ) = IFeeManager(feeManagerAddress).getDueInfo(cr);


        if (periodsPassed > 0) {
            cr.dueDate = uint64(cr.dueDate + periodsPassed * cr.intervalInDays * SECONDS_IN_A_DAY);
            // Adjusts remainingPeriods, special handling when reached the maturity of the credit line 
            if (cr.remainingPeriods > periodsPassed) {
                cr.remainingPeriods = uint16(cr.remainingPeriods - periodsPassed);
            }
            else {
                cr.remainingPeriods = 0;
                cr.creditLimit = 0;
            }

            // Sets the right missedPeriods and state for the credit record 
            if (cr.totalDue > 0) {
                // note the design of missedPeriods is awkward. need to find a simpler solution
                cr.missedPeriods = uint16(cr.missedPeriods + periodsPassed - 1);
                if (cr.missedPeriods > 0) cr.state = BS.CreditState.Delayed;
            } else {
                // When totalDue has been paid, the account is in good standing
                cr.missedPeriods = 0;
                cr.state = BS.CreditState.GoodStanding;
            }
            creditRecordMapping[_borrower] = cr;
        }
    }

    /**
     * @notice Triggers the default process
     * @return losses the amount of remaining losses to the pool after receivable
     * liquidation, pool cover, and staking.
     */
    function triggerDefault(address borrower) external virtual override returns (uint256 losses) {
        protocolAndPoolOn();
        // todo add security check

        // check to make sure the default grace period has passed.
        require(
            block.timestamp >
                creditRecordMapping[borrower].dueDate + poolDefaultGracePeriodInSeconds,
            "DEFAULT_TRIGGERED_TOO_EARLY"
        );

        // FeatureRequest: add pool cover logic

        // FeatureRequest: add staking logic

        // Trigger loss process
        // todo double check if we need to include fees into losses
        BS.CreditRecord memory cr = creditRecordMapping[borrower];
        losses = cr.unbilledPrincipal + cr.totalDue;
        distributeLosses(losses);

        return losses;
    }

    function extendCreditLineDuration(address borrower, uint256 numOfPeriods) external {
        onlyEvaluationAgents();
        creditRecordMapping[borrower].remainingPeriods += uint16(numOfPeriods);
    }

    function onERC721Received(
        address, /*operator*/
        address, /*from*/
        uint256, /*tokenId*/
        bytes calldata /*data*/
    ) external virtual override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    /**
     * @notice Gets high-level information about the loan.
     */
    // review remove it to use default getter creditRecordMapping(address)
    function getCreditInformation(address borrower)
        external
        view
        returns (
            uint96 creditLimit,
            uint96 totalDue,
            uint64 intervalInDays,
            uint16 aprInBps,
            uint64 dueDate,
            uint96 balance,
            uint16 remainingPeriods,
            BS.CreditState state
        )
    {
        BS.CreditRecord memory cr = creditRecordMapping[borrower];
        return (
            cr.creditLimit,
            cr.totalDue,
            cr.intervalInDays,
            cr.aprInBps,
            cr.dueDate,
            cr.unbilledPrincipal,
            cr.remainingPeriods,
            cr.state
        );
    }

    // review it is duplicated to isApproved, remove which one?
    function getApprovalStatusForBorrower(address borrower) external view returns (bool) {
        return creditRecordMapping[borrower].state >= BS.CreditState.Approved;
    }

    function onlyEvaluationAgents() internal view {
        require(evaluationAgents[msg.sender] == true, "APPROVER_REQUIRED");
    }
}
