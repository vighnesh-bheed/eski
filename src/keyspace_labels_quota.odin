package main

import lb "label"

ERR_LABEL_QUOTA_OOM :: "OOM command not allowed when used memory > 'label-quota'."

label_quotas: map[lb.Id]int

label_quota_active :: #force_inline proc "contextless" () -> bool {
	return len(label_quotas) > 0
}

label_partition_bytes :: proc "contextless" (p: ^Db) -> int {
	return p.t[0].size + p.t[1].size + p.next.size + p.slab.live + p.heap_bytes
}

label_used :: proc(id: lb.Id) -> int {
	total := 0
	for i in 0 ..< len(label_dbs) {
		if p := label_part(i, id); p != nil {
			total += label_partition_bytes(p)
		}
	}
	return total
}

label_quota_check :: proc(cmd: ^Command, spec: ^Cmd_Spec) -> string {
	if spec == nil || .Denyoom not_in spec.flags {
		return ""
	}
	quota, ok := label_quotas[access.id]
	if !ok {
		return ""
	}
	used := label_used(access.id)
	if used <= quota {
		return ""
	}
	evict_in_label(int(access.id), used - quota)
	if label_used(access.id) > quota {
		return ERR_LABEL_QUOTA_OOM
	}
	return ""
}
