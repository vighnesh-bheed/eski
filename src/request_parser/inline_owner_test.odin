package request_parser

import "core:fmt"
import "core:testing"

@(test)
inline_owner_layout_reuse_growth_and_cleanup :: proc(t: ^testing.T) {
	fmt.printf("Inline_Owner size=%d align=%d pointer=%d\n", size_of(Inline_Owner), align_of(Inline_Owner), size_of(^Inline_Owner))
	owner: ^Inline_Owner
	testing.expect(t, inline_charge(owner) == 0)
	testing.expect(t, inline_reserve(&owner, 0, 65536) && owner == nil)
	testing.expect(t, inline_reserve(&owner, 10, 65536))
	first := owner
	data := raw_data(owner.storage)
	capacity := len(owner.storage)
	testing.expect(t, capacity >= 10 && inline_charge(owner) == size_of(Inline_Owner) + capacity)
	for index in 0..<10 {
		owner.storage[index] = u8(index)
	}
	testing.expect(t, inline_reserve(&owner, 10, 65536))
	testing.expect(t, owner == first && raw_data(owner.storage) == data && len(owner.storage) == capacity)
	testing.expect(t, inline_reserve(&owner, capacity + 1, 65536))
	testing.expect(t, owner == first && len(owner.storage) >= capacity + 1)
	for index in 0..<10 {
		testing.expect(t, owner.storage[index] == u8(index))
	}
	charged := inline_charge(owner)
	testing.expect(t, !inline_reserve(&owner, 65537, 65536))
	testing.expect(t, inline_charge(owner) == charged)
	testing.expect(t, inline_release(&owner) == charged && owner == nil)
	testing.expect(t, inline_release(&owner) == 0)
}

@(test)
inline_owner_cross_connection_descriptor_restore :: proc(t: ^testing.T) {
	first, second: ^Inline_Owner
	defer inline_release(&first)
	defer inline_release(&second)
	testing.expect(t, inline_reserve(&first, 100, 65536))
	testing.expect(t, inline_reserve(&second, 100, 65536))
	for index in 0..<100 {
		first.storage[index] = u8(index)
		second.storage[index] = u8(255 - index)
	}
	scratch: Scratch
	defer destroy(&scratch)
	ensure_args(&scratch, 1)
	scratch.args[0] = first.storage[:100]
	saved := scratch.args[0]
	scratch.args[0] = second.storage[:100]
	testing.expect(t, inline_reserve(&second, 2000, 65536))
	for index in 0..<len(second.storage) {
		second.storage[index] = 255
	}
	scratch.args[0] = saved
	for index in 0..<100 {
		testing.expect(t, scratch.args[0][index] == u8(index))
	}
	testing.expect(t, first != second && raw_data(first.storage) != raw_data(second.storage))
}
