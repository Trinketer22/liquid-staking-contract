const `error::unknown_op` = 0xffff;

const `error::wrong_sender` = 0x9283;
const `error::wrong_state` = 0x9284;
const `error::halted` = 0x9285;

const `sudoer::quarantine` = 0xa000;
const `error::governor_update_too_soon` = 0xa001;
const `error::governor_update_not_matured` = 0xa003;

const `error::interest_too_low` = 0xf100;
const `error::contradicting_borrowing_params` = 0xf101;
const `error::not_enough_funds_for_loan` = 0xf102;
const `error::total_credit_too_high` = 0xf103;
const `error::borrowing_request_in_closed_round` = 0xf104;
const `error::too_early_borrowing_request` = 0xf105;

const `error::deposit_amount_too_low` = 0xf200;
const `error::deposits_are_closed` = 0xf201;
const `error::output_amount_is_zero` = 0xf202;

const `error::not_enough_TON_to_process` = 0xf300;

const `error::controller_in_wrong_workchain` = 0xf400;
const `error::credit_book_too_deep` = 0xf401;
const `error::unknown_borrower` = 0xf402;

const `error::finalizing_active_credit_round` = 0xf500;

const `error::too_early_stake_recover_attempt_count` = 0xf600;
const `error::too_early_stake_recover_attempt_time` = 0xf601;
const `error::too_low_recover_stake_value` = 0xf602;
const `error::not_enough_money_to_pay_fine` = 0xf603;
const `error::too_low_request_loan_value` = 0xf604;

const `error::too_much_validator_set_counts` = 0xf700;
const `error::no_new_hash` = 0xf701;

const `error::withdrawal_while_credited` = 0xf800;
const `error::incorrect_withdrawal_amount` = 0xf801;


const `error::incorrect_new_stake::query_id` = 0xf900;
const `error::incorrect_new_stake::request_value` = 0xf901;
const `error::incorrect_new_stake::value_lt_minimum` = 0xf902;
const `error::incorrect_new_stake::value_too_high` = 0xf903;
const `error::incorrect_new_stake::wrongly_used_credit` = 0xf904;
const `error::incorrect_new_stake::solvency_not_guaranteed` = 0xf905;


const `error::controller_not_approved` = 0xfa00;
const `error::multiple_loans_are_prohibited` = 0xfa01;
const `error::too_early_loan_request` = 0xfa02;
const `error::too_late_loan_request` = 0xfa03;
const `error::too_high_loan_request_amount` = 0xfa04;
const `error::credit_interest_too_high` = 0xfa05;
const `error::profit_share_mismatch` = 0xfa06;

const `error::no_credit` = 0xfb00;
const `error::too_early_loan_return` = 0xfb01;

const `error::contradicting_operational_params` = 0xfc00;
