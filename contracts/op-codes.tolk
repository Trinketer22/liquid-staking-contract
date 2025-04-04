/* ======== ELECTOR OPCODES =========== */

// https://github.com/ton-blockchain/ton/blob/b38d227a469666d83ac535ad2eea80cb49d911b8/crypto/smartcont/elector-code.fc#L621
const `elector::new_stake` = 0x4e73744b;

// return_stake https://github.com/ton-blockchain/ton/blob/b38d227a469666d83ac535ad2eea80cb49d911b8/crypto/smartcont/elector-code.fc#L169
const `elector::new_stake_error` = 0xee6f454c;

// send_confirmation https://github.com/ton-blockchain/ton/blob/b38d227a469666d83ac535ad2eea80cb49d911b8/crypto/smartcont/elector-code.fc#L173
const `elector::new_stake_ok` = 0xf374484c; 

// https://github.com/ton-blockchain/ton/blob/b38d227a469666d83ac535ad2eea80cb49d911b8/crypto/smartcont/elector-code.fc#L625
const `elector::recover_stake` = 0x47657424;

// https://github.com/ton-blockchain/ton/blob/b38d227a469666d83ac535ad2eea80cb49d911b8/crypto/smartcont/elector-code.fc#L407
const `elector::recover_stake_error` = 0xfffffffe;

// https://github.com/ton-blockchain/ton/blob/b38d227a469666d83ac535ad2eea80cb49d911b8/crypto/smartcont/elector-code.fc#L426
const `elector::recover_stake_ok` = 0xf96f7324;

/* ========  Validator Controller OPCODES ======== */
// IN
const `controller::top_up` = 0xd372158c;
const `controller::update_validator_hash` = 0xf0fd2250;
const `controller::approve` = 0x7b4b42e6;
const `controller::approve_extended` = 0x7b2142e6;
const `controller::disapprove` = 0xe8a0abfe;
const `controller::recover_stake` = 0xeb373a05;
const `controller::new_stake` = `elector::new_stake`;
const `controller::credit` = 0x1690c604;
const `controller::withdraw_validator` = 0x8efed779;
const `controller::return_unused_loan` = 0xed7378a6;

// OUT
const `controller::validator_withdrawal` = 0x30026327;
const `controller::send_request_loan` = 0x6335b11a;


/* ======== Validator Pool OPCODES ========== */
const `pool::request_loan` = 0xe642c965;
const `pool::loan_repayment` = 0xdfdca27b;
const `pool::deposit` = 0x47d54391;
const `pool::withdraw` = 0x319B0CDC;
const `pool::withdrawal` = 0x0a77535c;
const `pool::touch` = 0x4bc7c2df;
const `pool::donate` = 0x73affe21;

const `pool::deploy_controller` = 0xb27edcad;
// Method called unsafe because data may change till response reach requester
const `pool::get_conversion_rate_unsafe` = 0x4b7b42e6;
const `pool::take_conversion_rate_unsafe` = 0x42e64b7b;

/* ========== Governance OPCODES ========== */


const `sudo::send_message` = 0x270695fb;
const `sudo::upgrade` = 0x96e7f528;
const `governor::set_sudoer` = 0x79e7c016;
const `governor::set_governance_fee` = 0x2aaa96a0;
const `governor::set_roles` = 0x5e517f36;
const `governor::unhalt` = 0x7247e7a5;
const `governor::set_deposit_settings` = 0x9bf5561c;
const `governor::return_available_funds` = 0x55c26cd5;
const `governor::prepare_governance_migration` = 0x9971881c;

const `halter::halt` = 0x139a1b4e;
const `halter::partial_halt` = 0x77778888; //todo

const `treasury::operation_fee` = 0x54d37487;
const `interest_manager::request_notification` = 0xb1ebae06;
const `interest_manager::stats` = 0xc1344900;
const `interest_manager::set_interest` = 0xc9f04485;
const `interest_manager::set_operational_params` = 0x4485c9f0;

/* ========== Jetton OPCODES ========== */
const `jetton::transfer` = 0xf8a7ea5;
const `jetton::transfer_notification` = 0x7362d09c;
const `jetton::internal_transfer` = 0x178d4519;
const `jetton::excesses` = 0xd53276db;
const `jetton::burn` = 0x595f07bc;
const `jetton::burn_notification` = 0x7bdd97de;
const `jetton::withdraw_tons` = 0x6d8e5e3c;
const `jetton::withdraw_jettons` = 0x768a50b2;

const `jetton::provide_wallet_address` = 0x2c76b973;
const `jetton::take_wallet_address` = 0xd1735400;
const `jetton::change_content` = 0x5773d1f5;

const `payout::mint` = 0x1674b0a0;
const `payout::burn_notification` = `pool::withdraw`;
const `payout::init` = 0xf5aa8943;


const `payouts::start_distribution` = 0x1140a64f;

/* =========== awaited Jettons ============= */
const `payouts::mint` = 0x8887;
