package main

import "base:runtime"
import "base:intrinsics"
import "hll"
import "core:math"
import "core:slice"
import "core:strings"
import fi "ftindex"

FT_Reducer_Kind :: enum {
	Unknown,
	Count, Sum, Avg, Min, Max, Count_Distinct, Count_Distinctish, To_List,
	First_Value, Stddev, Quantile, Random_Sample, Collect,
}

FT_REDUCERS := #partial [FT_Reducer_Kind]string {
	.Count = "COUNT",
	.Sum = "SUM",
	.Avg = "AVG",
	.Min = "MIN",
	.Max = "MAX",
	.Count_Distinct = "COUNT_DISTINCT",
	.Count_Distinctish = "COUNT_DISTINCTISH",
	.To_List = "TOLIST",
	.First_Value = "FIRST_VALUE",
	.Stddev = "STDDEV",
	.Quantile = "QUANTILE",
	.Random_Sample = "RANDOM_SAMPLE",
	.Collect = "COLLECT",
}

FT_Reducer :: struct {
	kind: FT_Reducer_Kind,
	name: string,
	property: string,
	order: []FT_Order,
	fraction: f64,
	size: int,
	fields: []string,
	all, unique: bool,
	offset, count: int,
}

FT_Object :: distinct []FT_Cell

ft_reducer_parse :: proc(args: [][]u8, at: ^int) -> (FT_Reducer, string) {
	if at^ == len(args) {
		return {}, ft_argument_error("REDUCE", SEARCH_MISSING_ARGUMENT)
	}
	original := ft_token(args[at^])
	name := strings.to_upper(original, context.temp_allocator)
	at^ += 1
	r: FT_Reducer
	for kind in FT_Reducer_Kind {
		if name == FT_REDUCERS[kind] {
			r.kind = kind
			break
		}
	}
	params, err := search_counted_args(args, at, "REDUCE", context.temp_allocator)
	if err != "" {
		return {}, err
	}
	if r.kind == .Unknown {
		return {}, ft_error("SEARCH_REDUCER_NOT_FOUND No such reducer: ", original)
	}
	if at^ + 1 < len(args) && eq_nocase(args[at^], "as") {
		r.name = ft_token(args[at^+1])
		at^ += 2
	} else {
		key := make([dynamic]u8, context.temp_allocator)
		append(&key, "__generated_alias")
		append(&key, ..transmute([]u8)strings.to_lower(name, context.temp_allocator))
		for arg, i in params {
			if i != 0 {
				append(&key, ',')
			}
			lower := strings.to_lower(ft_property(ft_token(arg)), context.temp_allocator)
			append(&key, ..transmute([]u8)lower)
		}
		r.name = string(key[:])
	}
	if r.kind == .Count {
		if len(params) != 0 {
			return {}, "SEARCH_ATTR_BAD Count accepts 0 values only"
		}
		return r, ""
	}
	if r.kind == .Collect {
		collect_error := ft_collect_parse(&r, params)
		return r, collect_error
	}
	if len(params) == 0 {
		return {}, ft_error("SEARCH_PARSE_ARGS Missing arguments for ", name)
	}
	r.property = ft_property(ft_token(params[0]))
	#partial switch r.kind {
	case .First_Value:
		if len(params) == 1 {
			break
		}
		if !eq_nocase(params[1], "by") {
			return {}, ft_error("SEARCH_ARG_UNRECOGNIZED Unknown argument `", ft_token(params[1]), "` at position 1 for FIRST_VALUE")
		}
		if len(params) < 3 {
			return {}, "SEARCH_PARSE_ARGS Missing arguments for FIRST_VALUE"
		}
		field := FT_Order{name = ft_property(ft_token(params[2]))}
		if len(params) >= 4 {
			field.desc = eq_nocase(params[3], "desc")
			if !field.desc && !eq_nocase(params[3], "asc") {
				return {}, ft_error("SEARCH_ARG_UNRECOGNIZED Unknown argument `", ft_token(params[3]), "` at position 3 for FIRST_VALUE")
			}
		}
		r.order = make([]FT_Order, 1, context.temp_allocator)
		r.order[0] = field
	case .Quantile:
		if len(params) < 2 {
			return {}, "SEARCH_PARSE_ARGS Missing arguments for QUANTILE"
		}
		value, ok := fi.number_parse(ft_token(params[1]))
		if !ok || !(value >= 0 && value <= 1) {
			return {}, "SEARCH_PARSE_ARGS Percentage must be between 0.0 and 1.0"
		}
		r.fraction = value
	case .Random_Sample:
		if len(params) < 2 {
			return {}, "SEARCH_PARSE_ARGS Missing arguments for RANDOM_SAMPLE"
		}
		value, ok := search_number(params[1])
		if !ok || value <= 0 || value > FT_AGGREGATE_LIMIT {
			return {}, "SEARCH_PARSE_ARGS Invalid RANDOM_SAMPLE size"
		}
		r.size = int(value)
	case:
	}
	return r, ""
}

ft_collect_parse :: proc(r: ^FT_Reducer, args: [][]u8) -> string {
	if len(args) < 2 || !eq_nocase(args[0], "fields") {
		return "SEARCH_PARSE_ARGS COLLECT requires FIELDS"
	}
	r.count = FT_AGGREGATE_LIMIT
	at := 1
	if ft_token(args[at]) == "*" {
		r.all = true
		at += 1
	} else {
		fields, err := search_counted_args(args, &at, "FIELDS", context.temp_allocator)
		if err != "" {
			return err
		}
		r.all = len(fields) == 1 && ft_token(fields[0]) == "*"
		if !r.all {
			r.fields = make([]string, len(fields), context.temp_allocator)
			for field, i in fields {
				r.fields[i] = ft_property(ft_token(field))
			}
		}
	}
	for at < len(args) {
		token := args[at]
		at += 1
		switch {
		case eq_nocase(token, "distinct"):
			r.unique = true
		case eq_nocase(token, "sortby"):
			tokens, err := search_counted_args(args, &at, "SORTBY", context.temp_allocator)
			if err != "" {
				return err
			}
			if r.order, err = ft_sort_fields(tokens); err != "" {
				return err
			}
		case eq_nocase(token, "limit"):
			offset, count, err := ft_aggregate_limit(args[at:], false)
			if err != "" {
				return err
			}
			r.offset, r.count = offset, count
			at += 2
		case:
			return ft_unknown_argument(args, at - 1, "COLLECT")
		}
	}
	return ""
}

ft_group_value_key :: proc(buf: ^[dynamic]u8, val: FT_Value) {
	switch v in val {
	case i64:
		bits := transmute([8]u8)v
		append(buf, 5)
		append(buf, ..bits[:])
		return
	case FT_Json_Double:
		ft_group_value_key(buf, f64(v))
		return
	case f64:
		x := v
		if x == 0 { x = 0 }
		if math.is_nan(x) { x = math.nan_f64() }
		bits := transmute([8]u8)x
		append(buf, 1)
		append(buf, ..bits[:])
		return
	case string:
		n := transmute([8]u8)u64(len(v))
		append(buf, 2)
		append(buf, ..n[:])
		append(buf, ..transmute([]u8)v)
		return
	case []FT_Value:
		n := transmute([8]u8)u64(len(v))
		append(buf, 3)
		append(buf, ..n[:])
		for item in v {
			ft_group_value_key(buf, item)
		}
		return
	case FT_Object:
		n := transmute([8]u8)u64(len(v))
		append(buf, 4)
		append(buf, ..n[:])
		for field in v {
			ft_group_value_key(buf, field.name)
			ft_group_value_key(buf, field.value)
		}
		return
	}
	append(buf, 0)
}

FT_Reduction :: struct {
	count: int,
	sum, mean, m2: f64,
	value, sort: FT_Value,
	seen: map[string]bool,
	values: [dynamic]FT_Value,
	samples: [dynamic]f64,
	collect: [dynamic]FT_Row,
	random: u64,
	approx: ^[1024]u8,
}

ft_reduce_add :: proc(r: ^FT_Reducer, state: ^FT_Reduction, row: ^FT_Row) {
	if r.kind == .Count {
		state.count += 1
		return
	}
	if r.kind == .Collect {
		if state.collect == nil {
			state.collect = make([dynamic]FT_Row, context.temp_allocator)
		}
		append(&state.collect, row^)
		return
	}
	value, _ := ft_cell_get(row.cells[:], r.property)
	if value == nil {
		return
	}
	if r.kind == .First_Value {
		best: FT_Value
		better := state.count == 0
		if len(r.order) != 0 {
			best, _ = ft_cell_get(row.cells[:], r.order[0].name)
			if best != nil && state.sort == nil {
				better = true
			} else if best != nil {
				cmp := ft_compare(best, state.sort)
				better = cmp > 0 if r.order[0].desc else cmp < 0
			}
		}
		if better {
			state.value, state.sort = value, best
		}
		state.count += 1
		return
	}
	if values, array := value.([]FT_Value); array {
		for item in values {
			if item != nil { ft_reduce_value(r, state, item) }
		}
	} else {
		ft_reduce_value(r, state, value)
	}
}

ft_reduce_value :: proc(r: ^FT_Reducer, state: ^FT_Reduction, value: FT_Value) {
	#partial switch r.kind {
	case .Count_Distinct, .To_List:
		if state.seen == nil {
			state.seen = make(map[string]bool, context.temp_allocator)
		}
		key := make([dynamic]u8, context.temp_allocator)
		ft_group_value_key(&key, value)
		if !state.seen[string(key[:])] {
			state.seen[string(key[:])] = true
			if r.kind == .To_List {
				if state.values == nil {
					state.values = make([dynamic]FT_Value, context.temp_allocator)
				}
				append(&state.values, value)
			}
		} else {
			delete(key)
		}
	case .Count_Distinctish:
		if state.approx == nil {
			state.approx = new([1024]u8, context.temp_allocator)
		}
		key := make([dynamic]u8, context.temp_allocator)
		ft_group_value_key(&key, value)
		hash := hll.murmurhash64a(key[:], hll.HLL_HASH_SEED)
		register := int(hash & 1023)
		rank := u8(intrinsics.count_trailing_zeros((hash >> 10) | (u64(1) << 54)) + 1)
		state.approx[register] = max(state.approx[register], rank)
		delete(key)
	case .Random_Sample:
		state.count += 1
		if state.values == nil {
			state.values = make([dynamic]FT_Value, context.temp_allocator)
			seed: [8]u8
			runtime.rand_bytes(seed[:])
			state.random = transmute(u64)seed | 1
		}
		if len(state.values) < r.size {
			append(&state.values, value)
		} else {
			x := state.random
			x ~= x << 13
			x ~= x >> 7
			x ~= x << 17
			state.random = x
			at := int(x % u64(state.count))
			if at < r.size {
				state.values[at] = value
			}
		}
	case .Sum, .Avg, .Min, .Max, .Stddev, .Quantile:
		n, ok := ft_number(value)
		if !ok || math.is_nan(n) {
			return
		}
		state.count += 1
		#partial switch r.kind {
		case .Sum, .Avg:
			state.sum += n
		case .Min, .Max:
			if current, live := state.value.(f64); !live || (n < current if r.kind == .Min else n > current) {
				state.value = n
			}
		case .Stddev:
			delta := n - state.mean
			state.mean += delta / f64(state.count)
			state.m2 += delta * (n - state.mean)
		case .Quantile:
			if state.samples == nil {
				state.samples = make([dynamic]f64, context.temp_allocator)
			}
			append(&state.samples, n)
		case:
		}
	case:
	}
}

ft_reduce_finish :: proc(r: ^FT_Reducer, state: ^FT_Reduction) -> FT_Value {
	switch r.kind {
	case .Unknown: return nil
	case .Count: return f64(state.count)
	case .Sum: return state.sum
	case .Avg:
		return (state.sum / f64(state.count)) if state.count != 0 else math.nan_f64()
	case .Min, .Max:
		if state.value != nil { return state.value }
		return math.inf_f64(1 if r.kind == .Min else -1)
	case .Count_Distinct: return f64(len(state.seen))
	case .Count_Distinctish: return ft_approx_distinct(state.approx)
	case .To_List, .Random_Sample: return state.values[:]
	case .First_Value: return state.value
	case .Stddev:
		return math.sqrt(state.m2 / f64(state.count - 1)) if state.count > 1 else f64(0)
	case .Quantile:
		if len(state.samples) == 0 { return math.nan_f64() }
		slice.sort(state.samples[:])
		return state.samples[clamp(int(math.ceil(r.fraction * f64(len(state.samples)))) - 1, 0, len(state.samples)-1)]
	case .Collect: return ft_collect_finish(r, state.collect[:])
	}
	return nil
}

ft_approx_distinct :: proc(registers: ^[1024]u8) -> f64 {
	if registers == nil {
		return 0
	}
	empty := 0
	sum := 0.0
	for rank in registers^ {
		empty += int(rank == 0)
		sum += 1.0 / f64(u64(1) << rank)
	}
	m := f64(len(registers^))
	estimate := (0.7213 / (1 + 1.079 / m)) * m * m / sum
	if estimate <= 2.5 * m && empty > 0 {
		estimate = m * math.ln(m / f64(empty))
	}
	return math.round(estimate)
}
