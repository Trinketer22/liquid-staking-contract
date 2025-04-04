import "errors.tolk"
import "globals.tolk"

@inline
fun `assert_sender!`(sender: slice, requiredAddress: slice) {
  assert(isSliceBitsEqual(sender, requiredAddress)) throw `error::wrong_sender`;
}

const `state::HALTED` = 0xff;

@inline
fun `assert_not_halted!`() {
  assert(!(is_halted)) throw `error::halted`;
}

@inline
fun `assert_state!`(expected: int) {
  assert(state == expected) throw `error::wrong_state`;
}
@inline
fun `assert_1of2_state!`(expected1: int, expected2: int) {
  assert((state == expected1) | (state == expected2)) throw `error::wrong_state`;
}
