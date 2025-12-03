# `pool_mint_helpers.func`

Documentation for mint-related helper routines used by the pool contract. These helpers coordinate minting on the jetton minter and payout minters, deploying the payout contracts when necessary.

## `send_mint_message`
```func
() send_mint_message(slice minter, int query_id, slice destination, int amount, int notification_ton, int forward_ton, int total_ton, int mode) impure inline_ref
```
Builds and sends a raw outbound message to a jetton minter.

- Encodes the `payout::mint` body header with `query_id`, followed by the destination address, the jetton amount to mint, and the TON amounts for notification and forwarded payload.
- Wraps the body into parent message with `BOUNCEABLE` flag, targeting `minter`, carrying `total_ton` TON (caller-supplied to cover notification/fees), and using `mode` when sending.
- Calls `send_raw_message` and expects the caller to choose a mode that handles fees (the contract uses `CARRY_ALL_BALANCE` or `REGULAR`).

## `request_to_mint_pool_jettons`
```func
() request_to_mint_pool_jettons(slice destination, int amount, int query_id, int for_user?) impure inline_ref
```
Requests the pool jetton minter to mint tokens for `destination`.

- When `for_user?` is true, sends a mint message with `sendmode::CARRY_ALL_BALANCE`, forwarding only the notification value and carrying no extra TON beyond the transfer itself.
- When `for_user?` is false (pool-owned mint), forwards additional TON equal to `TRANSFER_NOTIFICATION_AMOUNT + PAYOUT_DISTRIBUTION_AMOUNT` with `sendmode::REGULAR` so the payout minter can immediately distribute funds.
- In both cases increments the global `supply` variable by `amount` after dispatching the mint message.

Cross-links: relies on message conventions documented in [`messages.md`](./messages.md) for BOUNCEABLE flag use and fee handling.

## `request_to_mint_deposit`
```func
() request_to_mint_deposit(slice destination, int amount, int query_id) impure inline
```
Mints deposit jettons to `destination`, deploying the deposit payout minter if absent.

- If `deposit_payout` is unset, computes payout `state_init` via `calculate_payout_state_init(my_address(), current_round_index(), true)` and derives its address with `calc_address`. Stores it in `deposit_payout`.
- Pre-computes the payout minter’s jetton wallet for the pool’s jetton using `calculate_jetton_wallet_state_init(to_address, jetton_minter, child_contract_codes.triple_second())` and embeds it in the deployment payload.
- Sends a BOUNCEABLE deployment message with `MINTER_DEPLOY_FEE`, the `state_init`, a `payout::init` body carrying `cur_lt()`, and a ref containing flags (`distribution not started`, `jettons payout`), zeroed coins, and the wallet address.
- Afterwards, issues a mint request to the newly determined `deposit_payout` using `sendmode::CARRY_ALL_BALANCE`, forwarding only the notification TON.
- Increments `requested_for_deposit` by `amount`.

## `request_to_mint_withdrawal`
```func
() request_to_mint_withdrawal(slice destination, int amount, int query_id) impure inline
```
Mints withdrawal jettons to `destination`, deploying the withdrawal payout minter if absent.

- If `withdrawal_payout` is unset, computes payout `state_init` via `calculate_payout_state_init(my_address(), current_round_index(), false)` and derives the address, storing it in `withdrawal_payout`.
- Sends a BOUNCEABLE deployment message with `MINTER_DEPLOY_FEE`, carrying the `state_init`, `payout::init` body, and a ref with flags (`distribution not started`, `not jettons`) and zero balance.
- Issues a mint request to `withdrawal_payout` with `sendmode::CARRY_ALL_BALANCE`, forwarding only notification TON.
- Increments `requested_for_withdrawal` by `amount`.

