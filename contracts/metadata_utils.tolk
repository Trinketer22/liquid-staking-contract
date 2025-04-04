@inline
fun packMetadataValue(a: slice): cell {
    return beginCell().storeUint(0, 8).storeSlice(a).endCell();
}

fun encodeNumberToText(decimals: int, radix: int): slice {
    var str: builder = beginCell();
    var ctr: int  = 0;
    var chars: tuple =  createEmptyTuple();

    do {
        var (decimals redef, rem: int) = divMod(decimals, radix);

        chars.tuplePush( rem >= 10 ? 87 + rem : 48 + rem);
        ctr += 1;
    } while (!(decimals == 0));

    repeat( ctr ) {
        str     = str.storeUint(chars.tupleAt(ctr - 1), 8);
        ctr    -= 1;
    }

    return str.endCell().beginParse();
}

@inline
fun concat(a: slice, b: slice): slice {
    return beginCell().storeSlice(a).storeSlice(b).endCell().beginParse();
}
