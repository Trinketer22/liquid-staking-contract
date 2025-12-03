# address_calculations.func

Utilities for constructing initial data/state cells for controller and payout contracts and deriving their addresses.

## Globals
- `global [cell, cell, cell] child_contract_codes`: expected to hold code cells for the controller, pool jetton wallet, and payout minter; used when building state-inits.
- `global slice consigliere;`: declared but unused in this module.

## Functions

### `slice addr_none()`
Returns the serialized `MsgAddress` representing the null/none address using the opcode `b{00}`. Useful as a placeholder address when initializing storage fields.

### `builder store_zeros(builder b, int n)`
Assembler helper that writes `n` zero bits into builder `b`. Not used.

### `cell controller_init_data(cell static_data)`
Constructs the controller contract persistent data cell. Fields are written in order with explicit bit widths and default zero/false values:
1. `uint8 state` (starts at 0)
2. `bool halted?` (false)
3. `bool approved` (false)
4. `coins stake_amount_sent`
5. `timestamp stake_at`
6. `uint128 saved_validator_set_hash` (upper 128 bits)
7. `uint8 validator_set_changes_count`
8. `timestamp validator_set_change_time`
9. `timestamp stake_held_for`
10. `coins borrowed_amount`
11. `timestamp borrowing_time`
12. `uint2 sudoer` (set to `addr_none` encoding)
13. `timestamp sudoer_set_at`
14. `share max_expected_interest`
15. `timestamp allowed_borrow_start_prior_elections_end`
16. `share approver_set_profit_share`
17. `share acceptable_profit_share`
18. `coins allocation`
19. `ref static_data` provided by caller

The layout is sized to stay within one cell (<1024 bits). Default values ensure deterministic state before any configuration updates.

### `cell controller_init_state(cell static_data)`
Builds the full state-init cell for the controller contract. Serializes the split depth and special flags (both absent), optionally stores the controller code from `child_contract_codes.triple_first()`, embeds the data cell from `controller_init_data(static_data)`, and writes an empty libraries bit (1 bit set to 0). Returns the finished state-init cell that can be hashed for address calculation.

### `slice calc_address(int workchain, cell state_init)`
Derives the standard address slice for the given `state_init` in `workchain`. Encodes the `addr_std$10` prefix, workchain id, and 256-bit hash of the provided state-init. Returns a parsed slice ready for use as destination or comparison.

### `cell calculate_payout_state_init(slice pool_address, int round_id, int distributing_jettons?)`
Constructs the state-init for a payout NFT contract (used for deposit or withdrawal payouts). Steps:
1. Build an on-chain metadata dictionary with dynamic fields: name (`"Deposit Payout#<round>"` or `"Withdrawal Payout#<round>"`), description dependent on `distributing_jettons?`, symbol set to `⏲️`, URIs for metadata/image, render_type `hidden`, and a `random_seed` that combines `random()` (after `randomize_lt()` to shuffle based on logical time) and the hash of current contract data (`get_data().cell_hash()`).
2. Create `onchain_content` cell wrapping the metadata dict with prefix tag `0` and store it in data alongside administrative fields: zero `total_supply`, `admin_address` set to `my_address()`, empty distribution ref, and the metadata reference.
3. Assemble the state-init with absent split depth/special, optional code from `child_contract_codes.triple_third()`, and the built data cell, leaving libraries empty.

This function produces unpredictable payout addresses thanks to the randomized metadata entry; the resulting cell can be passed to `calc_address` to compute the address for a specific round.
