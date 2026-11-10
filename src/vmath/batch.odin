package vmath

PREFETCH_WINDOW :: #config(VMATH_PREFETCH_WINDOW, 16384)
PREFETCH_AHEAD_MIN :: #config(VMATH_PREFETCH_AHEAD_MIN, 4)
PREFETCH_AHEAD_MAX :: #config(VMATH_PREFETCH_AHEAD_MAX, 16)
PREFETCH_BYTES :: #config(VMATH_PREFETCH_BYTES, 1024)

prefetch_ahead :: #force_inline proc "contextless" (a: ^Arena) -> int {
	return clamp(PREFETCH_WINDOW / max(a.stride, 1), PREFETCH_AHEAD_MIN, PREFETCH_AHEAD_MAX)
}

batch_of :: proc "contextless" ($kernel: Distance_Proc) -> Batch_Proc {
	return proc "contextless" (a: ^Arena, q: ^Query, slots: []u32, out: []f32) {
		#no_bounds_check {
			n := min(len(slots), len(out))
			ahead := prefetch_ahead(a)
			for i in 0 ..< min(n, ahead) {
				arena_prefetch(a, slots[i])
			}
			data := q.data
			aux := q.aux
			dim := a.dim
			for i in 0 ..< n {
				if i + ahead < n {
					arena_prefetch(a, slots[i + ahead])
				}
				s := slots[i]
				out[i] = kernel(data, aux, a.vectors[int(s) * a.stride:], arena_aux(a, s), dim)
			}
		}
	}
}

put :: #force_inline proc "contextless" (k: ^Kernel_Set, family: Family, elem: Elem, metric: Metric, $kernel: Distance_Proc) {
	k[family].distance[elem][metric] = kernel
	k[family].batch[elem][metric] = batch_of(kernel)
}

batch_kernels :: proc "contextless" (k: ^Kernel_Set) {
	put(k, .Vector_Set, .F32, .Cosine, distance_f32_base)
	put(k, .Vector_Set, .Int8, .Cosine, distance_i8_base)
	put(k, .Vector_Set, .Bin, .Cosine, distance_bin_base)
	put(k, .Search, .F32, .L2, qe_f32_l2)
	put(k, .Search, .F32, .IP, qe_f32_ip)
	put(k, .Search, .F32, .Cosine, qe_f32_ip)
	put(k, .Search, .F16, .L2, qe_f16_l2)
	put(k, .Search, .F16, .IP, qe_f16_ip)
	put(k, .Search, .F16, .Cosine, qe_f16_ip)
	put(k, .Search, .BF16, .L2, qe_bf16_l2)
	put(k, .Search, .BF16, .IP, qe_bf16_ip)
	put(k, .Search, .BF16, .Cosine, qe_bf16_ip)
	put(k, .Search, .F64, .L2, qe_f64_l2)
	put(k, .Search, .F64, .IP, qe_f64_ip)
	put(k, .Search, .F64, .Cosine, qe_f64_ip)
	put(k, .Search, .Int8, .L2, qe_i8_l2)
	put(k, .Search, .Int8, .IP, qe_i8_ip)
	put(k, .Search, .Int8, .Cosine, qe_i8_cosine)
	put(k, .Search, .U8, .L2, qe_u8_l2)
	put(k, .Search, .U8, .IP, qe_u8_ip)
	put(k, .Search, .U8, .Cosine, qe_u8_cosine)
}

Arena_Query :: struct {
	arena: ^Arena,
	query: Query,
}

arena_query_hook :: proc(qctx: rawptr, slot: u32) -> f32 {
	c := (^Arena_Query)(qctx)
	return arena_query_distance(c.arena, c.query, slot)
}

arena_batch_hook :: proc(qctx: rawptr, slots: []u32, out: []f32) {
	c := (^Arena_Query)(qctx)
	arena_query_distances(c.arena, &c.query, slots, out)
}

arena_prefetch_hook :: proc(ctx: rawptr, slot: u32) {
	arena_prefetch((^Arena)(ctx), slot)
}
