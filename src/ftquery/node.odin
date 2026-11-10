package ftquery

import "core:mem"

Node_Id :: distinct i32

NO_NODE :: Node_Id(-1)

Field_Mask :: distinct u128

ALL_FIELDS :: ~Field_Mask(0)

Node_Kind :: enum u8 {
	Null,
	Token,
	Phrase,
	Union,
	Intersect,
	Not,
	Optional,
	Prefix,
	Suffix,
	Infix,
	Wildcard_Pattern,
	Fuzzy,
	Numeric,
	Geo,
	Tag,
	Wildcard,
	Missing,
	Vector,
	Geoshape,
}

Unit :: enum u8 {
	M,
	Km,
	Mi,
	Ft,
}

UNIT_NAMES := [Unit]string {
	.M  = "m",
	.Km = "km",
	.Mi = "mi",
	.Ft = "ft",
}

Vector_Kind :: enum u8 {
	Knn,
	Range,
}

Vector_Attribute :: struct {
	name:  string,
	value: string,
}

Vector_Query :: struct {
	kind:        Vector_Kind,
	field:       int,
	k:           u64,
	radius:      f64,
	blob_param:  string,
	blob:        string,
	score_alias: string,
	attributes:  [dynamic]Vector_Attribute,
}

Node :: struct {
	kind:      Node_Kind,
	mask:      Field_Mask,
	children:  [dynamic]Node_Id,
	text:      string,
	expanded:  bool,
	verbatim:  bool,
	distance:  int,
	predicate: int,
	field:     int,
	min:       f64,
	max:       f64,
	min_open:  bool,
	max_open:  bool,
	lon:       f64,
	lat:       f64,
	radius:    f64,
	unit:      Unit,
	weight:    f64,
	slop:      int,
	in_order:  bool,
	phonetic:  int,
	has_attrs: bool,
	vector:    ^Vector_Query,
	pos:       int,
	param:     string,
	param_pos: int,
	params:    [4]string,
	checked:   bool,
	number:    bool,
}

Query :: struct {
	nodes:     [dynamic]Node,
	root:      Node_Id,
	dialect:   int,
	allocator: mem.Allocator,
}

node_get :: #force_inline proc(q: ^Query, id: Node_Id) -> ^Node {
	return &q.nodes[int(id)]
}

node_new :: proc(q: ^Query, kind: Node_Kind) -> Node_Id {
	n := Node {
		kind     = kind,
		mask     = ALL_FIELDS,
		weight   = 1,
		slop     = -1,
		field    = -1,
		phonetic = 0,
		children = make([dynamic]Node_Id, q.allocator),
	}
	append(&q.nodes, n)
	return Node_Id(len(q.nodes) - 1)
}

node_add_child :: proc(q: ^Query, parent, child: Node_Id) {
	append(&node_get(q, parent).children, child)
}

node_is_null :: proc(q: ^Query, id: Node_Id) -> bool {
	return id == NO_NODE || node_get(q, id).kind == .Null
}

make_null :: proc(q: ^Query) -> Node_Id {
	return node_new(q, .Null)
}

make_and :: proc(q: ^Query, left, right: Node_Id) -> Node_Id {
	if node_is_null(q, left) {
		return right
	}
	if node_is_null(q, right) {
		return left
	}
	l := node_get(q, left)
	if l.kind == .Intersect && l.mask == ALL_FIELDS {
		node_add_child(q, left, right)
		return left
	}
	if q.dialect >= 2 {
		r := node_get(q, right)
		if r.kind == .Intersect && r.mask == ALL_FIELDS {
			node_add_child(q, right, left)
			return right
		}
	}
	id := node_new(q, .Intersect)
	node_add_child(q, id, left)
	node_add_child(q, id, right)
	return id
}

make_or :: proc(q: ^Query, left, right: Node_Id) -> Node_Id {
	if node_is_null(q, left) {
		return right
	}
	if node_is_null(q, right) {
		return left
	}
	l := node_get(q, left)
	if l.kind == .Union && l.mask == ALL_FIELDS {
		node_add_child(q, left, right)
		return left
	}
	if q.dialect >= 2 {
		r := node_get(q, right)
		if r.kind == .Union && r.mask == ALL_FIELDS {
			node_add_child(q, right, left)
			return right
		}
	}
	id := node_new(q, .Union)
	node_add_child(q, id, left)
	node_add_child(q, id, right)
	return id
}

make_not :: proc(q: ^Query, child: Node_Id, pos: int) -> Node_Id {
	if node_is_null(q, child) {
		return child
	}
	c := node_get(q, child)
	if c.kind == .Not && len(c.children) == 1 {
		return c.children[0]
	}
	id := node_new(q, .Not)
	node_get(q, id).pos = pos
	node_add_child(q, id, child)
	return id
}

make_optional :: proc(q: ^Query, child: Node_Id, pos: int) -> Node_Id {
	if node_is_null(q, child) {
		return child
	}
	id := node_new(q, .Optional)
	node_get(q, id).pos = pos
	node_add_child(q, id, child)
	return id
}

make_leaf :: proc(q: ^Query, kind: Node_Kind, text: string, pos: int) -> Node_Id {
	id := node_new(q, kind)
	n := node_get(q, id)
	n.text = text
	n.pos = pos
	return id
}

apply_mask :: proc(q: ^Query, id: Node_Id, mask: Field_Mask) {
	if id == NO_NODE {
		return
	}
	n := node_get(q, id)
	n.mask &= mask
	for child in n.children {
		apply_mask(q, child, mask)
	}
}
