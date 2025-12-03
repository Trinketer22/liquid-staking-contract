# `sudoer_requests.func`

Documents sudoer-only entrypoints for executing privileged actions, including generic relayed messages and code/data upgrades.

## Constants
- `SUDOER_QUARANTINE = 2 * 24 * 3600`: enforced cooldown (2 days) after sudoer assignment before sensitive actions are allowed.

Cross-links: uses assertion helpers from [`asserts.md`](./asserts.md).

## `process_sudo_request`
```func
() process_sudo_request(slice sender, slice in_msg, slice sudoer, int sudoer_set_at) impure
```
Intended for arbitrary proxied outbound messages from active sudoer.
- Validates caller with `assert_sender!` against `sudoer` and ensures `now() > sudoer_set_at + SUDOER_QUARANTINE`.
- Loads `mode` (8-bit) and `message` (ref) from `in_msg`, sends it via `send_raw_message(message, mode)`, and requires `in_msg.end_parse()` to consume the payload.

## `process_sudo_upgrade_request`
```func
() process_sudo_upgrade_request(slice sender, slice in_msg, slice sudoer, int sudoer_set_at) impure
```
- Same sender/quarantine checks as `process_sudo_request`.
- Extracts optional references for new `data`, `code`, and `after_upgrade` continuation using `load_maybe_ref`.
- Applies updates: `set_data` if `data` present, `set_code` if `code` present, executes `after_upgrade` continuation if provided.
- Calls `throw(1)` at the end to terminate with an explicit exit code after applying updates (`exit_code=1` is the special `exit_code` that means success and doesn't revert tx, the same as default `exit_code=0`).

## `process_sudo_child_codes_upgrade`
```func
([cell, cell, cell], ()) ~process_sudo_child_codes_upgrade([cell, cell, cell] child_codes, slice sender_address, slice msg, slice sudoer, int sudoer_set_at) inline
```
- Verifies caller/quarantine (the same as above), load payload from `msg` (via a ref slice).
- Unpacks the input triple into `(controller_code, wallet_code, payout_code)`: should be currently set child codes.
- Sequentially loads three `Maybe` code references from the message; when a non-null ref is present, it replaces the corresponding element in the triple.
- Returns the updated triple and an empty tuple (no output except modification).

## `execute`
```func
() execute(cont c) impure asm "EXECUTE";
```
Low-level helper to run a continuation (used after upgrade hook).


