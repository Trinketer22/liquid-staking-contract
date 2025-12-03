# Pool contract function reference

## Utility helpers

- `current_round_index()` returns the `round_id` stored in `current_round_borrowers` using the inline accessor created in `pool_storage.func`. [pool.func](../../contracts/pool.func#L113-L117)
- `muldiv_extra(a, b, c)` mirrors `muldiv` but shortcuts to `a` when `b == c`, avoiding division by zero when both operands are zero and preserving exact results when `b == c`. [pool.func](../../contracts/pool.func#L130-L136)
- `_get_projected_conversion_ratio()` forecasts `(projected_balance, projected_supply)` at round end using `prev_round_borrowers.expected` and governance fee rules. When revenue sharing is disabled it adds expected profit (minus finalize fee and governance fee) to `total_balance`; with revenue sharing it leaves balances unchanged. Negative profit is clamped so balance never drops below zero. [pool.func](../../contracts/pool.func#L636-L684) [pool.func](../../contracts/pool.func#L816-L842)

## Round rotation

- `update_round(available_balance)` resets per-rotation counters, bails out when halted, and compares the current validator set hash with `saved_validator_set_hash`.

When the hash changes and the previous round is still active (non-empty borrowers or active borrowers), it flags `current_round_closed?` and exits. Otherwise it finalizes the previous lending round via `finalize_lending_round`, logs rotation, swaps `prev_round_borrowers` and `current_round_borrowers`, updates the saved hash, and clears the closed flag. [pool.func](../../contracts/pool.func#L138-L164)

Idea is the following: we restrict number of rounds in which we provide funds to controllers to 2. So, when hash changes it means a new validation round has started. At this moment usually N-2 round is not yet finished, because controllers will get funds from elector after some freeze delay (the only exception of this "usually" is when in N-2 round nobody got credit at all). So we temporally close ability to provide credits and wait till N-2 round borrowers will return all credits (to rotate rounds and start providing credits for new round).

## Message receiver

`recv_internal(balance, msg_value, in_msg_full, in_msg_body)` is the entrypoint handling all operations. It decodes bounce flags, extracts sender, and dispatches on `op`. Many branches rely on assertion helpers (see [asserts](./asserts.md)). [pool.func](../../contracts/pool.func#L166-L399)

### Control and governance

- `halter::halt`: requires the halter role and sets `halted?` without consuming the body to preserve analytics context. [pool.func](../../contracts/pool.func#L187-L192)
- `sudo::send_message` / `sudo::upgrade`: routed to sudo handlers with sudoer authorization and timestamp checks. [pool.func](../../contracts/pool.func#L215-L222)
- `sudo::set_codes`: delegates code upgrades for child contracts to `process_sudo_child_codes_upgrade`. [pool.func](../../contracts/pool.func#L223-L226)
- `governor::set_sudoer`: governor-only; updates sudoer address and quarantine timestamp. [pool.func](../../contracts/pool.func#L227-L234)
- `governor::unhalt`: clears `halted?`. [pool.func](../../contracts/pool.func#L235-L238)
- `governor::prepare_governance_migration`: schedules governor replacement; enforces a 1-day quarantine before it can be applied. [pool.func](../../contracts/pool.func#L239-L247)
- `governor::set_roles`: governor-only; conditionally rotates governor (respecting quarantine), interest manager, halter, approver, and optionally treasury roles based on boolean flags encoded in the body. [pool.func](../../contracts/pool.func#L248-L270)
- `governor::set_deposit_settings`: governor-only; updates optimistic deposit/withdraw flags, instant withdrawal fee, and revenue share. When enabling revenue sharing it requires a non-zero historical withdrawal rate. [pool.func](../../contracts/pool.func#L271-L288)
- `governor::set_governance_fee`: governor-only; sets `governance_fee_share`. [pool.func](../../contracts/pool.func#L289-L293)
- `interest_manager::set_interest`: interest-manager-only; requires normal state and updates `interest_rate`. [pool.func](../../contracts/pool.func#L294-L299)
- `interest_manager::set_operational_params`: interest-manager-only; adjusts min/max per-validator loan bounds, disbalance tolerance, and the earliest time to start credit requests; rejects contradictory min/max. [pool.func](../../contracts/pool.func#L300-L312)
- `halter::partial_halt`: halter-only; optionally disables optimistic flow and closes deposits while preserving other parameters. [pool.func](../../contracts/pool.func#L313-L327)

### Withdrawals (jetton burn)

- `pool::withdraw` (from jetton minter):
parses burned jettons and sender, then 
* if (optimistic TON payout is enabled) and (user asked for immediate payout) and (we have funds) :
  * estimate TON value to be withdrawed using current or previous withdrawal rates (if revenue sharing enabled), deduct instant-withdrawal fees to governance, adjusts `total_balance`/`supply`, and send corresponding sum to user (to correctly cover unspent gas we first reserve on balance everythin except what should be sent to user and then send everything else).
* else: Check whether user asked to return jettons if immediate withdrawal is unavailable (`fill_or_kill` flag). If not enough - throw exception. Mint payout vaucher (pessimistic flow). 

Catch block handles any failures by re-minting pool jettons back to the user. [pool.func](../../contracts/pool.func#L192-L215) [pool.func](../../contracts/pool.func#L216-L259)

### Deposits and donations

- `pool::deposit`: requires normal state and open deposits. With optimistic mode it estimates minted pool jettons using projected conversion ratio, mints immediately, and increments `total_balance`. Otherwise it mints deposit tokens for deferred accounting. Both paths reserve gas and ensure positive deposit value. [pool.func](../../contracts/pool.func#L334-L367)
- `pool::donate`: treats the transferred value minus deposit fee as a direct increase to `total_balance`, reserves gas, and sends an excess notification back to donor. [pool.func](../../contracts/pool.func#L501-L515)

### Loan lifecycle

- `pool::request_loan` / `pool::request_loan2`: only in normal state and when the round is open. Validates timing against validator config, per-validator min/max constraints, and disbalance tolerance. Computes available liquidity after reserving for pending withdrawals. For revenue share requests (`request_loan2` with `rev_share` enabled), ensures profit share meets minimum and sends a credit message carrying the requested share. Otherwise checks maximum interest, computes accrued interest at pool rate, and sends credit covering principal plus interest. Loans are logged, added to the borrower dictionary via `add_loan`, and limited so per-validator borrowing plus interest does not exceed configured max. Also notifies the interest manager with the requested bounds. [pool.func](../../contracts/pool.func#L368-L453)
- `pool::loan_repayment`: tries to close the loan in previous round first, then current; rejects unknown borrowers. When the last borrower of a round repays, triggers `update_round` to rotate and finalize. [pool.func](../../contracts/pool.func#L454-L470)
- `pool::get_controller_loan_position`: iterates sorted borrower dictionary to find the median distance for a controller’s loan for deterministic voting; throws if the controller is not found. [pool.func](../../contracts/pool.func#L872-L900)
- `calculate_loan_amount(min_loan, max_loan, max_interest)` (get method): performs the same availability checks as `request_loan` but returns the maximum repayable amount (principal + pool interest) or `-1` if borrowing is currently disallowed. [pool.func](../../contracts/pool.func#L902-L941)

### Round finalization and payouts

- `finalize_lending_round(borrowers_data, available_balance)`: requires no active borrowers and an empty dictionary. Computes the previous withdrawal rate, applies finalize fee and governance fee (using accrued carry-over), clamps losses to available `total_balance`, updates balances, pays treasury and interest manager, logs the round, and calls `finalize_deposit_withdrawal_round` to start distributions. Returns a fresh borrowers tuple for the next round with incremented `round_id` and persisted withdrawal rate. [pool.func](../../contracts/pool.func#L636-L684)
- `finalize_deposit_withdrawal_round(available_balance, round_id)`: orchestrates distribution of TON withdrawals and jetton mints for deferred deposits by calling `initiate_distribution_of_tons` and `initiate_distribution_of_pool_jettons`. [pool.func](../../contracts/pool.func#L710-L713)
- `initiate_distribution_of_tons(available_balance, round_id)`: if there are pending withdrawals, computes TON to send proportionally, halts the pool when insufficient balance, otherwise reduces `supply`, clears requests, deducts from `total_balance`, and sends payout start message with notification amount. Marks `sent_during_rotation` for gas tracking. [pool.func](../../contracts/pool.func#L714-L744)
- `initiate_distribution_of_pool_jettons(round_id)`: if deposits are pending, mints pool jettons for `deposit_payout` at current ratio (or 1:1 when supply is zero), increments `total_balance`, clears requests, and tracks gas spent. [pool.func](../../contracts/pool.func#L745-L758)

### Minting helpers

- `request_to_mint_pool_jettons`, `request_to_mint_deposit`, `request_to_mint_withdrawal`: included from `pool_mint_helpers.func`; see [pool mint helpers](./pool_mint_helpers.md) for their behavior. [pool.func](../../contracts/pool.func#L118-L127)

### Controller deployment and addressing

- `build_controller_address(controller_id, validator)`: constructs controller static data with ids, validator address, pool address, governor, and ref-packed approver/halter; derives init state and calculated address for the masterchain. [pool.func](../../contracts/pool.func#L516-L534)
- `_get_controller_address(controller_id, validator)` and `get_controller_address` simply expose the calculated address (stateful method loads data first). `get_controller_address_legacy` supports legacy parameterization by workchain/hash. [pool.func](../../contracts/pool.func#L759-L784)
- `get_loan(controller_id, validator_address, prev?, update?)`: optionally updates the round, picks current or previous borrowers, and returns borrowed principal and accounted interest for the specified controller address, or zeros if absent. [pool.func](../../contracts/pool.func#L801-L820)

### Data exposure and logging

- `compose_pool_full_data_internal(update?)` aggregates all storage fields (optionally after `update_round`) into a single tuple for getters. `get_pool_full_data` calls it with updates; `get_pool_full_data_raw` skips updates. [pool.func](../../contracts/pool.func#L822-L870)
- Log helpers `log_loan`, `log_repayment`, `log_round_completion`, and `log_round_rotation` emit structured events for analytics during loan issuance, repayment, round completion, and rotation respectively. [pool.func](../../contracts/pool.func#L686-L709)

## Lending dictionary helpers

- `add_loan(borrowers_data, borrower, loan_body, interest)`: validates the controller workchain, updates or inserts borrower totals (including accrued interest), increments active count when new, and enforces a maximum cell depth to bound dictionary growth. Returns updated borrowers data and total borrowed from that controller. [pool.func](../../contracts/pool.func#L535-L607)
- `close_loan(borrowers_data, borrower, amount)`: removes borrower entry if found, updates profit/returned counters, logs repayment, decrements active borrower count, and signals whether this was the last active borrower. [pool.func](../../contracts/pool.func#L608-L634)

