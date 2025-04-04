import "@stdlib/tvm-lowlevel"
import "asserts.tolk"
import "errors.tolk"


const SUDOER_QUARANTINE = 2 * 24 * 3600 ;

@inline_ref
fun processSudoRequest(sender: slice, inMsg: slice, sudoer: slice, sudoerSetAt: int) {
    `assert_sender!`(sender, sudoer);
    assert(now() > sudoerSetAt + SUDOER_QUARANTINE) throw `sudoer::quarantine`;
    var mode: int = inMsg.loadUint(8);
    var message: cell  = inMsg.loadRef();
    sendRawMessage(message, mode);
    inMsg.assertEndOfSlice();
}


fun execute(c: continuation): void
    asm "EXECUTE";
@inline_ref
fun processSudoUpgradeRequest(sender: slice, inMsg: slice, sudoer: slice, sudoerSetAt: int) {
    `assert_sender!`(sender, sudoer);
    assert(now() > sudoerSetAt + SUDOER_QUARANTINE) throw `sudoer::quarantine`;
    var data: cell? = inMsg.loadMaybeRef();
    var code: cell? = inMsg.loadMaybeRef();
    var afterUpgrade: cell? = inMsg.loadMaybeRef();
    inMsg.assertEndOfSlice();
    if (data != null) {
      setContractData(data);
    }
    if (code != null) {
      setContractCodePostponed(code);
    }
    if (afterUpgrade != null) {
      execute(afterUpgrade.beginParse().transformSliceToContinuation());
    }
    throw 1;
}
