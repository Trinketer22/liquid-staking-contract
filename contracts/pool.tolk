import "@stdlib/tvm-dicts"

import "types.tolk"
import "op-codes.tolk"
import "errors.tolk"
import "globals.tolk"
import "messages.tolk"
import "asserts.tolk"
import "sudoer_requests.tolk"
import "address_calculations.tolk"
import "network_config_utils.tolk"


// Whole storage is put to global variables

global total_balance: int;
global interest_rate: int; // times SHARE_BASIS == 2**24
// optimistic_deposit_withdrawals, deposits_open?, instant_withdrawal_fee (time SHARE_BASIS)
global deposit_withdrawal_parameters: [bool, bool, int];
global saved_validator_set_hash: int;

// [borrowers_dict, round_id, active_borrowers, borrowed, expected, returned, profit]
global current_round_borrowers: [cell?, int, int, int, int, int, int];
global prev_round_borrowers: [cell?, int, int, int, int, int, int];

//[min, max]
global loan_params_per_validator: [int, int];
global governance_fee_share: int; // times SHARE_BASIS == 2**24
global accrued_governance_fee: int;
global disbalance_tolerance: int;
global credit_start_prior_elections_end: int;

// Basic jetton that represents share of the pool
global jetton_minter: slice;
global supply: int;

global deposit_payout: slice?;
global requested_for_deposit: int;    // in TONs
global withdrawal_payout: slice?;
global requested_for_withdrawal: int; // in jettons

// ROLES
/*
pack all roles to one global variable
    sudoer;            ;; has right to send any message on behalf of any contract
    int sudoer_set_at;
    governor;          ;; sets roles, unhalt and get reward
    int governor_update_after;
    interest_manager;  ;; gets round stats and update interest
    halter;            ;; halts operation
    approver;          ;; approves controllers to ask for credit
    treasury;          ;; receives all the fees
*/
import "roles_helper.tolk"
// global roles: [slice, int, slice, int, slice, slice, slice, slice];

// CHILD CONTRACT CODES
// [controller_code, pool_jetton_wallet_code, payout_minter_code]
// global child_contract_codes: [cell, cell, cell];


// temporal variables (not saved to storage)
global sent_during_rotation: int;
global is_current_round_closed: bool; // hash of validator set changed since round start

const `state::NORMAL` = 0;


const DISBALANCE_BIT_SIZE = 8;
const DISBALANCE_TOLERANCE_BASIS = 2 << DISBALANCE_BIT_SIZE; // 2 and not 1 is intentional
const JETTONS_WORKCHAIN = 0;
const MAX_LOAN_DICT_DEPTH = 12;

// const ONE_TON = 1000000000;
const MIN_TONS_FOR_STORAGE = 10 * ONE_TON; // 10 TON
const CONTROLLER_WORKCHAIN = MASTERCHAIN;

const SERVICE_NOTIFICATION_AMOUNT = 2 * ONE_TON / 100;
// finalize fee goes to
//   a) SERVICE_NOTIFICATION_AMOUNT to interest manager
//   b) TRANSFER_NOTIFICATION_AMOUNT for ton distribution start
//   c) TRANSFER_NOTIFICATION_AMOUNT + POOL_JETTON_WALLET_FEE + POOL_JETTON_MINT_FEE for jetton distribution
//   d) Gas fees
const FINALIZE_ROUND_FEE = ONE_TON;
const DEPOSIT_FEE = ONE_TON;
const WITHDRAWAL_FEE = ONE_TON / 2;
const TRANSFER_NOTIFICATION_AMOUNT = ONE_TON / 10;
const MAX_POOL_GAS_ON_USER_ACTION = ONE_TON / 3;
const PAYOUT_DISTRIBUTION_AMOUNT = ONE_TON / 5; // we will get excesses back
const MINTER_DEPLOY_FEE = ONE_TON / 10;

const GOVERNOR_QUARANTINE = 86400; // 1 day
import "pool_storage.tolk"


 // called from close_loan
 // called from finalize_lending_round




@pure
fun roundIdFromRoundData<X, Y>(p: X): Y
    asm "SECOND";
@inline
fun currentRoundIndex(): int {
    //var [borrowers_dict, round_id, active_borrowers, borrowed, expected, returned, profit] = current_round_borrowers;
    //return round_id;
    return roundIdFromRoundData(current_round_borrowers);
}
/*
    () request_to_mint_pool_jettons(slice destination, int amount, int query_id, int for_user?) impure;
    () request_to_mint_deposit(slice destination, int amount, int query_id) impure;
    () request_to_mint_withdrawal(slice destination, int amount, int query_id) impure;
*/
import "pool_mint_helpers.tolk"



// special muldiv which is friendly for b == c == 0
@inline
fun muldivExtra(a: int, b: int, c: int): int {
    if(b == c) {
      return a;
    }
    return mulDivFloor(a, b, c);
}

@inline_ref
fun updateRound(availableBalance: int) {
    sent_during_rotation = 0;
    if(is_halted) {
        return;
    }
    var (utimeSince: int, utimeUntil: int, vset: cell) = getCurrentValidatorSet();
    var currentHash: int = cellHash(vset);
    if (saved_validator_set_hash != currentHash) {

        var [borrowersDict, roundId, activeBorrowers, borrowed, expected, returned, profit] = prev_round_borrowers;

        if((borrowersDict != null) || (activeBorrowers > 0)) {
            is_current_round_closed = true;
            return;
        }
        untouched_data = null;
        prev_round_borrowers.finalizeLendingRound(availableBalance);

        saved_validator_set_hash = currentHash;
        var roundIndex: int = currentRoundIndex() + 1;
        logRoundRotation(roundIndex);
        (prev_round_borrowers, current_round_borrowers) = (current_round_borrowers, [null, roundIndex, 0, 0, 0, 0, 0]);
        is_current_round_closed = false;
    } else {
        is_current_round_closed = false;
    }
}

fun onInternalMessage(balance: int, msgValue: int, inMsgFull: cell, inMsgBody: slice) {
    var cs: slice = inMsgFull.beginParse();
    var flags: int = cs.loadUint(4);

    var senderAddress: slice = cs.loadAddress();
    loadData();
    var op: int = -1;
    var queryId: int = -1;
    if (flags & 1) { // bounced messages
        // generally all bounces are either insignificant or unexpected
        // and require manual recover. However we can try automatically
        // handle credit bounce
        inMsgBody.skipBounce();
        (op, queryId) = inMsgBody.loadBodyHeader();
        if(op == `controller::credit`) {
            // just reassing op and process as usual
            op = `pool::loan_repayment`;
        }
    } else {
      (op, queryId) = inMsgBody.loadBodyHeader();
    }

    if (op == `halter::halt`) {
        // we do not end_parse here, because unprocessed data
        // in message maybe used for reason in offchain analytics
        `assert_sender!`(senderAddress, getHalter(roles));
        is_halted = true;
    } else if (op == `pool::withdraw`) {
        `assert_sender!`(senderAddress, jetton_minter);
        var jettonAmount: int = inMsgBody.loadCoins();
        var fromAddress: slice = inMsgBody.loadAddress();
        // Send to response address if it is in correct workchain
        var responseAddress: slice = inMsgBody.loadAddress();
        if (!((responseAddress.getRemainingBitsCount() == 267) & (responseAddress.preloadUint(11) == 0x400))) {
            //addr_std$10 anycast:(Maybe Anycast) workchain_id:int8 address:bits256  = MsgAddressInt;
            // 0x400 = 0b10'0'00000000 == standard address in basechain
            responseAddress = fromAddress;
        }
        // after that point we should not revert because jettons should not be lost
        try {
            assert(msgValue > WITHDRAWAL_FEE) throw `error::not_enough_TON_to_process`;
            var requestImmediateWithdrawalIfPossible: bool = !inMsgBody.loadBool();
            var fillOrKill: bool = inMsgBody.loadBool();
            inMsgBody.assertEndOfSlice();
            updateRound(getMyOriginalBalance() - msgValue);
            `assert_not_halted!`(); // otherwise mint back
            var approximateAmount: int = mulDivFloor(jettonAmount, total_balance, supply);
            var availableFunds: int = balance - msgValue - MIN_TONS_FOR_STORAGE - sent_during_rotation;
            var [optimisticDepositWithdrawals: bool,
             _, instantWithdrawalFee: int] = deposit_withdrawal_parameters;
            if(optimisticDepositWithdrawals &
                    requestImmediateWithdrawalIfPossible &
                    (state == `state::NORMAL`) &
                    (availableFunds > approximateAmount)) {
                assert(approximateAmount > 0) throw `error::output_amount_is_zero`;
                total_balance -= approximateAmount;
                supply -= jettonAmount;

                var additionalFee: int = 0;
                if(instantWithdrawalFee > 0) {
                    additionalFee = mulDivFloor(approximateAmount,
                                            instantWithdrawalFee,
                                            SHARE_BASIS);
                    accrued_governance_fee += additionalFee;
                }

                reserveToncoinsOnBalance(balance - msgValue - approximateAmount - sent_during_rotation + additionalFee, `reservemode::STRICT`);
                availableFunds -= approximateAmount;
                var msg = beginCell()
                        .storeMsgFlags(`msgflag::NON_BOUNCEABLE`)
                        .storeSlice(responseAddress)
                        .storeCoins(0)
                        .storeMsgbodyPrefixSlice()
                        .storeBodyHeader(`pool::withdrawal`, queryId);
                sendRawMessage(msg.endCell(), `sendmode::CARRY_ALL_BALANCE`);
            } else {
                assert(!(fillOrKill)) throw 105;
                assert(jettonAmount) throw `error::output_amount_is_zero`;
                reserveToncoinsOnBalance(balance - msgValue - sent_during_rotation, `reservemode::STRICT`);
                requestToMintWithdrawal(responseAddress, jettonAmount, queryId);
            }
            //  conservatively use `borrowed` instead of `expected` as amount that will be returned
            var [_, _, _, borrowed, _, _, _] = prev_round_borrowers;

            // max(*, 0) is needed because optimistic withdrawals do not participate in sharing -FINALIZE_ROUND_FEE
            // When we have both optimistic and pessimistic withdrawals it is ok: pessimists will get both
            // FINALIZE_ROUND_FEE loss and pool round profit. The only problem is when optimists withdraw 100% value
            // and there is no profit to cover FINALIZE_ROUND_FEE. In this case available_funds may become negative
            // and max(*,0) helps with that

            var fundsAtRoundEnd: int = max(availableFunds + borrowed - FINALIZE_ROUND_FEE, 0);
            var (projectedBalance: int, projectedSupply: int) = GetProjectedConversionRatio ();
            assert(fundsAtRoundEnd >= muldivExtra(requested_for_withdrawal, projectedBalance, projectedSupply)) throw 100;
        } catch (exc_num, exc_arg) {
            // note that sent_during_rotation is null because
            // effect of update_round is reverted in catch
            reserveToncoinsOnBalance(balance - msgValue, `reservemode::STRICT`);
            // request_to_mint automatically increase supply by minted amount
            // however there is no extra tokens in this case
            supply -= jettonAmount;
            requestToMintPoolJettons(fromAddress, jettonAmount, queryId, true);
        }

    /* ========== Governance operations ========== */
    } else if (op == `sudo::send_message`) {
                processSudoRequest(senderAddress, inMsgBody,
                              getSudoer(roles), getSudoerSetAt(roles));
    } else if (op == `sudo::upgrade`) {
        processSudoUpgradeRequest(senderAddress, inMsgBody,
                                     getSudoer(roles), getSudoerSetAt(roles));
    } else if (op == `governor::set_sudoer`) {
                `assert_sender!`(senderAddress, getGovernor(roles));
                setSudoerSetAt(now());
                setSudoer(inMsgBody.loadAddress());
                inMsgBody.assertEndOfSlice();
    } else if (op == `governor::unhalt`) {
        `assert_sender!`(senderAddress, getGovernor(roles));
        is_halted = false;
        inMsgBody.assertEndOfSlice();
    } else if (op == `governor::prepare_governance_migration`) {
        `assert_sender!`(senderAddress, getGovernor(roles));
        var governorUpdateAfter: int = inMsgBody.loadTimestamp();
        setGovernorUpdateAfter(governorUpdateAfter);
        assert(governorUpdateAfter - now() > GOVERNOR_QUARANTINE) throw `error::governor_update_too_soon`;
        inMsgBody.assertEndOfSlice();
    } else if (op == `governor::set_roles`) {
                `assert_sender!`(senderAddress, getGovernor(roles));
                if(inMsgBody.loadBool()) {
                    assert(getGovernorUpdateAfter(roles) < now()) throw `error::governor_update_not_matured`;
                    setGovernor(inMsgBody.loadAddress());
                    setGovernorUpdateAfter(0xffffffffffff);
                }
                if(inMsgBody.loadBool()) {
                    setInterestManager(inMsgBody.loadAddress());
                }
                if(inMsgBody.loadBool()) {
                    setHalter(inMsgBody.loadAddress());
                }
                if(inMsgBody.loadBool()) {
                    setApprover(inMsgBody.loadAddress());
                }
                if(inMsgBody.getRemainingBitsCount()) {
                  if(inMsgBody.loadBool()) {
                      setTreasury(inMsgBody.loadAddress());
                  }
                }
                inMsgBody.assertEndOfSlice();
    } else if(op == `governor::set_deposit_settings`) {
                `assert_sender!`(senderAddress, getGovernor(roles));
                var optimisticDepositWithdrawals: bool = inMsgBody.loadBool();
                var isDepositsOpen: bool = inMsgBody.loadBool();
                var instantWithdrawalFee: int = inMsgBody.loadShare();
                deposit_withdrawal_parameters = [optimisticDepositWithdrawals,
                                                 isDepositsOpen,
                                                 instantWithdrawalFee];
                inMsgBody.assertEndOfSlice();
    } else if(op == `governor::set_governance_fee`) {
                `assert_sender!`(senderAddress, getGovernor(roles));
                governance_fee_share = inMsgBody.loadShare();
                inMsgBody.assertEndOfSlice();
    } else if (op == `interest_manager::set_interest`) {
        `assert_state!`(`state::NORMAL`);
        `assert_sender!`(senderAddress, getInterestManager(roles));
        interest_rate = inMsgBody.loadShare();
        inMsgBody.assertEndOfSlice();
    } else if (op == `interest_manager::set_operational_params`) {
        `assert_state!`(`state::NORMAL`);
        `assert_sender!`(senderAddress, getInterestManager(roles));
        var minLoanPerValidator: int = inMsgBody.loadCoins();
        var maxLoanPerValidator: int = inMsgBody.loadCoins();
        assert(maxLoanPerValidator >= minLoanPerValidator) throw `error::contradicting_operational_params`;
        loan_params_per_validator = [minLoanPerValidator, maxLoanPerValidator];
        disbalance_tolerance = inMsgBody.loadUint(DISBALANCE_BIT_SIZE);
        credit_start_prior_elections_end = inMsgBody.loadTimestamp();
        inMsgBody.assertEndOfSlice();
    } else if (op == `halter::partial_halt`) {
        `assert_sender!`(senderAddress, getHalter(roles));
        var stopOptimistic: bool = inMsgBody.loadBool();
        var closeDeposits: bool = inMsgBody.loadBool();
        inMsgBody.assertEndOfSlice();
        var [optimisticDepositWithdrawals: bool,
         isDepositsOpen: bool,
         instantWithdrawalFee: int] = deposit_withdrawal_parameters;
        if (stopOptimistic) {
            optimisticDepositWithdrawals = false;
        }
        if (closeDeposits) {
            isDepositsOpen = false;
        }
        deposit_withdrawal_parameters = [optimisticDepositWithdrawals,
                                         isDepositsOpen,
                                         instantWithdrawalFee];
    } else {
        updateRound(getMyOriginalBalance() - msgValue);
        `assert_not_halted!`();
        // it is ok, controller know how to process loan_repayment/request_loan bounces
        /* ========== Pool operations ========== */
        if (op == `pool::deposit`) {
                // we do not end_parse here, because apps may use
                // unprocessed data in depositd message for offchain analytics
                `assert_state!`(`state::NORMAL`);
                var [optimisticDepositWithdrawals: bool,
                 isDepositsOpen: bool,
                 instantWithdrawalFee: int
                ] = deposit_withdrawal_parameters;
                assert(isDepositsOpen) throw `error::deposits_are_closed`;
                reserveToncoinsOnBalance(balance - DEPOSIT_FEE - sent_during_rotation, `reservemode::STRICT`);
                var depositAmount: int = msgValue - DEPOSIT_FEE;
                assert(depositAmount > 0) throw `error::deposit_amount_too_low`;
                if(optimisticDepositWithdrawals) {
                    // we convert TON to Jetton at projected (expected) price at the round end
                    var (expectedBalance: int, expectedSupply: int) = GetProjectedConversionRatio();

                    var amount: int = muldivExtra(depositAmount, expectedSupply, expectedBalance);
                    assert(amount) throw `error::output_amount_is_zero`;
                    requestToMintPoolJettons(senderAddress, amount, queryId, true);
                    total_balance += depositAmount;
                } else {
                    requestToMintDeposit(senderAddress, depositAmount, queryId);
                }
                return saveDataOptimised();
        } else if (op == `pool::request_loan`) {

              `assert_state!`(`state::NORMAL`);
              assert(!(is_current_round_closed)) throw `error::borrowing_request_in_closed_round`;
              if(credit_start_prior_elections_end) { // zero means do not check time
                  var (_, _, electionsEndBefore: int) = getValidatorConfig();
                  var (_, utimeUntil: int, _) = getCurrentValidatorSet();
                  assert(now() > utimeUntil - electionsEndBefore - credit_start_prior_elections_end) throw `error::too_early_borrowing_request`;
              }

              var minLoan: int = inMsgBody.loadCoins();
              var maxLoan: int = inMsgBody.loadCoins();
              var maxInterest: int = inMsgBody.loadShare();
              var staticData: slice = inMsgBody;
              inMsgBody = inMsgBody.preloadRef().beginParse();
              var controllerId: int = inMsgBody.loadControllerId();
              var validator: slice = inMsgBody.loadAddress();
              // the rest of in_msg_body is currently unused static data

              `assert_sender!`(senderAddress, GetControllerAddress(controllerId, validator));
              assert(maxInterest >= interest_rate) throw `error::interest_too_low`;

              // maybe too harsh conditions
              var creditableFunds: int = balance
                                     - muldivExtra(requested_for_withdrawal, total_balance, supply)
                                     - MIN_TONS_FOR_STORAGE;
              var [_, _, _, borrowed, _, _, _] = current_round_borrowers;
              var availableFunds: int = min( creditableFunds,
                                         mulDivFloor( (DISBALANCE_TOLERANCE_BASIS / 2) + disbalance_tolerance, total_balance, DISBALANCE_TOLERANCE_BASIS)
                                         - borrowed );

              var [minLoanPerValidator: int, maxLoanPerValidator: int] = loan_params_per_validator;
              minLoan = max(minLoan, minLoanPerValidator);
              maxLoan = min(maxLoan, maxLoanPerValidator);

              assert(minLoan <= maxLoan) throw `error::contradicting_borrowing_params`;

              var actualLoan: int = min(availableFunds, maxLoan);

              assert(actualLoan >=  minLoan) throw `error::not_enough_funds_for_loan`;

              var interest: int = mulDivFloor(actualLoan, interest_rate, SHARE_BASIS);
              var msg: builder = beginCell()
                        .storeMsgFlags(`msgflag::BOUNCEABLE`)
                        .storeSlice(senderAddress)
                        .storeCoins(actualLoan)
                        .storeMsgbodyPrefixSlice()
                        .storeBodyHeader(`controller::credit`, queryId)
                        .storeCoins(actualLoan + interest);
              sendRawMessage(msg.endCell(), `sendmode::REGULAR`);

              logLoan(senderAddress, actualLoan);
              var totalLoan: int = current_round_borrowers.addLoan(senderAddress, actualLoan, interest);
              assert(totalLoan <= maxLoanPerValidator + interest) throw `error::total_credit_too_high`;
              sendMsgBuilder(getInterestManager(roles), SERVICE_NOTIFICATION_AMOUNT,
                        beginCell()
                                .storeBodyHeader(`interest_manager::request_notification`, getLogicalTime())
                                .storeCoins(minLoan)
                                .storeCoins(maxLoan)
                                .storeShare(maxInterest),
                        `msgflag::NON_BOUNCEABLE`, `sendmode::REGULAR`);

        } else if (op == `pool::loan_repayment`) {
            // we expect loans from previous round only
            // note, close_loan finalize round if last loan is closed
            var (closed: bool, lastOne: bool) = prev_round_borrowers.closeLoan(senderAddress, msgValue);
            if (!closed) {
              // lets check other side
              var (closed: bool, closedOne: bool) = current_round_borrowers.closeLoan(senderAddress, msgValue);
              lastOne = closedOne!;
              if (!closed) {
                // if this request was sent by actual controller, this bounce should be processed
                throw `error::unknown_borrower`;
              }
            }
            if(lastOne) {
                updateRound(getMyOriginalBalance());
            }
        } else if (op == `pool::touch`) {
            // return save_data
        } else if (op == `pool::deploy_controller`) {
            `assert_state!`(`state::NORMAL`);
            var controllerId: int = inMsgBody.loadControllerId();
            // we do not end_parse here, because apps may use
            // unprocessed data in message for offchain analytics
            var (controllerAddress: slice, initState: cell ) = buildControllerAddress(controllerId, senderAddress);
            var msg: builder = beginCell()
                          .storeMsgFlags(`msgflag::BOUNCEABLE`)
                          .storeSlice(controllerAddress)
                          .storeCoins(0)
                          .storeMsgbodyPrefixStateinitSlice(initState)
                          .storeBodyHeader(`controller::top_up`, getLogicalTime());
            sendRawMessage(msg.endCell(), `sendmode::CARRY_ALL_REMAINING_MESSAGE_VALUE`);
        } else if (op == `pool::donate`) {
            // we do not end_parse here, because apps may use
            // unprocessed data in message for offchain analytics
            `assert_state!`(`state::NORMAL`);
            var donateValue: int = msgValue - DEPOSIT_FEE;
            assert(donateValue > 0) throw `error::deposit_amount_too_low`;
            total_balance += donateValue;
            reserveToncoinsOnBalance(balance - msgValue + donateValue - sent_during_rotation, `reservemode::STRICT`);
            var msg: builder = beginCell()
                    .storeMsgFlags(`msgflag::NON_BOUNCEABLE`)
                    .storeSlice(senderAddress)
                    .storeCoins(0)
                    .storeMsgbodyPrefixSlice()
                    .storeBodyHeader(`jetton::excesses`, queryId);
            sendRawMessage(msg.endCell(), `sendmode::CARRY_ALL_BALANCE`);
        } else if (op == `pool::get_conversion_rate_unsafe`) {
            // Method called unsafe because data may change till response reach requester
            var (projectedBalance: int, projectedSupply: int) = GetProjectedConversionRatio ();
            inMsgBody.assertEndOfSlice();
            var response: builder = beginCell()
                    .storeBodyHeader(`pool::take_conversion_rate_unsafe`, queryId)
                    .storeCoins(projectedBalance)
                    .storeCoins(projectedSupply);
            var msg: builder = beginCell()
                .storeMsgFlags(`msgflag::NON_BOUNCEABLE`)
                .storeSlice(senderAddress)
                .storeCoins(0)
                .storeMsgbodyPrefixSlice()
                .storeBuilder(response);
            sendRawMessage(msg.endCell(), `sendmode::CARRY_ALL_REMAINING_MESSAGE_VALUE`);
        } else {
            throw `error::unknown_op`;
        }
    }

    saveData();
}

fun buildControllerAddress(controllerId: int, validator: slice): (slice, cell) {
    var [sudoer: slice, sudoerSetAt: int,
     governor: slice, governorUpdateAfter: int,
     interestManager: slice, halter: slice, approver: slice, treasury: slice] = roles;
    var staticData: cell = beginCell()
                          .storeControllerId(controllerId)
                          .storeSlice(validator)
                          .storeSlice(getMyAddress())
                          .storeSlice(governor)
                          .storeRef(
                             beginCell()
                             .storeSlice(approver)
                             .storeSlice(halter)
                             .endCell()
                          )
                        .endCell();
    var initState: cell = controllerInitState(staticData);
    var controllerAddress: slice = calcAddress(CONTROLLER_WORKCHAIN, initState);
    return (controllerAddress, initState);
}

fun addLoan(mutate self: [cell?, int, int, int, int, int, int], borrower: slice, loanBody: int, interest: int): int {
    var [borrowersDict, roundId, activeBorrowers, borrowed, expected, returned, profit] = self;

    var (wc: int, addrHash: int) = parseStandardAddress(borrower);
    assert(wc == CONTROLLER_WORKCHAIN) throw `error::controller_in_wrong_workchain`;

    var alreadyBorrowed: int = 0;
    var accountedInterest: int = 0;
    var (prevData: slice?, isFound: bool) = borrowersDict.uDictGet(ADDR_SIZE, addrHash);
    if(isFound) {
        alreadyBorrowed = prevData!.loadCoins();
        accountedInterest = prevData!.loadCoins();
    } else {
      activeBorrowers += 1;
    }
    alreadyBorrowed += loanBody;
    accountedInterest += interest;
    borrowed += loanBody;
    expected +=  loanBody + interest;

    borrowersDict.uDictSetBuilder(ADDR_SIZE, addrHash, beginCell().storeCoins(alreadyBorrowed).storeCoins(accountedInterest));

    assert(getCellDepth(borrowersDict) < MAX_LOAN_DICT_DEPTH) throw `error::credit_book_too_deep`;

    self = [borrowersDict, roundId, activeBorrowers, borrowed, expected, returned, profit]; return alreadyBorrowed;
}

fun closeLoan(mutate self: [cell?, int, int, int, int, int, int], borrower: slice, amount: int): (bool, bool) {
    var [borrowersDict, roundId, activeBorrowers, borrowed, expected, returned, profit] = self;

    var (wc: int, addrHash: int) = parseStandardAddress(borrower);
    assert(wc == CONTROLLER_WORKCHAIN) throw `error::controller_in_wrong_workchain`;

    var (prevData: slice?, isFound: bool) = borrowersDict.uDictDeleteAndGet(ADDR_SIZE, addrHash);
    if (!isFound) {
      return (false, false);
    }

    var wasBorrowed: int = prevData!.loadCoins();

    profit += amount - wasBorrowed;

    returned += amount;

    activeBorrowers -= 1;

    logRepayment(borrower, wasBorrowed, amount - wasBorrowed);

    self = [borrowersDict, roundId, activeBorrowers, borrowed, expected, returned, profit];
    var lastOne: bool = activeBorrowers == 0;

    return (true, lastOne);
}

fun finalizeLendingRound(borrowersData: [cell?, int, int, int, int, int, int], availableBalance: int): ([cell?, int, int, int, int, int, int], ()) {
    // Does all the necessary value checks, sends logs
    // and governor fees, nullifies variables.
    var [borrowersDict, roundId, activeBorrowers, borrowed, expected, returned, profit] = borrowersData;
    assert((borrowersDict == null)) throw `error::finalizing_active_credit_round`;
    assert(activeBorrowers == 0) throw `error::finalizing_active_credit_round`;

    profit -= FINALIZE_ROUND_FEE;

    // governance_fee_share / SHARE_BASIS < 1, share to send to governance
    var fee: int = max(mulDivFloor(governance_fee_share, profit, SHARE_BASIS), 0);
    profit -= fee;

    // if there is negative profit (loss), then it can take maximum all the balance
    profit = max(profit, - total_balance);
    total_balance += profit;

    fee += accrued_governance_fee;
    if (fee > SERVICE_NOTIFICATION_AMOUNT) { // otherwise it is less than msg cost
      sent_during_rotation += fee;
      accrued_governance_fee = 0;
      sendMsgBuilder(getTreasury(roles), fee,
               beginCell().storeBodyHeader(`treasury::operation_fee`, getLogicalTime()),
               `msgflag::NON_BOUNCEABLE`, `sendmode::REGULAR`);

    }
    sent_during_rotation += SERVICE_NOTIFICATION_AMOUNT;
    sendMsgBuilder(getInterestManager(roles), SERVICE_NOTIFICATION_AMOUNT,
             beginCell()
               .storeBodyHeader(`interest_manager::stats`, getLogicalTime())
               .storeCoins(borrowed)
               .storeCoins(expected)
               .storeCoins(returned)
               .storeSignedCoins(profit)
               .storeCoins(total_balance), // duplication at this point?
             `msgflag::NON_BOUNCEABLE`, `sendmode::REGULAR`);
    logRoundCompletion(roundId, borrowed, returned, profit, total_balance, supply);

    finalizeDepositWithdrawalRound(availableBalance, roundId);

    // do we need to nulify data here ???
    return ([null, roundId, 0, 0, 0, 0, 0], ());
}

fun logLoan(borrower: slice, amount: int) {
    emitLog(1, beginCell().storeSlice(borrower)
                            .storeCoins(amount));
}

fun logRepayment(borrower: slice, amount: int, profit: int) {
    emitLog(2, beginCell().storeSlice(borrower)
                            .storeCoins(amount)
                            .storeSignedCoins(profit));
}

fun logRoundCompletion(roundId: int, borrowed: int, returned: int, profit: int, totalBalance: int, supply: int) {
    emitLog(3, beginCell().storeUint(roundId, 32)
                            .storeCoins(borrowed)
                            .storeCoins(returned)
                            .storeSignedCoins(profit)
                            .storeCoins(totalBalance)
                            .storeCoins(supply));
}

fun logRoundRotation(roundId: int) {
    emitLog(4, beginCell().storeUint(roundId, 32));
}

fun finalizeDepositWithdrawalRound(availableBalance: int, roundId: int) {
    initiateDistributionOfTons(availableBalance, roundId);
    initiateDistributionOfPoolJettons(roundId);
}

fun initiateDistributionOfTons(availableBalance: int, roundId: int) {
    // Sends tons for distribution, in proportion to
    // the number requested before the start of the round.
    if (!requested_for_withdrawal) {
        return;
    }
    var tonWithdrawal: int = mulDivFloor(requested_for_withdrawal, total_balance, supply);
    var prevWithdrawalPayout: slice = withdrawal_payout!;
    if(availableBalance < tonWithdrawal + MIN_TONS_FOR_STORAGE) {
      // not enough money to withdraw
      // Note that this halt may not be saved to the storage
      // if update_round not called from loan_repayment->last_one->update_round:
      // transaction which will cause halt inside update_round
      // will revert on assert_not_halted!() later. However, this halt
      // still has sense: it will affect any operation after assert_not_halted!()
      // and also it will be shown in get methods since there is update_round()
      // call inside get_pool_full_data
      is_halted = true;
      return;
    } else {
        supply -= requested_for_withdrawal;
        requested_for_withdrawal = 0;
        withdrawal_payout = null;
    }

    total_balance -= tonWithdrawal;
    sent_during_rotation += tonWithdrawal + TRANSFER_NOTIFICATION_AMOUNT;
    var msg = beginCell()
            .storeMsgFlags(`msgflag::BOUNCEABLE`)
            .storeSlice(prevWithdrawalPayout)
            .storeCoins(tonWithdrawal + TRANSFER_NOTIFICATION_AMOUNT)
            .storeMsgbodyPrefixSlice()
            .storeBodyHeader(`payouts::start_distribution`, getLogicalTime());
    sendRawMessage(msg.endCell(), `sendmode::REGULAR`);
}

fun initiateDistributionOfPoolJettons(roundId: int) {
    // Distributes pool tokens among those who received
    // deposit tokens before the start of the round.
    if (!requested_for_deposit) {
        return;
    }
    // if supply == 0 distribute via 1:1 ratio
    var jettonMint: int = supply ? muldivExtra(requested_for_deposit, supply, total_balance) : requested_for_deposit;
    sent_during_rotation += TRANSFER_NOTIFICATION_AMOUNT + PAYOUT_DISTRIBUTION_AMOUNT;
    requestToMintPoolJettons(deposit_payout!,
                                 jettonMint,
                                 getLogicalTime(),
                                 false
                                );
    total_balance += requested_for_deposit;
    deposit_payout = null;
    requested_for_deposit = 0;
}

@inline
fun GetControllerAddress(controllerId: int, validator: slice): slice {
    var (controllerAddress, _) = buildControllerAddress(controllerId, validator);
    return controllerAddress;
}

@inline
fun GetProjectedConversionRatio(): (int, int) {
    var [borrowersDict, roundId, activeBorrowers, borrowed, expected, returned, profit] = prev_round_borrowers;
    var expectedProfit: int = expected - borrowed - FINALIZE_ROUND_FEE;
    var fee: int = max(mulDivFloor(governance_fee_share, expectedProfit, SHARE_BASIS), 0);
    expectedProfit -= fee;
    return (max(total_balance + expectedProfit, 0), supply);
}


get get_controller_address(controllerId: int, validator: slice): slice {
    loadData();
    return GetControllerAddress(controllerId, validator);
}

get get_controller_address_legacy(controllerId: int, wc: int, addrHash: int): (int, int) {
    loadData();
    var (controllerAddress, _) = buildControllerAddress( controllerId,
      beginCell()
           .storeUint(4, 3).storeWorkchain(wc).storeUint(addrHash, ADDR_SIZE)
      .endCell().beginParse());
    return parseStandardAddress(controllerAddress);
}


get get_loan(controllerId: int, validatorAddress: slice, isPrev: int, isUpdate: bool): (int, int) {
    loadData();
    if (isUpdate) {
        updateRound(getMyOriginalBalance());
    }
    var roundBorrowers = isPrev ? prev_round_borrowers
                            : current_round_borrowers;
    var [borrowersDict, roundId, activeBorrowers, borrowed, expected, returned, profit] = roundBorrowers;
    var (controllerAddress: slice, _) = buildControllerAddress(controllerId, validatorAddress);
    var (wc: int, addrHash: int) = parseStandardAddress(controllerAddress);
    var (loanData: slice?, isFound: bool) = borrowersDict.uDictGet(ADDR_SIZE, addrHash);
    if (!isFound) {
        return (0, 0);
    }
    var borrowedAmount: int = loanData!.loadCoins();
    var accountedInterest: int = loanData!.loadCoins();
    return (borrowedAmount, accountedInterest);
}
@inline_ref
fun composePoolFullDataInternal( isUpdate: bool) {
    loadData();
    if (isUpdate) {
        updateRound(getMyOriginalBalance());
    }
    var [optimisticDepositWithdrawals: bool, isDepositsOpen: bool,
     instantWithdrawalFee: int] = deposit_withdrawal_parameters;

    var [sudoer: slice, sudoerSetAt: int,
     governor: slice, governorUpdateAfter: int,
     interestManager: slice, halter: slice, approver: slice, treasury: slice] = roles;

    var [minLoanPerValidator: int, maxLoanPerValidator: int] = loan_params_per_validator;
    var [controller_code, pool_jetton_wallet_code, payout_minter_code] = child_contract_codes;

    return (state, is_halted,
            total_balance,
            interest_rate,
            optimisticDepositWithdrawals, isDepositsOpen,
            instantWithdrawalFee,
            saved_validator_set_hash,

            prev_round_borrowers, current_round_borrowers,
            //unpair(loan_params_per_validator),

            minLoanPerValidator, maxLoanPerValidator,
            governance_fee_share, accrued_governance_fee,
            disbalance_tolerance,
            credit_start_prior_elections_end,


            jetton_minter, supply,

            deposit_payout, requested_for_deposit,
            withdrawal_payout, requested_for_withdrawal,

            sudoer, sudoerSetAt,
            governor, governorUpdateAfter,
            interestManager,
            halter,
            approver,

            controller_code, pool_jetton_wallet_code, payout_minter_code,

            (GetProjectedConversionRatio())
    );
}
get get_pool_full_data() {
    return composePoolFullDataInternal(true);
}

get get_pool_full_data_raw() {
    return composePoolFullDataInternal(false);
}

// We order all loans by controller address hash, put them in line and find position
// of median of given controller loan. This data can be used for deterministic
// voting: if stakers decide to vote in some proptions, we can check that controllers
// voted in the same proportion
get get_controller_loan_position(controllerAddrHash: int, isPrev: int): (int?, int?) {
    loadData();
    updateRound(getMyOriginalBalance());
    var target = isPrev ? prev_round_borrowers : current_round_borrowers;
    var [borrowersDict, roundId, activeBorrowers, borrowed, expected, returned, profit] = target;
    var isFound: bool = true;
    var address: int = -1;
    var loanSumm: int = 0;
    do {
        var (foundAddress: int?, cs: slice?, isFound redef) = borrowersDict.uDictGetNext(ADDR_SIZE, address);
        if(isFound) {
            address = foundAddress!;
            var addressLoan: int = cs!!.loadCoins() + cs!.loadCoins();
            if(address == controllerAddrHash) {
                // we found controller
                var distanceToMedian: int = loanSumm + (addressLoan / 2);
                return (distanceToMedian, expected);
            } else {
              loanSumm += addressLoan;
            }
        }
    } while (isFound);
    // controller not found
    throw `error::unknown_op`;
    return (null, null);
}

get calculate_loan_amount(minLoan: int, maxLoan: int, maxInterest: int): int {
    loadData();
    updateRound(getMyOriginalBalance());
    if(is_current_round_closed) {
        return -1;
    }
    if(maxInterest < interest_rate) {
        return -1;
    }
    if(credit_start_prior_elections_end) { // zero means do not check time
        var (_, _, electionsEndBefore: int) = getValidatorConfig();
        var (_, utimeUntil: int, _) = getCurrentValidatorSet();
        if(now() > utimeUntil - electionsEndBefore - credit_start_prior_elections_end) {
            return -1;
        }
    }

    var creditableFunds: int = getMyOriginalBalance()
            - muldivExtra(requested_for_withdrawal, total_balance, supply)
            - MIN_TONS_FOR_STORAGE;
    var [_, _, _, borrowed, _, _, _] = current_round_borrowers;
    var availableFunds: int = min( creditableFunds, mulDivFloor((DISBALANCE_TOLERANCE_BASIS / 2) + disbalance_tolerance, total_balance, DISBALANCE_TOLERANCE_BASIS) - borrowed );

    var [minLoanPerValidator: int, maxLoanPerValidator: int] = loan_params_per_validator;
    minLoan = max(minLoan, minLoanPerValidator);
    maxLoan = min(maxLoan, maxLoanPerValidator);

    if(minLoan > maxLoan) {
        return -1;
    }

    var actualLoan: int = min(availableFunds, maxLoan);

    if(actualLoan <  minLoan) {
        return -1;
    }

    var interest: int = mulDivFloor(actualLoan, interest_rate, SHARE_BASIS);

    return actualLoan + interest;
}
