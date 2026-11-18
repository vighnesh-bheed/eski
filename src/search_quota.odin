package main

import dt "doctable"
import fi "ftindex"
import lb "label"
import ow "owner"
import vt "vsettype"
import "vmath"

SEARCH_DEFINITION_BASE :: 4096
SEARCH_PARTITION_BASE :: 16384
SEARCH_OFFSET_CHARGE :: 96

Search_Memory_Kind :: enum {
	Keys,
	Documents,
	Inverted,
	Offsets,
	Tag,
	Text,
	Vector,
	Overhead,
}

Search_Bytes :: [Search_Memory_Kind]int

@(private = "file")
search_label_charges: map[lb.Id]int

search_owner_charges: map[ow.Owner]int

search_charge_sum :: proc "contextless" (sizes: Search_Bytes) -> (bytes: int) {
	for size in sizes {
		bytes += size
	}
	return
}

search_scope_charged :: proc(scope: ow.Scope) -> int {
	if scope.owner == ow.SHARED {
		return search_label_charges[scope.label]
	}
	return search_owner_charges[scope.owner]
}

@(private = "file")
search_charge_adjust :: proc(charges: ^map[$K]int, key: K, change: int) {
	if change == 0 {
		return
	}
	bytes := charges^[key] + change
	if bytes < 0 {
		store_fatal("invalid search quota accounting")
	}
	if bytes == 0 {
		delete_key(charges, key)
		if len(charges^) == 0 {
			delete(charges^)
			charges^ = nil
		} else if cap(charges^) / 4 > len(charges^) {
			shrink(charges)
		}
		return
	}
	if charges^ == nil {
		charges^ = make(map[K]int, vt.ledger_allocator(&search_memory))
	}
	charges^[key] = bytes
}

search_scope_charge :: proc(scope: ow.Scope, change: int) {
	if !labels_on {
		return
	}
	if scope.owner == ow.SHARED {
		search_charge_adjust(&search_label_charges, scope.label, change)
	} else {
		search_charge_adjust(&search_owner_charges, scope.owner, change)
	}
}

@(private = "file")
search_schema_bytes :: proc "contextless" (def: ^fi.Definition) -> int {
	bytes := 4 * (len(def.language_field) + len(def.score_field) + len(def.payload_field))
	for f in def.fields {
		bytes += 512 + 4 * (len(f.name) + len(f.source))
	}
	for word in def.stop_words {
		bytes += 128 + 4 * len(word)
	}
	return bytes
}

search_definition_bytes :: proc "contextless" (name: string, spec: ^Search_Create) -> int {
	bytes := SEARCH_DEFINITION_BASE + search_schema_bytes(&spec.definition) + 2 * len(name)
	for prefix in spec.prefixes {
		bytes += 96 + 2 * len(prefix)
	}
	return bytes
}

search_part_schema_bytes :: proc "contextless" (def: ^fi.Definition) -> Search_Bytes {
	bytes := #partial Search_Bytes{.Overhead = SEARCH_PARTITION_BASE + search_schema_bytes(def) + 2048 * len(def.fields)}
	for f in def.fields {
		if f.kind == .Vector {
			bytes[.Vector] += search_vector_base(f.vector)
		}
	}
	return bytes
}

@(private = "file")
search_vector_stride :: proc "contextless" (v: fi.Vector_Options) -> int {
	return (v.dim * vmath.elem_size(v.elem) + 63) &~ 63
}

@(private = "file")
search_vector_base :: proc "contextless" (v: fi.Vector_Options) -> int {
	return 4096 + 4 * search_vector_stride(v)
}

search_vector_bytes :: proc(part: ^Search_Partition, i: int) -> (base, rows: int) {
	source := part.data.slots[i].vector
	if source == nil {
		return
	}
	v := part.data.definition.fields[i].vector
	units := 1024 + 8 * search_vector_stride(v)
	if v.method == .Hnsw {
		units += 1024 * v.m
	}
	return search_vector_base(v), units * source.count(source.ctx)
}

search_document_key_bytes :: proc "contextless" (name: string) -> int {
	return 128 + 2 * len(name)
}

search_document_bytes :: proc "contextless" (name: string, size: fi.Content_Size) -> Search_Bytes {
	return #partial Search_Bytes {
		.Keys = search_document_key_bytes(name),
		.Documents = 256,
		.Inverted = 1024 * size.text_entries + 256 * (size.numbers + size.missing),
		.Text = 512 * size.text_entries + 4 * size.term_bytes,
		.Offsets = SEARCH_OFFSET_CHARGE * size.positions,
		.Tag = 512 * size.tag_entries + 4 * size.tag_bytes,
	}
}

search_document_release :: proc(part: ^Search_Partition, id: u32) {
	if bytes, found := part.members[id]; found {
		part.content -= bytes
		delete_key(&part.members, id)
		delete_key(&part.field_limits, id)
		if len(part.field_limits) == 0 {
			delete(part.field_limits)
			part.field_limits = nil
		} else if len(part.field_limits) * 4 < cap(part.field_limits) {
			shrink(&part.field_limits)
		}
	}
}

search_document_charge :: proc(part: ^Search_Partition, id: u32, bytes: Search_Bytes) {
	part.members[id] = bytes
	part.content += bytes
}

@(private = "file")
search_error_bytes :: proc "contextless" (err: fi.Field_Errors) -> int {
	return 2 * (len(err.last_key) + len(err.last_error))
}

search_part_charge_bytes :: proc(part: ^Search_Partition, vector_fields: []int = nil) -> Search_Bytes {
	bytes := part.base + part.content
	if docs := dt.count(&part.data.docs); docs > 0 {
		bytes[.Documents] += ((docs + dt.PAGE_SIZE - 1) / dt.PAGE_SIZE) * (48 << 10)
	}
	bytes[.Overhead] += search_error_bytes(part.data.errors)
	for &slot, i in part.data.slots {
		bytes[.Overhead] += search_error_bytes(slot.errors)
		if slot.vector != nil {
			base, rows := search_vector_bytes(part, i)
			bytes[.Vector] += rows
			if vector_fields != nil {
				vector_fields[i] += base + rows
			}
		}
	}
	return bytes
}

search_definition_admit :: proc(scope: ow.Scope, bytes: int) -> string {
	if !labels_on || aof.loading || pst.loading {
		return ""
	}
	if scope.owner != ow.SHARED {
		e := owner_entry(scope.owner)
		if e == nil {
			return ERR_OWNER_INVALID
		}
		limit := owner_quota_of(e)
		if limit <= 0 {
			return ""
		}
		room := limit - i64(bytes)
		if room < 0 {
			return ERR_OWNER_QUOTA_OOM
		}
		if i64(owner_used_live(e)) > room {
			retained := owner_quota_expire(e, nil)
			evict_in_owner(e, room, retained)
			if i64(owner_used_live(e)) - retained > room {
				return ERR_OWNER_QUOTA_OOM
			}
		}
		return ""
	}
	limit, found := label_quotas[scope.label]
	if !found {
		return ""
	}
	room := limit - bytes
	if room < 0 {
		return ERR_LABEL_QUOTA_OOM
	}
	if label_used(scope.label) > room {
		label_quota_expire(scope.label)
		evict_in_label(scope.label, room)
		if label_used(scope.label) > room {
			return ERR_LABEL_QUOTA_OOM
		}
	}
	return ""
}
