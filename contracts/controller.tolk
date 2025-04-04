// The validator has his own wallet on which he holds his own coins for operating.
// From this wallet (s)he sends commands to this validator-controller (mostly `new_stake`, `update_validator_set` and `recover_stake`).
// validator-controller contract must be in masterchain.
// The validator in most cases have two validator-controllers (for even and odd validation rounds).


/*
 TODO:
   1) move config_param(1) to constants
   2) elector_address() can be optimized
*/

import "@stdlib/gas-payments"

import "types.tolk"
import "op-codes.tolk"
import "messages.tolk"
import "errors.tolk"
import "asserts.tolk"
import "globals.tolk"
import "network_config_utils.tolk"
import "sudoer_requests.tolk"


// Redefined const ONE_TON = 1000000000;
const ELECTOR_OPERATION_VALUE = 103 * ONE_TON / 100 ;
const MIN_REQUEST_LOAN_VALUE = ONE_TON ; // should cover controller and pool gas
const MIN_TONS_FOR_STORAGE = 2 * ONE_TON; // 2 TON
const DEPOSIT_FEE = ONE_TON / 4; // 0.25 TON
const WITHDRAWAL_FEE = ONE_TON / 4; // 0.25 TON
const MIN_STAKE_TO_SEND = 50000 * ONE_TON; // 50 000 TON

// Time in seconds for validator to make mandatory actions, such as
// recover stake or update hash
const GRACE_PERIOD = 600;
// Fines for validator for overdue actions
const HASH_UPDATE_FINE = 10 * ONE_TON;
const STAKE_RECOVER_FINE = 10 * ONE_TON;

const MAX_OVERDUE_FINE = (HASH_UPDATE_FINE * 3) + STAKE_RECOVER_FINE;
// ENSURABLE_BALANCE_FOR_STAKING is expected to be on balance after sending new_stake request.
// it includes
//   - TON for pool storage
//   - TON for possible fines which are paid to watchdogs during staking
// we also add ELECTOR_OPERATION_VALUE to ensure room for computation fees
// and storage fees on other contract we interact with
const ENSURABLE_BALANCE_FOR_STAKING = MIN_TONS_FOR_STORAGE + MAX_OVERDUE_FINE + ELECTOR_OPERATION_VALUE;

// Whole storage is put to global variables

// global state: int;
// global is_halted: bool;
global is_approved: bool;

global stake_amount_sent: int;
global stake_at: int;

global saved_validator_set_hash: int;
global validator_set_changes_count: int;
global validator_set_change_time: int;
global stakeHeldFor: int;

global borrowed_amount: int;
global borrowing_time: int;

global sudoer: slice;
global sudoer_set_at: int;

global interest: int;

global allowed_borrow_start_prior_elections_end: int;
global approver_set_profit_share: int;
global acceptable_profit_share: int;
global allocation: int;

global static_data: slice;
global controller_id: int;
global validator: slice;
global pool: slice;
global governor: slice;
global halter: slice;
global approver: slice;



const `state::REST` = 0;
const `state::SENT_BORROWING_REQUEST` = 1;
const `state::SENT_STAKE_REQUEST` = 2;
const `state::FUNDS_STAKEN` = 3;
const `state::SENT_RECOVER_REQUEST` = 4;
const `state::INSOLVENT` = 5;



//int max_recommended_punishment_for_validator_misbehaviour(int stake);
//(int, int, int) get_validator_config();
//int get_stake_held_for();
//int get_elections_start_before();
//(int, int, cell) get_current_validator_set();

fun onInternalMessage(balance: int, msgValue: int, inMsgFull: cell, inMsgBody: slice) {

    var cs: slice = inMsgFull.beginParse();
    var flags: int = cs.loadUint(4);

    var senderAddress: slice = cs.loadAddress();
    loadData();
    if (flags & 1) { // bounced messages
        if (inMsgBody.getRemainingBitsCount() >= 64) {
            inMsgBody.skipBounce(); // skip 0xFFFFFFFF bounced prefix
            var op: int = inMsgBody.loadOp();
            if ((op == `elector::new_stake`) && (isElectorAddress(senderAddress))) {
                // `new_stake` from nominator-pool should always be handled without throws by elector
                // because nominator-pool do `check_new_stake_msg` and `msg_value` checks before sending `new_stake`.
                // If the stake is not accepted elector will send `new_stake_error` response message.
                // Nevertheless we do process theoretically possible bounced `new_stake`.

                if (state == `state::SENT_STAKE_REQUEST`) {
                    state = `state::REST`;
                } else {
                    is_halted = true;
                }
            } else if (isSliceBitsEqual(senderAddress, pool)) {
              if(op == `pool::loan_repayment`) {
                borrowed_amount += msgValue;
                borrowing_time = now();
              } else if (op == `pool::request_loan`) {
                if (state == `state::SENT_BORROWING_REQUEST`) {
                  state = `state::REST`;
                } else {
                  is_halted = true;
                }
              }
            }
        }

        saveData();
        return; // ignore other bounces messages
    }

    var (op: int, queryId: int) = inMsgBody.loadBodyHeader();

    if (isElectorAddress(senderAddress)) { // response from elector

            acceptExternalMessage();

            if (op == `elector::recover_stake_ok`) {
                // Note, this request will be processed even in halted state
                state = `state::REST`;
                // return max of borrowed_amount or borrowed_amount + profit_share * profit
                var profit: int = msgValue - stake_amount_sent;
                var amountToReturn: int = max(borrowed_amount,
                                           mulDivFloor(borrowed_amount, SHARE_BASIS, SHARE_BASIS + interest) +  // restore credit body
                                              mulDivFloor(approver_set_profit_share, profit, SHARE_BASIS));
                if( amountToReturn ) {
                  if(balance >= MIN_TONS_FOR_STORAGE + amountToReturn) {
                    sendMsg(pool,
                             amountToReturn, // TODO add fee???
                             beginCell().storeBodyHeader(`pool::loan_repayment`, queryId).endCell(),
                             `msgflag::BOUNCEABLE`,
                             `sendmode::PAY_FEES_SEPARATELY`); // remaining inbound message amount, fee deducted from
                    borrowed_amount = 0;
                    borrowing_time = 0;
                    interest = 0;
                    stake_amount_sent = 0;
                    stake_at = 0;
                  } else {
                    state = `state::INSOLVENT`;
                  }
                }
            } else if (op == `elector::recover_stake_error`) {
                if(state == `state::SENT_RECOVER_REQUEST`) {
                    // The only case when we get elector::recover_stake_error is credits = 0
                    // in this case we should not return state to FUNDS_STAKEN to avoid
                    // further balance depletion due to repetitive STAKE_RECOVER_FINE
                    is_halted = true;
                    state = `state::INSOLVENT`;
                } else {
                    is_halted = true;
                }
            }

            if (state == `state::SENT_STAKE_REQUEST`) {
                if (op == `elector::new_stake_error`) { // error when new_stake; stake returned
                    state = `state::REST`;
                } else if (op == `elector::new_stake_ok`) {
                    state = `state::FUNDS_STAKEN`;
                    // update saved_validator_set_hash in case it have changed
                    // while new_stake message reached the elector
                    var (utimeSince: int, utimeUntil: int, vset: cell) = getCurrentValidatorSet();
                    saved_validator_set_hash = cellHash(vset) >> 128;
                } else {
                    is_halted = true;
                }
            }

            // else just accept coins from elector

    } else {

            if (op == `controller::top_up`) {
                inMsgBody.assertEndOfSlice();
                if(state == `state::INSOLVENT`) {
                    // we add WITHDRAWAL_FEE below to ensure there is enough money to process
                    // and send bounty in return_unused_loan
                    if (balance > MIN_TONS_FOR_STORAGE + STAKE_RECOVER_FINE + borrowed_amount + WITHDRAWAL_FEE) {
                        state = `state::REST`;
                    }
                }
            } else if (op == `controller::credit`) {
                `assert_sender!`(senderAddress, pool);
                // borrowed_amount includes interest
                if (!borrowing_time) {
                  borrowing_time = now();
                }
                var creditAmount: int = inMsgBody.loadCoins();
                borrowed_amount += creditAmount;
                inMsgBody.assertEndOfSlice();
                assert(creditAmount < mulDivFloor(msgValue, interest + SHARE_BASIS, SHARE_BASIS) + ONE_TON) throw `error::credit_interest_too_high`;
                interest = mulDivFloor(creditAmount - msgValue, SHARE_BASIS, msgValue);
                if(state == `state::SENT_BORROWING_REQUEST`) {
                  state = `state::REST`;
                }
            } else if (op == `controller::approve`) {
                `assert_sender!`(senderAddress, approver);
                // we do not end_parse here, because unprocessed data
                // in message maybe used for reason in offchain analytics
                is_approved = true;
                // default value for allowed_borrow_start_prior_elections_end  is permisive
                allowed_borrow_start_prior_elections_end = 65536;
                // zero allocation means no limit
                allocation = 0;
            } else if (op == `controller::approve_extended`) {
                `assert_sender!`(senderAddress, approver);
                is_approved = true;
                allowed_borrow_start_prior_elections_end = inMsgBody.loadTimestamp();
                allocation = inMsgBody.loadCoins();
                var newProfitShare: int = inMsgBody.loadShare();
                if (newProfitShare) {
                    if(newProfitShare > approver_set_profit_share) {
                        // do not allow to increase profit share for controller which validate right now
                        // note, controller can be disapproved
                        `assert_state!`(`state::REST`);
                    }
                }
                approver_set_profit_share = newProfitShare;
            }  else if (op == `controller::disapprove`) {
                `assert_sender!`(senderAddress, approver);
                // we do not end_parse here, because unprocessed data
                // in message maybe used for reason in offchain analytics
                is_approved = false;
            } else if (op == `sudo::send_message`) {
                processSudoRequest(senderAddress, inMsgBody,
                                     sudoer, sudoer_set_at);
            } else if (op == `governor::set_sudoer`) {
                `assert_sender!`(senderAddress, governor);
                sudoer_set_at = now();
                sudoer = inMsgBody.loadAddress();
                inMsgBody.assertEndOfSlice();
            }  else if (op == `governor::unhalt`) {
                `assert_sender!`(senderAddress, governor);
                is_halted = false;
                inMsgBody.assertEndOfSlice();
            }  else if (op == `governor::return_available_funds`) {
                `assert_state!`(`state::INSOLVENT`);
                `assert_sender!`(senderAddress, governor);
                inMsgBody.assertEndOfSlice();
                var availableFunds: int = balance - MIN_TONS_FOR_STORAGE - WITHDRAWAL_FEE;
                availableFunds = min( availableFunds, borrowed_amount);
                sendMsg(pool,
                        availableFunds,
                        beginCell().storeBodyHeader(`pool::loan_repayment`, queryId).endCell(),
                        `msgflag::BOUNCEABLE`,
                        `sendmode::PAY_FEES_SEPARATELY`); // remaining inbound message amount, fee deducted from
                borrowed_amount -= availableFunds;
                if(borrowed_amount == 0) {
                    borrowing_time = 0;
                    state = `state::REST`;
                }
            }  else if (op == `halter::halt`) {
                // we do not end_parse here, because unprocessed data
                // in message maybe used for reason in offchain analytics
                `assert_sender!`(senderAddress, halter);
                is_halted = true;
            }  else {
                // actions above considered safe or critical enough to be processed in halted regime
                // actions below are only allowed for not halted controller
                `assert_not_halted!`();
                if (op == `controller::recover_stake`) { // send recover_stake to elector
                    `assert_state!`(`state::FUNDS_STAKEN`);
                    inMsgBody.assertEndOfSlice();
                    // We need to take all credits from the elector at once,
                    // because if we do not take all at once, then it will be processed as a fine by pool.
                    // In the elector, credits (`credit_to`) are accrued in three places:
                    // 1) return of surplus stake in elections (`try_elect`)
                    // 2) reward for complaint when punish (`punish`) - before unfreezing
                    // 3) unfreeze round (`unfreeze_without_bonuses`/`unfreeze_with_bonuses`)
                    // We need to be guaranteed to wait for unfreezing round and only then send `recover_stake`.
                    // So we are waiting for the change of 3 validator sets.

                    // ADDITIONAL NOTE:
                    // In a special case (if the network was down), the config theoretically can refuse the elector to save a new round after election - https://github.com/ton-blockchain/ton/blob/b38d227a469666d83ac535ad2eea80cb49d911b8/crypto/smartcont/config-code.fc#L494
                    // and the elector will start a new election - https://github.com/ton-blockchain/ton/blob/b38d227a469666d83ac535ad2eea80cb49d911b8/crypto/smartcont/elector-code.fc#L364
                    // in this case, our pool will have to skip the round, but it will be able to recover stake later

                    assert(validator_set_changes_count >= 2) throw `error::too_early_stake_recover_attempt_count`;
                    var timeSinceUnfreeze: int = now() - validator_set_change_time - stakeHeldFor;
                    assert((validator_set_changes_count > 2) | (timeSinceUnfreeze > 60)) throw `error::too_early_stake_recover_attempt_time`;
                    // https://github.com/ton-blockchain/ton/blob/b38d227a469666d83ac535ad2eea80cb49d911b8/crypto/smartcont/elector-code.fc#L887
                    assert(msgValue >= ELECTOR_OPERATION_VALUE) throw `error::too_low_recover_stake_value`;

                    var payload: cell = beginCell().storeBodyHeader(`elector::recover_stake`, queryId).endCell();
                    sendMsg(electorAddress(),
                             0, // amount
                             payload,
                             `msgflag::BOUNCEABLE`,
                             `sendmode::CARRY_ALL_REMAINING_MESSAGE_VALUE`); // remaining inbound message amount, fee deducted from amount, revert on errors
                    state = `state::SENT_RECOVER_REQUEST`;
                    if( (timeSinceUnfreeze < GRACE_PERIOD) | (borrowed_amount == 0) ) {
                      `assert_sender!`(senderAddress, validator);
                    } else {
                      if(balance - msgValue - STAKE_RECOVER_FINE >= MIN_TONS_FOR_STORAGE) {
                        if (! isSliceBitsEqual(senderAddress, validator)) {
                          sendMsg(senderAddress, STAKE_RECOVER_FINE, null, `msgflag::NON_BOUNCEABLE`, `sendmode::IGNORE_ERRORS`);
                        }
                      }
                    }

                } else if (op == `controller::update_validator_hash`) {
                    `assert_state!`(`state::FUNDS_STAKEN`);
                    inMsgBody.assertEndOfSlice();
                    assert(validator_set_changes_count < 3) throw `error::too_much_validator_set_counts`;
                    var (utimeSince: int, utimeUntil: int, vset: cell) = getCurrentValidatorSet();
                    var currentHash: int = cellHash(vset) >> 128;
                    assert(saved_validator_set_hash != currentHash) throw `error::no_new_hash`;
                    saved_validator_set_hash = currentHash;
                    validator_set_changes_count += 1;
                    validator_set_change_time = now();

                    // elector set 'stakeHeldFor' during election conduction
                    // we save it when sending stake and after first round change and chose max
                    // it's ok unless 'stakeHeldFor' will change twice: first one after sending stake
                    // but before election conduction and second one after election but prior update_hash
                    var (_, currentStakeHeldFor: int, _) = getValidatorConfig();
                    stakeHeldFor = max(stakeHeldFor, currentStakeHeldFor);


                    var overdue: int = now() - utimeSince;
                    if( (overdue < GRACE_PERIOD) | (borrowed_amount == 0) ) {
                      `assert_sender!`(senderAddress, validator);
                      sendExcesses(senderAddress);
                    } else {
                      if(balance - HASH_UPDATE_FINE >= MIN_TONS_FOR_STORAGE) {
                        if (! isSliceBitsEqual(senderAddress, validator)) {
                          sendMsg(senderAddress, HASH_UPDATE_FINE, null, `msgflag::NON_BOUNCEABLE`, `sendmode::IGNORE_ERRORS`);
                        }
                      }
                    }
                } else if (op == `controller::withdraw_validator`) { // withdraw validator (after recover_stake and before new_stake)
                    `assert_state!`(`state::REST`);
                    assert(!(borrowed_amount)) throw `error::withdrawal_while_credited`;
                    `assert_sender!`(senderAddress, validator);
                    var requestAmount: int = inMsgBody.loadCoins();
                    inMsgBody.assertEndOfSlice();
                    assert(requestAmount > 0) throw `error::incorrect_withdrawal_amount`;

                    reserveToncoinsOnBalance(MIN_TONS_FOR_STORAGE, `reservemode::AT_MOST`);
                    sendMsg(validator,
                             requestAmount,
                             beginCell().storeBodyHeader(`controller::validator_withdrawal`, queryId).endCell(),
                             `msgflag::NON_BOUNCEABLE`,
                             `sendmode::REGULAR`);

                } else if (op == `controller::new_stake`) {
                    `assert_state!`(`state::REST`);
                    `assert_sender!`(senderAddress, validator);

                    assert(queryId) throw `error::incorrect_new_stake::query_id`; // query_id must be greater then 0 to receive confirmation message from elector

                    assert(msgValue >= ELECTOR_OPERATION_VALUE) throw `error::incorrect_new_stake::request_value`; // must be greater then new_stake sending to elector fee

                    var value: int = inMsgBody.loadCoins();

                    var msg: slice = inMsgBody;

                    stake_at = checkNewStakeMsg(inMsgBody);

                    stake_amount_sent = value - ELECTOR_OPERATION_VALUE;

                    assert(value >= MIN_STAKE_TO_SEND) throw `error::incorrect_new_stake::value_lt_minimum`;

                    var overdueFineAndStorage: int = MAX_OVERDUE_FINE + MIN_TONS_FOR_STORAGE;

                    assert(balance - value >=  overdueFineAndStorage) throw `error::incorrect_new_stake::value_too_high`;
                    var (_, stakeHeldParsed, electionsEndBefore: int) = getValidatorConfig();
                    stakeHeldFor = stakeHeldParsed;
                    var (utimeSince: int, utimeUntil: int, vset: cell) = getCurrentValidatorSet();
                    if (borrowed_amount) {
                      // it is allowed to use credit funds only in the same round when they were obtained
                      assert((borrowing_time > utimeSince) & (now() < utimeUntil - electionsEndBefore)) throw `error::incorrect_new_stake::wrongly_used_credit`;
                    }

                    var validatorOwnFunds: int = balance - borrowed_amount - overdueFineAndStorage;

                    assert(validatorOwnFunds >= maxRecommendedPunishmentForValidatorMisbehaviour(stake_amount_sent)) throw `error::incorrect_new_stake::solvency_not_guaranteed`;

                    state = `state::SENT_STAKE_REQUEST`;



                    saved_validator_set_hash = cellHash(vset) >> 128; // current validator set, we will be in next validator set
                    validator_set_changes_count = 0;
                    validator_set_change_time = utimeSince;

                    sendMsg(electorAddress(),
                             value,
                             beginCell().storeBodyHeader(`elector::new_stake`, queryId).storeSlice(msg).endCell(),
                             `msgflag::BOUNCEABLE`,
                             `sendmode::PAY_FEES_SEPARATELY`); // pay fee separately, revert on errors

                } else if (op == `controller::send_request_loan`) {
                  `assert_state!`(`state::REST`);
                  `assert_sender!`(senderAddress, validator);
                  assert(msgValue >= MIN_REQUEST_LOAN_VALUE) throw `error::too_low_request_loan_value`;
                  var request: slice = inMsgBody;
                  var minLoan: int = inMsgBody.loadCoins();
                  var maxLoan: int = inMsgBody.loadCoins();
                  var maxInterest: int = inMsgBody.loadShare();
                  // leaving it here for backward compatibility
                  // consider to remove when MTC will be ready to handle
                  if(inMsgBody.getRemainingBitsCount()) {
                      acceptable_profit_share = inMsgBody.loadShare();
                  } else {
                      acceptable_profit_share = 0;
                  }
                  assert(acceptable_profit_share >= approver_set_profit_share) throw `error::profit_share_mismatch`;

                  inMsgBody.assertEndOfSlice();
                  interest = maxInterest;

                  assert(is_approved) throw `error::controller_not_approved`;

                  // For simplicity forbid multiple borrowing
                  // TODO
                  assert(!(borrowed_amount)) throw `error::multiple_loans_are_prohibited`;

                  var (electionsStartBefore: int, _, electionsEndBefore: int) = getValidatorConfig();
                  var (utimeSince: int, utimeUntil: int, vset: cell) = getCurrentValidatorSet();
                  assert(now() > utimeUntil - electionsStartBefore) throw `error::too_early_loan_request`; // elections started
                  assert(now() > utimeUntil - electionsEndBefore - allowed_borrow_start_prior_elections_end) throw `error::too_early_loan_request`; // allowed to borrow
                  assert(now() < utimeUntil - electionsEndBefore) throw `error::too_late_loan_request`;   // elections not yet closed


                  // lets check whether we can afford it
                  var electorFine: int = maxRecommendedPunishmentForValidatorMisbehaviour(maxLoan + balance);
                  var interestPayment: int = mulDivFloor(maxLoan, maxInterest, SHARE_BASIS);
                  var validatorAmount: int = balance - borrowed_amount;
                    assert(validatorAmount >= ENSURABLE_BALANCE_FOR_STAKING + electorFine + interestPayment) throw `error::too_high_loan_request_amount`;
                    if(allocation) { // zero allocation means no limit
                      assert(maxLoan <= allocation) throw `error::too_high_loan_request_amount`;
                    }

                  var payload: cell = beginCell()
                                             .storeBodyHeader(`pool::request_loan`, queryId)
                                             .storeSlice(request)
                                             .storeSlice(static_data)
                                 .endCell();
                  sendMsg(pool,
                           0,
                           payload,
                           `msgflag::BOUNCEABLE`,
                           `sendmode::CARRY_ALL_REMAINING_MESSAGE_VALUE`);
                  state = `state::SENT_BORROWING_REQUEST`;
                } else if (op == `controller::return_unused_loan`) {
                    `assert_state!`(`state::REST`);
                    inMsgBody.assertEndOfSlice();
                    assert(borrowed_amount) throw `error::no_credit`;
                    var (utimeSince: int, utimeUntil: int, vset: cell) = getCurrentValidatorSet();
                    assert(utimeSince > borrowing_time) throw `error::too_early_loan_return`; // loan was requested in previous round
                    var overdue: int = now() - utimeSince;
                    if(balance >= MIN_TONS_FOR_STORAGE + borrowed_amount) {
                      sendMsg(pool,
                               borrowed_amount, // TODO add fee???
                               beginCell().storeBodyHeader(`pool::loan_repayment`, queryId).endCell(),
                               `msgflag::BOUNCEABLE`,
                               `sendmode::PAY_FEES_SEPARATELY`); // remaining inbound message amount, fee deducted from
                      if(overdue < GRACE_PERIOD) {
                        `assert_sender!`(senderAddress, validator);
                        sendExcesses(senderAddress);
                      } else {
                        if(balance >=  MIN_TONS_FOR_STORAGE + borrowed_amount + STAKE_RECOVER_FINE) {
                          if (! isSliceBitsEqual(senderAddress, validator)) {
                            sendMsg(senderAddress, STAKE_RECOVER_FINE, null, `msgflag::NON_BOUNCEABLE`, `sendmode::IGNORE_ERRORS`);
                          }
                        }
                      }
                      borrowed_amount = 0;
                      borrowing_time = 0;
                    } else {
                      state = `state::INSOLVENT`;
                    }
                } else {
                  throw `error::unknown_op`;
                }
            }
    }

    saveData();
}

@inline_ref
fun saveData() {
    setContractData(beginCell()
        .storeUint(state, 8)
        .storeBool(is_halted)
        .storeBool(is_approved)
        .storeCoins(stake_amount_sent)
        .storeTimestamp(stake_at)
        .storeUint(saved_validator_set_hash, 128)
        .storeUint(validator_set_changes_count, 8)
        .storeTimestamp(validator_set_change_time)
        .storeTimestamp(stakeHeldFor)
        .storeCoins(borrowed_amount)
        .storeTimestamp(borrowing_time)
        .storeSlice(sudoer)
        .storeTimestamp(sudoer_set_at)
        .storeShare(interest)
        .storeTimestamp(allowed_borrow_start_prior_elections_end)
        .storeShare(approver_set_profit_share)
        .storeShare(acceptable_profit_share)
        .storeCoins(allocation)
        .storeSlice(static_data)
        .endCell());
}

@inline_ref
fun loadData() {

    var ds: slice = getContractData().beginParse();
    state = ds.loadUint(8);
    is_halted = ds.loadBool();
    is_approved = ds.loadBool();

    stake_amount_sent = ds.loadCoins();
    stake_at = ds.loadTimestamp();

    saved_validator_set_hash = ds.loadUint(128);
    validator_set_changes_count = ds.loadUint(8);
    validator_set_change_time = ds.loadTimestamp();
    stakeHeldFor = ds.loadTimestamp();

    borrowed_amount = ds.loadCoins();
    borrowing_time = ds.loadTimestamp();

    sudoer = ds.loadAddress();
    sudoer_set_at = ds.loadTimestamp();

    interest = ds.loadShare();

    allowed_borrow_start_prior_elections_end = ds.loadTimestamp();
    approver_set_profit_share = ds.loadShare();
    acceptable_profit_share = ds.loadShare();
    allocation = ds.loadCoins();

    static_data = ds;

    ds = ds.loadRef().beginParse();

    controller_id = ds.loadUint(32);
    validator = ds.loadAddress();
    pool = ds.loadAddress();
    governor = ds.loadAddress();

    ds = ds.loadRef().beginParse();

    approver = ds.loadAddress();
    halter = ds.loadAddress();
}


@inline_ref
fun makeAddress(wc: int, addr: int): slice {
    return beginCell()
           .storeUint(4, 3).storeWorkchain(wc).storeUint(addr, ADDR_SIZE).endCell().beginParse();
}

@inline_ref
fun electorAddress(): slice {
    var elector: int = getBlockchainConfigParam(1)!.beginParse().preloadUint(ADDR_SIZE);
    return makeAddress(MASTERCHAIN, elector);
}

// https://github.com/ton-blockchain/ton/blob/ae5c0720143e231c32c3d2034cfe4e533a16d969/crypto/block/block.tlb#L584
@inline_ref
fun isElectorAddress(address: slice): bool {
  return isSliceBitsEqual(address, electorAddress());
}


// check the validity of the new_stake message
// https://github.com/ton-blockchain/ton/blob/b38d227a469666d83ac535ad2eea80cb49d911b8/crypto/smartcont/elector-code.fc#L208
@inline_ref
fun checkNewStakeMsg(cs: slice): int {
    var validatorPubkey = cs.loadUint(256);
    var stakeAt = cs.loadUint(32);
    var maxFactor = cs.loadUint(32);
    var adnlAddr = cs.loadUint(256);
    var signature = cs.loadRef().beginParse().preloadBits(512);
    cs.assertEndOfSlice();
    return stakeAt; // supposed start of next validation round (utime_since)
}

// Get methods

get get_validator_controller_data() {
    loadData();
    return (
      state, is_halted, is_approved,
      
      stake_amount_sent, stake_at,
      
      saved_validator_set_hash,
      validator_set_changes_count,
      validator_set_change_time,
      stakeHeldFor,

      interest, allowed_borrow_start_prior_elections_end,
      approver_set_profit_share, acceptable_profit_share, allocation,

      borrowed_amount, borrowing_time,
      validator, pool, sudoer
      );
}

get get_max_punishment(stake: int): int {
    return maxRecommendedPunishmentForValidatorMisbehaviour(stake);
}

get get_max_stake_value(): int {
    loadData();
    if (!(state == `state::REST`)) {
        return -1;
    }
    var balance: int = getMyOriginalBalance();
    // we add ELECTOR_OPERATION_VALUE to ensure room for storage fees and so on
    var value: int = balance - ENSURABLE_BALANCE_FOR_STAKING;
    if(value < MIN_STAKE_TO_SEND) {
        return -1;
    }
    if (borrowed_amount) {
        var (_, stakeHeldParsed, electionsEndBefore: int) = getValidatorConfig();
        stakeHeldFor = stakeHeldParsed;
        var (utimeSince: int, utimeUntil: int, vset: cell) = getCurrentValidatorSet();
        // it is allowed to use credit funds only in the same round when they were obtained
        if((borrowing_time > utimeSince) & (now() < utimeUntil - electionsEndBefore)) {
            return -1;
        }
    }
    // currently we skip checks related to max_recommended_punishment_for_validator_misbehaviour
    return value;
}

get required_balance_for_loan(credit: int, interest: int): (int, int) {
    loadData();
    var balance: int = getMyOriginalBalance();
    var electorFine: int = maxRecommendedPunishmentForValidatorMisbehaviour(credit + balance);
    var interestPayment: int = mulDivFloor(credit, interest, SHARE_BASIS);
    var validatorAmount: int = balance - borrowed_amount;
    return (ENSURABLE_BALANCE_FOR_STAKING + electorFine + interestPayment,
            validatorAmount);
}


get request_window_time(): (int, int) { // TODO: put it in recv_internal in request_loan operation
    // get time window (since, until) when controller may request loan
    var (electionsStartBefore: int, _, electionsEndBefore: int) = getValidatorConfig();
    var (utimeSince: int, utimeUntil: int, _) = getCurrentValidatorSet();
    return (utimeUntil - electionsStartBefore,
            utimeUntil - electionsEndBefore);
}
