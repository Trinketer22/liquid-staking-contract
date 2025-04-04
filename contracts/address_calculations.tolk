import "@stdlib/tvm-dicts"
import "metadata_utils.tolk"
import "types.tolk"
import "auto/metadata.tolk"

// [controller_code, pool_jetton_wallet_code, payout_minter_code]
global child_contract_codes: [cell, cell, cell];

@pure
fun addrNone(): slice
    asm "b{00} PUSHSLICE";
@pure
fun storeZeros(b: builder, n: int): builder
    asm "STZEROES";

fun controllerInitData(staticData: cell): cell {
  // TODO optimize with store_zeros
  // Note, given maximal amounts equal to 5'000'000'000 TONs
  // all store_coins sizes are limited to 67 bits
  // so the size is at most 8+1+1+67+48+128+8+48+48+67+48+267+48+24+48+24+24+67 = 974 bits
  return beginCell()
            .storeUint(0, 8) // state
            .storeBool(false)  // halted
            .storeBool(false)  // approved
            .storeCoins(0) // stake_amount_sent
            .storeTimestamp(0) // stake_at
            .storeUint(0, 128) // saved_validator_set_hash higher 128 bits
            .storeUint(0, 8) // validator_set_changes_count
            .storeTimestamp(0) // validator_set_change_time
            .storeTimestamp(0) // stake_held_for
            .storeCoins(0) // borrowed_amount
            .storeTimestamp(0) // borrowing_time
            .storeUint(0, 2) // sudoer addr_none
            .storeTimestamp(0) // sudoer_set_at
            .storeShare(0)     // max_expected_interest
            .storeTimestamp(0) // allowed_borrow_start_prior_elections_end
            .storeShare(0)    // approver_set_profit_share
            .storeShare(0)    // acceptable_profit_share
            .storeCoins(0)    // allocation
            .storeRef(staticData)
           .endCell();
}

fun controllerInitState(staticData: cell): cell {
    return beginCell()
            .storeUint(0, 1 + 1) // split_depth (Maybe = 0) and special (Maybe = 0)
            .storeMaybeRef(child_contract_codes.0)
            .storeMaybeRef(controllerInitData(staticData))
            .storeUint(0,1) // libraries - empty cell
            .endCell();
}


@inline
fun calcAddress(workchain: int, stateInit: cell): slice {
    return beginCell().storeUint(4, 3) // 0x100 : $10 + anycast (Maybe = 0)
            .storeWorkchain(workchain)
            .storeUint(
                    cellHash(stateInit), 256)
            .endCell()
            .beginParse();
}

// global consigliere: slice;

fun calculatePayoutStateInit(poolAddress: slice, roundId: int, isDistributingJettons: bool): cell {
  var contentDict: cell? = createEmptyDict();
  // TODO optimize
  var name: slice = concat(isDistributingJettons ? "Deposit " : "Withdrawal ", concat("Payout#", encodeNumberToText(roundId, 10)));
  contentDict.uDictSetRef(256, stringSha256("name"), packMetadataValue(name));
  if (isDistributingJettons) {
    contentDict.uDictSetRef(256, stringSha256("description"), packMetadataValue("Converts deposited TON to Pool Jettons"));
  } else {
    contentDict.uDictSetRef(256, stringSha256("description"), packMetadataValue("Converts burned Pool Jettons to TON"));
  }
  contentDict.uDictSetRef(256, stringSha256("symbol"), packMetadataValue("⏲️"));
  contentDict.uDictSetRef(256, stringSha256("uri"), packMetadataValue(NFT_URI));
  contentDict.uDictSetRef(256, stringSha256("image"), packMetadataValue(NFT_IMAGE_URI));
  contentDict.uDictSetRef(256, stringSha256("render_type"), packMetadataValue("hidden"));
  // To make payout address unpredictable we use two sources of difficult to know in advance data:
  // Hash of contract storage and block random seed
  randomizeByLogicalTime();
  contentDict.uDictSetRef(256, stringSha256("random_seed"), beginCell().storeUint(random() >> 8, 256).storeUint(getContractData().cellHash(), 256).endCell());
  var onchainContent: cell = beginCell().storeUint(0, 8).storeDict(contentDict).endCell();
  
  
  var data: cell =  beginCell()
            .storeCoins(0)                   // total_supply
            .storeSlice(getMyAddress())        // admin_address
            .storeMaybeRef(null)          // Distribution
            .storeRef(onchainContent)       // Content
           .endCell();
  return beginCell()
            .storeUint(0, 1 + 1) // split_depth (Maybe = 0) and special (Maybe = 0)
            .storeMaybeRef(child_contract_codes.2)
            .storeMaybeRef(data)
            .storeUint(0,1) // libraries - empty cell
            .endCell();
}

@inline
fun packJettonWalletData(balance: int, owner: slice,
                              jettonMaster: slice, tokenWalletCode: cell,
                              locked: int, lockedExpiration: int): cell {
    return  beginCell()
            .storeCoins(balance)
            .storeSlice(owner)
            .storeSlice(jettonMaster)
            .storeRef(tokenWalletCode)
            .storeCoins(locked)
            .storeTimestamp(lockedExpiration)
            .endCell();
}
/*
    _ split_depth:(Maybe (## 5)) special:(Maybe TickTock)
      code:(Maybe ^Cell) data:(Maybe ^Cell)
      library:(HashmapE 256 SimpleLib) = StateInit;
*/
@inline
fun calculateJettonWalletStateInit(owner: slice, jettonMaster: slice, code: cell): cell {
    return beginCell()
            .storeUint(0,1 + 1) // split_depth (Maybe = 0) and special (Maybe = 0)
            .storeMaybeRef(code)
            .storeMaybeRef(packJettonWalletData(0, owner, jettonMaster, code, 0, 0))
            .storeUint(0,1) // libraries - empty cell
            .endCell();
}
