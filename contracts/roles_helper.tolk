
global roles: [slice, int, slice, int, slice, slice, slice, slice];

@pure
fun getSudoer(roles_: [slice, int, slice, int, slice, slice, slice, slice]): slice
    asm "0 INDEX";
@pure
fun getSudoerSetAt(roles_: [slice, int, slice, int, slice, slice, slice, slice]): int
    asm "1 INDEX";
@pure
fun getGovernor(roles_: [slice, int, slice, int, slice, slice, slice, slice]): slice
    asm "2 INDEX";
@pure
fun getGovernorUpdateAfter(roles_: [slice, int, slice, int, slice, slice, slice, slice]): int
    asm "3 INDEX";
@pure
fun getInterestManager(roles_: [slice, int, slice, int, slice, slice, slice, slice]): slice
    asm "4 INDEX";
@pure
fun getHalter(roles_: [slice, int, slice, int, slice, slice, slice, slice]): slice
    asm "5 INDEX";
@pure
fun getApprover(roles_: [slice, int, slice, int, slice, slice, slice, slice]): slice
    asm "6 INDEX";
@pure
fun getTreasury(roles_: [slice, int, slice, int, slice, slice, slice, slice]): slice
    asm "7 INDEX";


@pure
fun setSudoerInternal(roles_: [slice, int, slice, int, slice, slice, slice, slice], sudoer: slice): [slice, int, slice, int, slice, slice, slice, slice]
    asm "0 SETINDEX";
@inline
fun setSudoer(sudoer: slice) {
    roles = setSudoerInternal(roles, sudoer);
}
@pure
fun setSudoerSetAtInternal(roles_: [slice, int, slice, int, slice, slice, slice, slice], setAt: int): [slice, int, slice, int, slice, slice, slice, slice]
    asm "1 SETINDEX";
@inline
fun setSudoerSetAt(setAt: int) {
    roles = setSudoerSetAtInternal(roles, setAt);
}
@pure
fun setGovernorInternal(roles_: [slice, int, slice, int, slice, slice, slice, slice], governor: slice): [slice, int, slice, int, slice, slice, slice, slice]
    asm "2 SETINDEX";
@inline
fun setGovernor(governor: slice) {
    roles = setGovernorInternal(roles, governor);
}
@pure
fun setGovernorUpdateAfterInternal(roles_: [slice, int, slice, int, slice, slice, slice, slice], updateAfter: int): [slice, int, slice, int, slice, slice, slice, slice]
    asm "3 SETINDEX";
@inline
fun setGovernorUpdateAfter(updateAfter: int) {
    roles = setGovernorUpdateAfterInternal(roles, updateAfter);
}
@pure
fun setInterestManagerInternal(roles_: [slice, int, slice, int, slice, slice, slice, slice], interestManager: slice): [slice, int, slice, int, slice, slice, slice, slice]
    asm "4 SETINDEX";
@inline
fun setInterestManager(interestManager: slice) {
    roles = setInterestManagerInternal(roles, interestManager);
}
@pure
fun setHalterInternal(roles_: [slice, int, slice, int, slice, slice, slice, slice], halter: slice): [slice, int, slice, int, slice, slice, slice, slice]
    asm "5 SETINDEX";
@inline
fun setHalter(halter: slice) {
    roles = setHalterInternal(roles, halter);
}
@pure
fun setApproverInternal(roles_: [slice, int, slice, int, slice, slice, slice, slice], approver: slice): [slice, int, slice, int, slice, slice, slice, slice]
    asm "6 SETINDEX";
@inline
fun setApprover(approver: slice) {
    roles = setApproverInternal(roles, approver);
}
@pure
fun setTreasuryInternal(roles_: [slice, int, slice, int, slice, slice, slice, slice], treasury: slice): [slice, int, slice, int, slice, slice, slice, slice]
    asm "7 SETINDEX";
@inline
fun setTreasury(treasury: slice) {
    roles = setTreasuryInternal(roles, treasury);
}
