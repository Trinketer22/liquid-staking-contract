import "types.tolk"

// int_msg_info$0 ihr_disabled:Bool bounce:Bool bounced:Bool src:MsgAddress -> 011000
const `msgflag::NON_BOUNCEABLE` = 0x10;
const `msgflag::BOUNCEABLE` = 0x18;

const `sendmode::REGULAR` = 0;
const `sendmode::PAY_FEES_SEPARATELY` = 1;
const `sendmode::IGNORE_ERRORS` = 2;
const `sendmode::DESTROY` = 32;
const `sendmode::CARRY_ALL_REMAINING_MESSAGE_VALUE` = 64;
const `sendmode::CARRY_ALL_BALANCE` = 128;

const `reservemode::STRICT` = 0;
const `reservemode::AT_MOST` = 2;

@inline
fun storeMsgFlags(b: builder, msgFlag: int): builder { return b.storeUint(msgFlag, 6); }

/*
  Helpers below fill in default/overwritten values of message layout:
  Relevant part of TL-B schema:
  ... other:ExtraCurrencyCollection ihr_fee:Grams fwd_fee:Grams created_lt:uint64 created_at:uint32 = CommonMsgInfoRelaxed;
  bits      1                               4             4                64                32                            
  ... init:(Maybe (Either StateInit ^StateInit))  body:(Either X ^X) = Message X;
  bits      1      1(if prev is true)                   1

*/

@inline
fun storeMsgbodyPrefixStateinit(b: builder, stateInit: cell, ref: cell): builder {
    return b.storeUint(4 + 2 + 1, 1 + 4 + 4 + 64 + 32 + 1 + 1 + 1).storeRef(stateInit).storeRef(ref);
}

@inline
fun storeMsgbodyPrefixStateinitSlice(b: builder, stateInit: cell): builder {
    return b.storeUint(4 + 2 + 0, 1 + 4 + 4 + 64 + 32 + 1 + 1 + 1).storeRef(stateInit);
}

@inline
fun storeMsgbodyPrefixSlice(b: builder): builder {
    return b.storeUint(0, 1 + 4 + 4 + 64 + 32 + 1 + 1);
}
@inline
fun storeMsgbodyPrefixRef(b: builder, ref: cell): builder {
    return b.storeUint(1, 1 + 4 + 4 + 64 + 32 + 1 + 1).storeRef(ref);
}

/*

addr_std$10 anycast:(Maybe Anycast) 
   workchain_id:int8 address:bits256  = MsgAddressInt;
*/

@inline
fun storeMasterchainAddress(b: builder, addressHash: int): builder {
  return b.storeUint(4, 3).storeWorkchain(MASTERCHAIN).storeUint(addressHash, 256);
}


@inline_ref
fun sendMsg(toAddress: slice, amount: int, payload: cell?, flags: int, sendMode: int) {

    var msg: builder = beginCell()
        .storeMsgFlags(flags)
        .storeSlice(toAddress)
        .storeCoins(amount);

    if (payload != null) {
        msg = msg.storeMsgbodyPrefixRef(payload);
    } else {
        msg = msg.storeMsgbodyPrefixSlice();
    }

    sendRawMessage(msg.endCell(), sendMode);
}

@inline_ref
fun sendMsgBuilder(toAddress: slice, amount: int, payload: builder, flags: int, sendMode: int) {
    var msg: builder = beginCell()
        .storeMsgFlags(flags)
        .storeSlice(toAddress)
        .storeCoins(amount);

    try {
        // store body in slice, may overflow
        msg = msg
                .storeMsgbodyPrefixSlice()
                .storeBuilder(payload);
    } catch {
        // overflowed, lets store in ref
        msg = msg
                .storeMsgbodyPrefixRef(beginCell().storeBuilder(payload).endCell());
    }

    sendRawMessage(msg.endCell(), sendMode);
}

@inline_ref
fun sendExcesses(senderAddress: slice) {
    sendMsg(
      senderAddress,
      0, // value
      null,
      `msgflag::NON_BOUNCEABLE`,
      `sendmode::CARRY_ALL_REMAINING_MESSAGE_VALUE` | `sendmode::IGNORE_ERRORS`); // non-bouneable, remaining inbound message amount, fee deducted from amount, ignore errors
}



@inline
fun emitLog(topic: int, data: builder) {
    // 1023 - (4+2+9+256+64+32+2) = 654 bit free

    var msg = beginCell()
            .storeUint (12, 4)         // ext_out_msg_info$11 src:MsgAddressInt ()
            .storeUint (1, 2)          // addr_extern$01
            .storeUint (256, 9)        // len:(## 9)
            .storeUint(topic, 256); // external_address:(bits len)
    try {
        // store body in slice, may overflow
        msg = msg.storeUint(0, 64 + 32 + 2) // created_lt, created_at, init:Maybe, body:Either
                .storeBuilder(data);
    } catch {
        // overflowed, lets store in ref
        msg = msg.storeUint(1, 64 + 32 + 2) // created_lt, created_at, init:Maybe, body:Either
                .storeRef(beginCell().storeBuilder(data).endCell());
    }

    sendRawMessage(msg.endCell(), `sendmode::REGULAR`);
}
