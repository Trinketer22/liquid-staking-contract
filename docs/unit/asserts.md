# asserts.func

This file defines small guard helpers around common failure conditions. They rely on error codes provided by `errors.func` and the global control variables stored in contract data.

## Globals
- `int state`: current contract state flag used by state assertions.
- `int halted?`: boolean-like flag indicating whether the contract is halted.
- `const int state::HALTED = 0xff`: sentinel value representing the halted state.

## Functions

### `() assert_sender!(slice sender, slice required_address) impure inline`
Checks that an inbound message comes from an expected address. Throws `error::wrong_sender` unless `sender` and `required_address` share identical bits. No return value; execution halts on mismatch.

### `() assert_not_halted!() impure inline`
Verifies the contract is not halted. Throws `error::halted` if the global `halted?` flag is set. Use before operations that should be disabled when the contract is halted.

### `() assert_state!(int expected) impure inline`
Confirms the global `state` matches `expected`. Throws `error::wrong_state` otherwise. Suitable for state-machine transitions that require an exact prior state.

### `() assert_1of2_state!(int expected1, int expected2) impure inline`
Similar to `assert_state!` but allows two acceptable states. Throws `error::wrong_state` unless `state` equals either `expected1` or `expected2`.
