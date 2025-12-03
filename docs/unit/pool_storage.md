# `pool_storage.func`

Describes how pool contract state is loaded and saved. Functions here define the binary layout of persistent data and manage migration between old and new formats.

## Round data helpers
### `load_round_data`
```func
(slice, ([cell, int, int, int, int, int, int, int])) ~load_round_data(slice s)
```
- Reads a reference from `s` and parses:
  1. `borrowers_dict` (cell dictionary)
  2. `round_id` (`uint32`)
  3. `active_borrowers` (`uint32`)
  4. `borrowed` (coins)
  5. `expected` (coins)
  6. `returned` (coins)
  7. `profit` (signed coins)
  8. `withdrawal_rate_prev2_x24` (int64, defaults to `0` if slice is empty)
- Returns the remaining slice and the 8-element tuple.

### `store_round_data`
```func
builder store_round_data(builder b, [cell, int, int, int, int, int, int, int] round_data)
```
Serializes the tuple back into a ref cell with matching field widths/order.

## Minters data
### `load_minters_data`
```func
(slice, ()) ~load_minters_data(slice s) impure
```
- Parses minter-related state from a ref:
  - `jetton_minter` address and total `supply`.
  - `deposit_payout` and `requested_for_deposit` (maybe inline or ref). Both reset to defaults before reading; presence is guarded by a `Maybe` flag and nested `Either` flags.
  - `withdrawal_payout` and `requested_for_withdrawal` with identical layout.
- Updates globals and returns the residual slice.

### `save_minters_data`
```func
builder save_minters_data(builder pb)
```
- Writes current globals into a ref:
  - Always stores `jetton_minter` and `supply`.
  - For `deposit_payout`: stores a `false` flag if null; otherwise stores `true`, an `Either` flag of `false` (inline), the address, and `requested_for_deposit`.
  - For `withdrawal_payout`: stores `false` if null; otherwise `true` then either inline (`Either` `false`) or as a ref (`Either` `true`) if adding both fields would exceed cell limits (`builder_bits() > 1023 - 267 - 124`).
- Returns `pb` with a ref to the constructed cell attached.

Cross-links: mint helper behaviors that update these fields are described in [`pool_mint_helpers.md`](./pool_mint_helpers.md).

## Roles
### `load_roles`
```func
(slice, ()) ~load_roles(slice s) impure
```
- Reads a ref containing `sudoer`, `sudoer_set_at`, `governor`, `governor_update_after`, `interest_manager`, and a nested ref with `halter`, `approver`, and optional `treasury` (defaults to `interest_manager` if omitted).
- Populates the global `roles` tuple (see [`roles_helper.md`](./roles_helper.md)).

### `save_roles`
```func
builder save_roles(builder pb)
```
Serializes the current `roles` tuple into a ref with the same layout as `load_roles`.

## Child codes
### `load_codes`
```func
(slice, ()) ~load_codes(slice s) impure
```
Loads controller, pool jetton wallet, and payout minter code cells from a ref into the global `child_contract_codes` triple.

### `save_codes`
```func
builder save_codes(builder pb)
```
Stores the three code cells into a ref in the same order.

## Data loading entrypoints
### `load_data_new`
```func
() load_data_new() impure
```
Parses the current (new) storage layout from `get_data()`:
1. `state` (`uint8`)
2. `halted?` (bool)
3. `total_balance` (coins)
4. Minters data (`load_minters_data`)
5. `untouched_data` (captures the remainder slice after minters for optimized saving)
6. `interest_rate` (share)
7. `optimistic_deposit_withdrawals` (bool)
8. `deposits_open?` (bool)
9. `instant_withdrawal_fee` (share)
10. `saved_validator_set_hash` (`uint256`)
11. Two rounds (`current_round_borrowers`, `prev_round_borrowers`) via a ref with `load_round_data` twice
12. `loan_params_per_validator` (min/max coins)
13. `governance_fee_share` (share)
14. `accrued_governance_fee` (coins)
15. `disbalance_tolerance` (`uint` sized by `DISBALANCE_BIT_SIZE`)
16. `credit_start_prior_elections_end` (timestamp)
17. Optional `rev_share` (share) if bits remain; otherwise defaults to `0`
18. `deposit_withdrawal_parameters` assembled from the boolean flags, fees, and `rev_share`
19. Roles (`load_roles`)
20. Child codes (`load_codes`)
21. Ensures the slice is fully consumed (`end_parse`).

### `load_data_old`
```func
() load_data_old() impure
```
Parses the legacy storage layout, omitting newer fields:
- Reads through `governance_fee_share`, roles, and child codes.
- Sets `deposit_withdrawal_parameters` to `[optimistic_deposit_withdrawals, deposits_open?, 0, 0]` (zero fees/shares) and does not populate `accrued_governance_fee`, `disbalance_tolerance`, `credit_start_prior_elections_end`, or `rev_share`.

### `load_data`
```func
() load_data() impure
```
- Attempts `load_data_new` inside a `try`. On failure, falls back to `load_data_old` and sets defaults:
  - `disbalance_tolerance = 30`
  - `credit_start_prior_elections_end = 0`
  - `accrued_governance_fee = 0`
  - `instant_withdrawal_fee` already zeroed in `deposit_withdrawal_parameters`
- Comment notes that a guard to prevent double-loading is currently disabled.

## Data saving
### `save_data`
```func
() save_data() impure
```
Serializes the full new layout back to `set_data`:
- Emits all fields in the same order as `load_data_new`, writing round data via `store_round_data`, minter info via `save_minters_data`, roles with `save_roles`, and codes with `save_codes`.
- `deposit_withdrawal_parameters` are destructured into `optimistic_deposit_withdrawals`, `deposits_open?`, `instant_withdrawal_fee`, and `rev_share` (defaults from globals).

### `save_data_optimised`
```func
() save_data_optimised() impure
```
- If `untouched_data` is null (no cached slice), defers to `save_data` to rewrite everything.
- Otherwise writes a minimal cell containing only `state`, `halted?`, `total_balance`, current minter data, and the previously saved `untouched_data` slice to reduce serialization cost.
