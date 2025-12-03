# messages.func

Messaging helpers for constructing and sending TON messages. Functions focus on encoding flags, addresses, and message bodies while handling payload size overflow.

## Constants
- Message flags: `msgflag::NON_BOUNCEABLE`, `msgflag::BOUNCEABLE` encode the 6-bit info header.
- Send modes: `sendmode::REGULAR`, `sendmode::PAY_FEES_SEPARATELY`, `sendmode::IGNORE_ERRORS`, `sendmode::DESTROY`, `sendmode::CARRY_ALL_REMAINING_MESSAGE_VALUE`, `sendmode::CARRY_ALL_BALANCE`.
- Reserve modes: `reservemode::STRICT`, `reservemode::AT_MOST` (not used directly here but exposed for callers).

## Helper encoders

### `builder store_msg_flags(builder b, int msg_flag) inline`
Stores the 6-bit message flags prefix into `b`. Used by all sending helpers.

### `builder store_msgbody_prefix_stateinit(builder b, cell state_init, cell ref) inline`
Writes the CommonMsgInfo layout bits for a message that includes both a state-init reference and a body reference. Returns the updated builder storing both refs.

### `builder store_msgbody_prefix_stateinit_slice(builder b, cell state_init) inline`
Encodes the CommonMsgInfo bits for a message carrying a state-init reference and an inlined (slice) body. Caller appends the body bits after this prefix.

### `builder store_msgbody_prefix_slice(builder b) inline`
Encodes the message header for messages with inlined body data and no state-init. Used when the payload fits into the same cell without extra references.

### `builder store_msgbody_prefix_ref(builder b, cell ref) inline`
Encodes the message header for messages whose body is stored in a referenced cell `ref`. Useful when payload would overflow the inlined representation.

### `builder store_masterchain_address(builder b, int address_hash) inline`
Stores the masterchain workchain prefix and a 256-bit address hash into the builder, producing a masterchain `MsgAddressInt` slice. Suitable for destination or source encoding in other helpers.

## Sending helpers

### `() send_msg(slice to_address, int amount, cell payload, int flags, int send_mode) impure inline_ref`
Sends a message to `to_address` transferring `amount` nanoton. If `payload` is non-null, it is stored as a reference body; otherwise an empty inline body is encoded. The caller controls bounceability via `flags` and delivery behavior via `send_mode`. Uses `send_raw_message` after constructing the message cell.

### `() send_msg_builder(slice to_address, int amount, builder payload, int flags, int send_mode) impure inline_ref`
Like `send_msg` but accepts a payload builder. Attempts to inline the payload; if storing the builder overflows the cell, it falls back to storing the payload in a reference cell. Behavior is otherwise identical to `send_msg`.

### `() send_excesses(slice sender_address) impure inline_ref`
Returns all remaining inbound message value to `sender_address` with a non-bounceable message. Uses send mode `CARRY_ALL_REMAINING_MESSAGE_VALUE | IGNORE_ERRORS` so it drains remaining balance from the inbound transfer, ignores delivery failures, and sends zero explicit value.

### `() emit_log(int topic, builder data) impure inline`
Emits an external outbound log message with `topic` as the external address field (256 bits). Encodes the message as `ext_out_msg_info`, inlining the body when possible; on overflow it stores the body in a reference. Sends with `sendmode::REGULAR`. Useful for off-chain event logging.
