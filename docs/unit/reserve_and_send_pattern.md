# Reserve + send flow

A peculiarity of TON is that an incoming message carries a TON value without any built-in split between what will be used for gas and what should be treated as the financial asset of the operation.

The approach we use in this protocol is a virtual separation. For each relevant operation we conceptually split the incoming message value into a gas buffer (used to pay for execution, with any unused remainder sent back to the user or downstream to the next contract) and a financial part.

To correctly send the unused part of the gas buffer back to the user (given that the exact gas usage cannot be known during VM execution), we do the following:

* we calculate the expected contract balance that should remain as the financial part after adding the incoming financial amount and subtracting all outgoing transfers created during execution
* we reserve exactly this amount on the balance
* this means that after reservation the remaining "free" part of the balance at the end of VM execution will be exactly the leftovers of the gas buffer
* as the final message we send a message back to the user (or downstream) with flag `CARRY_ALL_BALANCE` (which sends everything that has not yet been sent or reserved)

In code the pattern looks roughly like this:

```c
recv_internal(int balance, int msg_value) {

  ;; let it be a deposit
  int deposit_amount = msg_value - DEPOSIT_FEE;
  ;; Note: DEPOSIT_FEE is not charged to the user. It is a "gas buffer" that ensures
  ;; that all operations complete successfully. Any unused part of this buffer is returned to the user.
  
  ... possible "rotation" operations, including sending messages ...
  ... collect all sent amounts into sent_during_rotation ...
  
  raw_reserve(balance - DEPOSIT_FEE - sent_during_rotation, reservemode::STRICT);
  ...
  send_raw_message( ... , sendmode::CARRY_ALL_BALANCE);
}
```

If, for example, we want the entire incoming message value to be available for gas, but also want to withdraw some additional funds to the user, we do:

```c
  raw_reserve(
    balance - msg_value - what_we_want_withdraw - what_we_already_sent,
    reservemode::STRICT
  );
  ...
  send_raw_message( ... , sendmode::CARRY_ALL_BALANCE);
```

Note that `balance` passed into `recv_internal` is the balance after `msg_value` has been credited. For example, to get the balance before this message arrived, you calculate `balance - msg_value`.

