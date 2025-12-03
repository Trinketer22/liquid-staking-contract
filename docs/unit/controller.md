# Controller contract function reference

## Persistence helpers

- `save_data()` serializes controller storage into the contract data cell, including operational flags, staking and borrowing metadata, sudoer timestamp, borrow/interest terms, static deployment data, and role addresses packed in references.[controller.func](../../contracts/controller.func#L512-L534)
- `load_data()` reads the serialized fields back into globals, rehydrating static_data and role references.[controller.func](../../contracts/controller.func#L536-L577)

## Address utilities

- `make_address(wc, addr)` builds a std address slice for a given workchain/id pair (used to derive the elector address).[controller.func](../../contracts/controller.func#L580-L583)
- `elector_address()` loads config param 1, extracts the elector account id, and constructs its masterchain address.[controller.func](../../contracts/controller.func#L585-L588)
- `is_elector_address(address)` compares a slice against the derived elector address.[controller.func](../../contracts/controller.func#L590-L593)

## Stake request validation

- `check_new_stake_msg(cs)` minimally parses a `new_stake` payload (pubkey, timing, max factor, ADNL, signature) and returns the proposed start time; used to ensure message structure before forwarding to the elector.[controller.func](../../contracts/controller.func#L596-L606)

## Main message handler

`recv_internal(balance, msg_value, in_msg_full, in_msg_body)` processes both bounced messages and normal operations. It always loads storage first and persists changes at the end.[controller.func](../../contracts/controller.func#L104-L510)

### Bounce handling

- Bounce from `elector::new_stake` resets state to REST when a previously sent stake failed; otherwise halts as an unexpected bounce.[controller.func](../../contracts/controller.func#L111-L125)
- Bounce from pool repayment or credit request adjusts borrowing bookkeeping: repaid funds increase `borrowed_amount` and set `borrowing_time`, while rejected borrow requests clear pending state or halt on mismatch.[controller.func](../../contracts/controller.func#L126-L137)

### Elector responses (sender is elector)

- `elector::recover_stake_ok`: treated even when halted. Computes profit as returned stake minus originally sent stake, then returns the larger of outstanding loan or loan principal plus profit share to the pool (if balance permits). Resets borrowing and staking markers on success; otherwise marks INSOLVENT.[controller.func](../../contracts/controller.func#L146-L174)
- `elector::recover_stake_error`: when awaiting recover, marks INSOLVENT and halts to avoid repeated fines; otherwise simply halts.[controller.func](../../contracts/controller.func#L174-L183)
- `elector::new_stake_ok/new_stake_error`: during stake request, transitions to FUNDS_STAKEN on success (updating saved validator set hash) or back to REST on failure; unexpected responses halt.[controller.func](../../contracts/controller.func#L186-L199)

### Pool, governor, approver, and halter operations

- `controller::top_up`: lets anyone top up; if INSOLVENT and the new balance exceeds storage + fines + borrowed + fee threshold, returns to REST.[controller.func](../../contracts/controller.func#L204-L212)
- `controller::credit`: only from the pool. Adds credited amount (which already includes interest) to `borrowed_amount`, optional profit share validation against `acceptable_profit_share`, recomputes effective interest from the delta between body and transferred value, and clears pending borrowing state.[controller.func](../../contracts/controller.func#L213-L233)
- `controller::approve`: approver-only; marks approved, sets permissive borrow start offset (65536), and clears allocation limit.[controller.func](../../contracts/controller.func#L234-L243)
- `controller::approve_extended`: approver-only; sets approved with explicit borrow-start timestamp and allocation cap.[controller.func](../../contracts/controller.func#L243-L248)
- `controller::disapprove`: approver-only; revokes approval.[controller.func](../../contracts/controller.func#L248-L253)
- `sudo::send_message`: passes through to sudo handler with sudoer/timestamp validation.[controller.func](../../contracts/controller.func#L253-L256)
- `governor::set_sudoer`: governor-only; updates sudoer and timestamp.[controller.func](../../contracts/controller.func#L256-L261)
- `governor::unhalt`: governor-only; clears halt flag.[controller.func](../../contracts/controller.func#L261-L265)
- `governor::return_available_funds`: governor-only and INSOLVENT-only. Computes available funds as `balance - MIN_TONS_FOR_STORAGE - WITHDRAWAL_FEE`, caps by `borrowed_amount`, and repays that amount to the pool. If debt is cleared, resets borrowing time and returns to REST. **Note:** the subtraction can yield a negative amount when balance is below the minimum, leading to an attempted negative transfer; behavior depends on runtime checks and is likely erroneous.[controller.func](../../contracts/controller.func#L265-L281). This will fail. We are ok with that.
- `halter::halt`: halter-only; sets halt flag without consuming body for analytics.[controller.func](../../contracts/controller.func#L281-L286)

### Operations requiring non-halted state

These branches begin after `assert_not_halted!()` in the main handler.

- `controller::recover_stake`: validator-only while FUNDS_STAKEN. Requires at least two validator-set changes and sufficient elapsed time since unfreeze, plus a minimum message value. Sends `recover_stake` to elector carrying all remaining message value. Validators late beyond grace or with outstanding debt may be fined (paid to the caller if not the validator) when balance allows.[controller.func](../../contracts/controller.func#L287-L334)
- `controller::update_validator_hash`: validator-only while FUNDS_STAKEN. Ensures no more than three hash updates, requires a new validator set hash, records change time/count and max stake holding duration, and fines callers lagging beyond the grace period when balance permits.[controller.func](../../contracts/controller.func#L335-L365)
- `controller::withdraw_validator`: validator-only while REST and debt-free. Withdraws requested amount (must be >0) to validator after reserving storage.[controller.func](../../contracts/controller.func#L366-L379)
- `controller::new_stake`: validator-only while REST. Requires positive `query_id`, sufficient message value (≥ `ELECTOR_OPERATION_VALUE` and `MIN_STAKE_TO_SEND`), solvency against potential fines, and not using borrowed funds beyond allowed window. Records stake metadata and sends `new_stake` to elector paying fees separately.[controller.func](../../contracts/controller.func#L380-L423)
- `controller::send_request_loan`: validator-only while REST and approved. Requires minimum message value for fees, respects optional profit-share field, forbids concurrent loans, enforces election timing windows, and ensures validator balance plus potential loan can cover storage and maximum elector penalties (and optional allocation cap). Sends `pool::request_loan2` with static data and marks pending borrow state.[controller.func](../../contracts/controller.func#L424-L474)
- `controller::return_unused_loan`: validator-only while REST and when debt exists. Requires the loan to have been taken in a prior round (`borrowing_time < current utime_since`). If balance suffices, repays borrowed amount to pool and either returns excess to caller (when timely) or optionally fines late callers when balance allows; otherwise marks INSOLVENT.[controller.func](../../contracts/controller.func#L475-L503)

### Unknown operations

- Any unrecognized `op` after dispatch results in `error::unknown_op` throw.[controller.func](../../contracts/controller.func#L503-L505)

## Getter methods

- `get_validator_controller_data()` returns a tuple snapshot of operational flags, staking metadata, validator set tracking, borrowing terms, profit-sharing limits, debts, addresses, and sudoer, after loading storage.[controller.func](../../contracts/controller.func#L610-L627)
- `get_max_punishment(stake)` proxies to `max_recommended_punishment_for_validator_misbehaviour` for external calculations.[controller.func](../../contracts/controller.func#L630-L632)
- `get_max_stake_value()` returns the maximum stake value permissible in REST state given current balance, reserved storage/penalty buffers, and borrowing recency (disallows staking borrowed funds in the same round). Returns `-1` when insufficient or disallowed.[controller.func](../../contracts/controller.func#L634-L655)
- `required_balance_for_loan(credit, interest)` reports the ensured balance requirement (storage + max elector fine + interest payment) and current validator-owned balance (balance minus borrowed).[controller.func](../../contracts/controller.func#L657-L665)
- `request_window_time()` computes the `(since, until)` window when loan requests are valid based on network config timing relative to current validator set.[controller.func](../../contracts/controller.func#L668-L674)

