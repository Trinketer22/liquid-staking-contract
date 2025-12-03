# `roles_helper.func`

Reference for role storage helpers managing privileged addresses in the pool contract.

## Role tuple layout
The global `roles` value is an 8-element tuple:
1. `sudoer` (address(slice))
2. `sudoer_set_at` (int timestamp)
3. `governor` (address(slice))
4. `governor_update_after` (int timestamp)
5. `interest_manager` (address(slice))
6. `halter` (address(slice))
7. `approver` (address(slice))
8. `treasury` (address(slice))

## Getters
Each getter reads a specific position using `INDEX`:
- `get_sudoer` / `get_sudoer_set_at`
- `get_governor` / `get_governor_update_after`
- `get_interest_manager`
- `get_halter`
- `get_approver`
- `get_treasury`

These functions return slices or ints and have no side effects.

## Setters
Setters use `SETINDEX` to mutate `roles` in-place, updating the global tuple.

- `set_sudoer`, `set_sudoer_set_at`
- `set_governor`, `set_governor_update_after`
- `set_interest_manager`
- `set_halter`
- `set_approver`
- `set_treasury`

All setters are `impure inline` and simply replace the indexed element. They perform no validation; callers must enforce authorization and timeline checks (see [`asserts.md`](./asserts.md) for assertion helpers).

