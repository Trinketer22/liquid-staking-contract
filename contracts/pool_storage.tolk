import "pool.tolk"
import "roles_helper.tolk"
import "address_calculations.tolk"
import "globals.tolk"

//[borrowers_dict, round_id, active_borrowers, borrowed, expected, returned, profit]
@inline
fun loadRoundData(mutate self: slice): ([cell?, int, int, int, int, int, int]) {
    var ds: slice = self.loadRef().beginParse();
    var data = [ds.loadDict(),             // borrowers
                ds.loadUint(32),           // round_id
                ds.loadUint(32),           // active_borrowers
                ds.loadCoins(),            // borrowed
                ds.loadCoins(),            // expected
                ds.loadCoins(),            // returned
                ds.loadSignedCoins()];    // profit
   return (data);
}

@inline
fun storeRoundData(b: builder, roundData: [cell?, int, int, int, int, int, int]): builder {
  var [borrowersDict, roundId, activeBorrowers, borrowed, expected, returned, profit] = roundData;
  var serialized: cell = beginCell()
                     .storeDict(borrowersDict)
                     .storeUint(roundId, 32)
                     .storeUint(activeBorrowers, 32)
                     .storeCoins(borrowed)
                     .storeCoins(expected)
                     .storeCoins(returned)
                     .storeSignedCoins(profit)
                     .endCell();
  return b.storeRef(serialized);
}


@inline
fun loadMintersData(mutate self: slice): void {
    var ds: slice = self.loadRef().beginParse();
    jetton_minter = ds.loadAddress();
    supply = ds.loadCoins();

    deposit_payout = null;
    requested_for_deposit = 0;
    // (Maybe (Either X, ^X))
    if(ds.loadBool()) {
      if(ds.loadBool()) {
        var ajmS: slice = ds.loadRef().beginParse();
        deposit_payout = ajmS.loadAddress();
        requested_for_deposit = ajmS.loadCoins();
      } else {
        deposit_payout = ds.loadAddress();
        requested_for_deposit = ds.loadCoins();
      }
    }

    withdrawal_payout = null;
    requested_for_withdrawal = 0;
    //(Maybe (Either X, ^X)) 
    if(ds.loadBool()) {
      if(ds.loadBool()) {
          var atmS: slice = ds.loadRef().beginParse();
          withdrawal_payout = atmS.loadAddress();
          requested_for_withdrawal = atmS.loadCoins();
      } else {
          withdrawal_payout = ds.loadAddress();
          requested_for_withdrawal = ds.loadCoins();
      }
    }
    return;
}

@inline
fun saveMintersData(pb: builder): builder {
    var b: builder = beginCell()
                 .storeSlice(jetton_minter)
                 .storeCoins(supply);
    if(deposit_payout == null) {
      b.storeBool(false);
    } else {
      b.storeBool(true) // Maybe
       .storeBool(false) //Either X
       .storeSlice(deposit_payout!)
       .storeCoins(requested_for_deposit);
    }
    if(withdrawal_payout == null) {
      b = b.storeBool(false);
    } else {
      b = b.storeBool(true);
      if(b.getBuilderBitsCount() > 1023 - 267 - 124) {
        b = b.storeBool(true) //Either ^X
              .storeRef(
              beginCell()
                .storeSlice(withdrawal_payout!)
                .storeCoins(requested_for_withdrawal)
              .endCell()
            );
      } else {
        b = b.storeBool(false) //Either X
             .storeSlice(withdrawal_payout!)
             .storeCoins(requested_for_withdrawal);
      }
    }
    return pb.storeRef(b.endCell());
}



@inline
fun loadRoles(mutate self: slice): void {
    var ds: slice = self.loadRef().beginParse();
    var sudoer: slice = ds.loadAddress();
    var sudoerSetAt: int = ds.loadTimestamp();
    var governor: slice = ds.loadAddress();
    var governorUpdateAfter: int = ds.loadTimestamp();
    var interestManager: slice = ds.loadAddress();
    ds = ds.loadRef().beginParse();
    var halter: slice = ds.loadAddress();
    var approver: slice = ds.loadAddress();
    var treasury: slice = ds.getRemainingBitsCount() ? ds.loadAddress() : interestManager;
    roles = [sudoer, sudoerSetAt, governor, governorUpdateAfter, interestManager,
             halter, approver, treasury];
    return;
}

@inline
fun saveRoles(pb: builder): builder {
    var [sudoer: slice, sudoerSetAt: int,
     governor: slice, governorUpdateAfter: int,
     interestManager: slice, halter: slice, approver: slice, treasury: slice] = roles;
    var rolesRef: cell = beginCell()
                     .storeSlice(sudoer)
                     .storeTimestamp(sudoerSetAt)
                     .storeSlice(governor)
                     .storeTimestamp(governorUpdateAfter)
                     .storeSlice(interestManager)
                     .storeRef(
                       beginCell()
                       .storeSlice(halter)
                       .storeSlice(approver)
                       .storeSlice(treasury)
                       .endCell()
                      )
                     .endCell();
   return pb.storeRef(rolesRef);
}

@inline
fun loadCodes(mutate self: slice): void {
    var ds: slice = self.loadRef().beginParse();
    var controllerCode: cell = ds.loadRef();
    var poolJettonWalletCode: cell = ds.loadRef();
    var payoutMinterCode: cell = ds.loadRef();
    child_contract_codes = [controllerCode, poolJettonWalletCode, payoutMinterCode];
    return;
}

@inline
fun saveCodes(pb: builder): builder {
    var [controllerCode: cell, poolJettonWalletCode: cell, payoutMinterCode: cell]
    = child_contract_codes;
    var codes: cell = beginCell()
                 .storeRef(controllerCode)
                 .storeRef(poolJettonWalletCode)
                 .storeRef(payoutMinterCode)
                 .endCell();
   return pb.storeRef(codes);
}

global untouched_data: slice?;

@inline_ref
fun loadDataNew() {

    var ds: slice = getContractData().beginParse();
    state = ds.loadUint(8);
    is_halted = ds.loadBool();
    total_balance = ds.loadCoins();
    ds.loadMintersData();
    untouched_data = ds;
    interest_rate = ds.loadShare();
    var optimisticDepositWithdrawals: bool = ds.loadBool();
    var isDepositsOpen: bool = ds.loadBool();
    var instantWithdrawalFee: int = ds.loadShare();
    deposit_withdrawal_parameters = [optimisticDepositWithdrawals, isDepositsOpen,
                                     instantWithdrawalFee];
    saved_validator_set_hash = ds.loadUint(256);
    var roundData: slice = ds.loadRef().beginParse();
    current_round_borrowers = roundData.loadRoundData();
    prev_round_borrowers = roundData.loadRoundData();
    loan_params_per_validator = [ds.loadCoins(), ds.loadCoins()];
    governance_fee_share = ds.loadShare();
    accrued_governance_fee = ds.loadCoins();
    disbalance_tolerance = ds.loadUint(DISBALANCE_BIT_SIZE);
    credit_start_prior_elections_end = ds.loadTimestamp();
    ds.loadRoles();
    ds.loadCodes();
    ds.assertEndOfSlice();
}

@inline_ref
fun loadDataOld() {

    var ds: slice = getContractData().beginParse();
    state = ds.loadUint(8);
    is_halted = ds.loadBool();
    total_balance = ds.loadCoins();
    ds.loadMintersData();
    untouched_data = ds;
    interest_rate = ds.loadShare();
    var optimisticDepositWithdrawals: bool = ds.loadBool();
    var isDepositsOpen: bool = ds.loadBool();
    deposit_withdrawal_parameters = [optimisticDepositWithdrawals, isDepositsOpen, 0];
    saved_validator_set_hash = ds.loadUint(256);
    var roundData: slice = ds.loadRef().beginParse();
    current_round_borrowers = roundData.loadRoundData();
    prev_round_borrowers = roundData.loadRoundData();
    loan_params_per_validator = [ds.loadCoins(), ds.loadCoins()];
    governance_fee_share = ds.loadShare();
    ds.loadRoles();
    ds.loadCodes();
    ds.assertEndOfSlice();
}

@inline_ref
fun loadData() {
    // this check should be removed in production
    // it ensures that load_data is not loaded twice
    //throw_unless(2222, state.null?());

    // if storage doesn't fit updated layout, parse it as old and fill new fields by default values
    try {
        loadDataNew();
    } catch {
        loadDataOld();
        disbalance_tolerance = 30;
        // zero means do not check time
        credit_start_prior_elections_end = 0;
        accrued_governance_fee = 0;
        // also 0 for instant_withdrawal_fee in deposit_withdrawal_parameters
    }
}

@inline_ref
fun saveData() {
    var [minLoanPerValidator: int, maxLoanPerValidator: int] = loan_params_per_validator;
    var [optimisticDepositWithdrawals: bool,
     isDepositsOpen: bool,
     instantWithdrawalFee: int] = deposit_withdrawal_parameters;
    // 8 + 1 + 124 + 24 + 1 + 1 + 256 + 124 + 124 + 24 + 8 + 48 + 24 + 124 + 124
    setContractData(beginCell()
        .storeUint(state, 8)
        .storeBool(is_halted)
        .storeCoins(total_balance)
        .saveMintersData()
        .storeShare(interest_rate)
        .storeBool(optimisticDepositWithdrawals)
        .storeBool(isDepositsOpen)
        .storeShare(instantWithdrawalFee)
        .storeUint(saved_validator_set_hash, 256)
        .storeRef(
          beginCell()
          .storeRoundData(current_round_borrowers)
          .storeRoundData(prev_round_borrowers)
          .endCell()
        )
        .storeCoins(minLoanPerValidator)
        .storeCoins(maxLoanPerValidator)
        .storeShare(governance_fee_share)
        .storeCoins(accrued_governance_fee)
        .storeUint(disbalance_tolerance, DISBALANCE_BIT_SIZE)
        .storeTimestamp(credit_start_prior_elections_end)
        .saveRoles()
        .saveCodes()
        .endCell()
    );
}

@inline_ref
fun saveDataOptimised() {
    if(untouched_data == null) {
        return saveData();
    }
    setContractData(beginCell()
        .storeUint(state, 8)
        .storeBool(is_halted)
        .storeCoins(total_balance)
        .saveMintersData()
        .storeSlice(untouched_data!)
    .endCell());
}
