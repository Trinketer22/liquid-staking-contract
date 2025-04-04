import "pool.tolk"
import "op-codes.tolk"
import "messages.tolk"
import "address_calculations.tolk"

@inline_ref
fun sendMintMessage(minter: slice, queryId: int, destination: slice, amount: int, notificationTon: int, forwardTon: int, totalTon: int, mode: int) {
    var mintRequest: builder = beginCell()
            .storeBodyHeader(`payout::mint`, queryId)
            .storeSlice(destination)
            .storeCoins(amount) // max 124 bit
            .storeCoins(notificationTon)
            .storeCoins(forwardTon);
    var msg = beginCell()
            .storeMsgFlags(`msgflag::BOUNCEABLE`)
            .storeSlice(minter)
            .storeCoins(totalTon) //TRANSFER_NOTIFICATION_AMOUNT + JETTON_WALLET_FEE + MINT_FEE)
            .storeMsgbodyPrefixSlice()
            .storeBuilder(mintRequest);
    sendRawMessage(msg.endCell(), mode); // pay transfer fees separately, revert on errors
}

@inline_ref
fun requestToMintPoolJettons(destination: slice, amount: int, queryId: int, isForUser: bool) {
    if (isForUser) {
        sendMintMessage(jetton_minter, queryId, destination, amount,
                TRANSFER_NOTIFICATION_AMOUNT,
                0,
                0,
                `sendmode::CARRY_ALL_BALANCE`);
    } else {
        sendMintMessage(jetton_minter, queryId, destination, amount,
                TRANSFER_NOTIFICATION_AMOUNT,
                0,
                TRANSFER_NOTIFICATION_AMOUNT + PAYOUT_DISTRIBUTION_AMOUNT,
                `sendmode::REGULAR`
        );
    }
    supply += amount;
}

@inline
fun requestToMintDeposit(destination: slice, amount: int, queryId: int) {
    if((deposit_payout == null)) {
        // we need to deploy new minter
        var stateInit: cell = calculatePayoutStateInit(getMyAddress(), currentRoundIndex(), true);
        var toAddress: slice = calcAddress(JETTONS_WORKCHAIN, stateInit);
        deposit_payout = toAddress;
        var depositMinterJettonWallet: slice = calcAddress(JETTONS_WORKCHAIN,
                calculateJettonWalletStateInit(toAddress, jetton_minter, child_contract_codes.1)
        );
        var msg: builder = beginCell()
                .storeMsgFlags(`msgflag::BOUNCEABLE`)
                .storeSlice(deposit_payout!)
                .storeCoins(MINTER_DEPLOY_FEE)
                .storeMsgbodyPrefixStateinitSlice(stateInit)
                .storeBodyHeader(`payout::init`, getLogicalTime())
                .storeRef(
                        beginCell()
                                .storeBool(false) // distribution not started
                                .storeBool(true) // jettons
                                .storeCoins(0)
                                .storeSlice(depositMinterJettonWallet)
                                .endCell()
                );
        sendRawMessage(msg.endCell(), `sendmode::REGULAR`);
    }
    sendMintMessage(deposit_payout!, queryId, destination, amount,
            TRANSFER_NOTIFICATION_AMOUNT,
            0,
            0,
            `sendmode::CARRY_ALL_BALANCE`
    );
    requested_for_deposit += amount;
}

@inline
fun requestToMintWithdrawal(destination: slice, amount: int, queryId: int) {
    if((withdrawal_payout == null)) {
        // we need to deploy new minter
        var stateInit: cell = calculatePayoutStateInit(getMyAddress(), currentRoundIndex(), false);
        var toAddress: slice = calcAddress(JETTONS_WORKCHAIN, stateInit);
        withdrawal_payout = toAddress;
        var msg: builder = beginCell()
                .storeMsgFlags(`msgflag::BOUNCEABLE`)
                .storeSlice(withdrawal_payout!)
                .storeCoins(MINTER_DEPLOY_FEE)
                .storeMsgbodyPrefixStateinitSlice(stateInit)
                .storeBodyHeader(`payout::init`, getLogicalTime())
                .storeRef(
                        beginCell()
                                .storeBool(false) // distribution not started
                                .storeBool(false) // not jettons
                                .storeCoins(0)
                                .endCell()
                );
        sendRawMessage(msg.endCell(), `sendmode::REGULAR`);
    }
    sendMintMessage(withdrawal_payout!, queryId, destination, amount,
            TRANSFER_NOTIFICATION_AMOUNT,
            0,
            0,
            `sendmode::CARRY_ALL_BALANCE`
    );
    requested_for_withdrawal += amount;
}
