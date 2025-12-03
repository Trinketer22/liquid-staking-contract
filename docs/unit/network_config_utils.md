# network_config_utils.func

Helpers for reading TON global configuration parameters related to validator elections and penalties. All functions assume the environment provides access to `config_param` and other standard TVM primitives.

## Constants
- `ONE_TON = 1_000_000_000`: convenience multiplier for expressing whole TON amounts.

## Functions

### `int max_recommended_punishment_for_validator_misbehaviour(int stake) inline_ref`
Computes the recommended penalty for validator misbehavior based on config parameter 40. Logic:
1. Fetch `config_param(40)`. If absent (`null`), return a default of `101 * ONE_TON` (matches lite-client fallback).
2. Parse the parameter slice extracting: an 8-bit prefix (ignored), default flat and proportional fines, severity multipliers (flat and proportional), unpunishable interval, long interval, and long multipliers (flat and proportional).
3. Initialize `fine` to the default flat fine and `fine_part` to the proportional fine. Apply severity multipliers (`>> 8` normalizes after multiplying), then long multipliers with the same normalization.
4. Return the minimum of `stake` and `fine + muldiv(stake, fine_part, 1 << 32)`, matching elector contract calculations. This caps the punishment at the validator’s stake and scales proportional fines using 32-bit fixed-point math.

### `(int, int, int) get_validator_config() inline`
Reads config parameter 15 and returns `(elections_start_before, stake_held_for, elections_end_before)` derived from the parameter layout. Uses `preload_uint` for `stake_held_for` to avoid advancing the slice unnecessarily. Callers can destructure to access individual timing windows.

### `int get_stake_held_for() inline_ref`
Convenience wrapper around `get_validator_config` returning only `stake_held_for` (duration staking remains locked after elections end).

### `int get_elections_start_before() inline_ref`
Convenience wrapper returning `elections_start_before` (how long before the round start elections open).

### `(int, int, cell) get_current_validator_set() inline_ref`
Parses config parameter 34 describing the current validator set. Steps:
1. Load the cell and begin parsing; enforce that the first 8 bits equal `0x12` (`validators_ext#12`). Throws error code `9` on mismatch.
2. Read `utime_since` and `utime_until` (32 bits each) representing the current validation round’s start and projected end. `utime_until` combines with `stake_held_for` (from config 15) to compute unfreeze times in higher-level logic.
3. Return `(utime_since, utime_until, vset_cell)` where `vset_cell` is the raw config cell for further parsing (e.g., individual validators).

## Cross-references
These timing values often gate state transitions guarded by assertions described in [asserts.func](./asserts.md) and may influence message scheduling using helpers in [messages.func](./messages.md).
