// general
@inline
fun loadTimestamp(mutate self: slice): int { return self.loadUint(48); }
@inline
fun storeTimestamp(b: builder, timestamp: int): builder { return b.storeUint(timestamp, 48); }

// @inline
// fun loadBool(mutate self: slice): int { return self.loadInt(1); }
// @inline
// fun storeBool(b: builder, flag: int): builder { return b.storeInt(flag, 1); }

@inline
fun loadWorkchain(mutate self: slice): int { return self.loadInt(8); }
@inline
fun storeWorkchain(b: builder, wc: int): builder { return b.storeInt(wc, 8); }

// Op-codes

@inline
fun loadOp(mutate self: slice): int { return self.loadUint(32); }
@inline
fun loadQueryId(mutate self: slice): int { return self.loadUint(64); }
@inline
fun loadBodyHeader(mutate self: slice): (int, int) {
    var op: int = self.loadUint(32);
    var queryId: int = self.loadUint(64);
    return (op, queryId);
}


@inline
fun skipBounce(mutate self: slice): void { self.skipBits(32); return;}

@inline
fun storeOp(b: builder, op: int): builder { return b.storeUint(op, 32); }
@inline
fun storeQueryId(b: builder, queryId: int): builder { return b.storeUint(queryId, 64); }
@inline
fun storeBodyHeader(b: builder, op: int, queryId: int): builder {
    return b.storeUint(op, 32)
            .storeUint(queryId, 64);
}

// Pool types

@inline
fun loadShare(mutate self: slice): int { return self.loadUint(24); }
@inline
fun storeShare(b: builder, share: int): builder { return b.storeUint(share, 24); }
const SHARE_BASIS = 256 * 256 * 256; // 24 bit


@inline
fun loadControllerId(mutate self: slice): int { return self.loadUint(32); }
@inline
fun storeControllerId(b: builder, id: int): builder { return b.storeUint(id, 32); }


@inline
fun loadSignedCoins(mutate self: slice): int {
    var sign: int = self.loadInt(1) * 2 + 1;
    var coins: int = self.loadCoins();
    return coins * sign;
}
@inline
fun storeSignedCoins(b: builder, amount: int): builder {
    return b.storeBool(amount < 0).storeCoins(abs(amount));
}

const ADDR_SIZE = 256; // bits
