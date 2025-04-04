const ONE_TON = 1000000000;

// https://github.com/ton-blockchain/ton/blob/ae5c0720143e231c32c3d2034cfe4e533a16d969/crypto/block/block.tlb#L721
@inline_ref
fun maxRecommendedPunishmentForValidatorMisbehaviour(stake: int): int {
    var cp: cell? = getBlockchainConfigParam(40);
    if (cp == null) {
        return 101 * ONE_TON; // 101 TON - https://github.com/ton-blockchain/ton/blob/b38d227a469666d83ac535ad2eea80cb49d911b8/lite-client/lite-client.cpp#L3678
    }

    var cs: slice = cp.beginParse();

    var (prefix: int,
     defaultFlatFine: int, defaultProportionalFine: int,
     severityFlatMult: int, severityProportionalMult: int,
     unpunishableInterval: int,
     longInterval: int, longFlatMult: int, longProportionalMult: int) =
        (cs.loadUint(8),
         cs.loadCoins(), cs.loadUint(32),
         cs.loadUint(16), cs.loadUint(16),
         cs.loadUint(16),
         cs.loadUint(16), cs.loadUint(16), cs.loadUint(16)
        );

     // https://github.com/ton-blockchain/ton/blob/master/lite-client/lite-client.cpp#L3721
     var fine: int = defaultFlatFine;
     var finePart: int = defaultProportionalFine;

     fine *= severityFlatMult; fine >>= 8;
     finePart *= severityProportionalMult; finePart >>= 8;

     fine *= longFlatMult; fine >>= 8;
     finePart *= longProportionalMult; finePart >>= 8;

     return min(stake, fine + mulDivFloor(stake, finePart, 1 << 32)); // https://github.com/ton-blockchain/ton/blob/b38d227a469666d83ac535ad2eea80cb49d911b8/crypto/smartcont/elector-code.fc#L529
}

// https://github.com/ton-blockchain/ton/blob/b38d227a469666d83ac535ad2eea80cb49d911b8/crypto/block/block.tlb#L632
// https://github.com/ton-blockchain/ton/blob/b38d227a469666d83ac535ad2eea80cb49d911b8/crypto/smartcont/elector-code.fc#L118
@inline
fun getValidatorConfig(): (int, int, int) {
    var cs: slice = getBlockchainConfigParam(15)!.beginParse();
    var (validatorsElectedFor: int, electionsStartBefore: int, electionsEndBefore: int, StakeHeldFor: int) = (cs.loadUint(32), cs.loadUint(32), cs.loadUint(32), cs.preloadUint(32));
    return (electionsStartBefore, StakeHeldFor, electionsEndBefore);
}

@inline_ref
fun getStakeHeldFor(): int {
    var (electionsStartBefore: int, StakeHeldFor: int, _) = getValidatorConfig();
    return StakeHeldFor;
}
@inline_ref
fun getElectionsStartBefore(): int {
    var (electionsStartBefore: int, StakeHeldFor: int, _) = getValidatorConfig();
    return electionsStartBefore;
}

// https://github.com/ton-blockchain/ton/blob/b38d227a469666d83ac535ad2eea80cb49d911b8/crypto/block/block.tlb#L712
@inline_ref
fun getCurrentValidatorSet(): (int, int, cell) {
    var vset: cell = getBlockchainConfigParam(34)!; // current validator set
    var cs: slice = vset.beginParse();
    // https://github.com/ton-blockchain/ton/blob/b38d227a469666d83ac535ad2eea80cb49d911b8/crypto/block/block.tlb#L579
    // https://github.com/ton-blockchain/ton/blob/b38d227a469666d83ac535ad2eea80cb49d911b8/crypto/smartcont/config-code.fc#L49
    assert(cs.loadUint(8) == 0x12) throw 9;  // validators_ext#12 only
    var utimeSince: int = cs.loadUint(32); // actual start unixtime of current validation round
    var utimeUntil: int = cs.loadUint(32); // supposed end unixtime of current validation round (utime_until = utime_since + validators_elected_for); unfreeze_at = utime_until + stake_held_for
    return (utimeSince, utimeUntil, vset);
}
