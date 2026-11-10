package ftindex

Gc_Probe :: struct {
	file:  string,
	stage: string,
	query: string,
	total: int,
	keys:  []string,
	scores: []string,
}

@(rodata)
GC_PROBES := [?]Gc_Probe {
	{file = "probe1.json", stage = "initial", query = "same", total = 5, keys = {"gc:1", "gc:2", "gc:3", "gc:4", "gc:5"}, scores = {"0.2294298484458195", "0.2294298484458195", "0.2294298484458195", "0.2294298484458195", "0.2294298484458195"}},
	{file = "probe1.json", stage = "initial", query = "@g:{x}", total = 3, keys = {"gc:1", "gc:3", "gc:5"}, scores = {"0.6594265063316499", "0.6594265063316499", "0.6594265063316499"}},
	{file = "probe1.json", stage = "initial", query = "same @g:{x}", total = 3, keys = {"gc:1", "gc:3", "gc:5"}, scores = {"0.8888563547774694", "0.8888563547774694", "0.8888563547774694"}},
	{file = "probe1.json", stage = "initial", query = "*", total = 6, keys = {"gc:6", "gc:1", "gc:2", "gc:3", "gc:4", "gc:5"}, scores = {"1.3435114587175074", "0.951351350515406", "0.951351350515406", "0.951351350515406", "0.951351350515406", "0.951351350515406"}},
	{file = "probe1.json", stage = "after rewriting gc:1", query = "same", total = 5, keys = {"gc:2", "gc:3", "gc:4", "gc:5", "gc:1"}, scores = {"0.07236653152409452", "0.07236653152409452", "0.07236653152409452", "0.07236653152409452", "0.06342421398929318"}},
	{file = "probe1.json", stage = "after rewriting gc:1", query = "@g:{x}", total = 3, keys = {"gc:3", "gc:5", "gc:1"}, scores = {"0.43145025922251945", "0.43145025922251945", "0.37813603872328855"}},
	{file = "probe1.json", stage = "after rewriting gc:1", query = "same @g:{x}", total = 3, keys = {"gc:3", "gc:5", "gc:1"}, scores = {"0.503816790746614", "0.503816790746614", "0.4415602527125817"}},
	{file = "probe1.json", stage = "after rewriting gc:1", query = "*", total = 6, keys = {"gc:6", "gc:2", "gc:3", "gc:4", "gc:5", "gc:1"}, scores = {"1.3600000088431619", "0.9765013050685688", "0.9765013050685688", "0.9765013050685688", "0.9765013050685688", "0.8558352380460852"}},
	{file = "probe1.json", stage = "after DEL gc:2 and gc:6", query = "same", total = 4, keys = {"gc:3", "gc:4", "gc:5", "gc:1"}, scores = {"0.07651581244910725", "0.07651581244910725", "0.07651581244910725", "0.06771527157489278"}},
	{file = "probe1.json", stage = "after DEL gc:2 and gc:6", query = "@g:{x}", total = 3, keys = {"gc:3", "gc:5", "gc:1"}, scores = {"0.10878378157336471", "0.10878378157336471", "0.09627190872584343"}},
	{file = "probe1.json", stage = "after DEL gc:2 and gc:6", query = "same @g:{x}", total = 3, keys = {"gc:3", "gc:5", "gc:1"}, scores = {"0.18529959402247198", "0.18529959402247198", "0.16398718030073622"}},
	{file = "probe1.json", stage = "after DEL gc:2 and gc:6", query = "*", total = 4, keys = {"gc:3", "gc:4", "gc:5", "gc:1"}, scores = {"1.0324909753351617", "1.0324909753351617", "1.0324909753351617", "0.9137380177456658"}},
	{file = "probe1.json", stage = "after garbage collection", query = "same", total = 4, keys = {"gc:3", "gc:4", "gc:5", "gc:1"}, scores = {"0.07651581244910725", "0.07651581244910725", "0.07651581244910725", "0.06771527157489278"}},
	{file = "probe1.json", stage = "after garbage collection", query = "@g:{x}", total = 3, keys = {"gc:3", "gc:5", "gc:1"}, scores = {"0.10878378157336471", "0.10878378157336471", "0.09627190872584343"}},
	{file = "probe1.json", stage = "after garbage collection", query = "same @g:{x}", total = 3, keys = {"gc:3", "gc:5", "gc:1"}, scores = {"0.18529959402247198", "0.18529959402247198", "0.16398718030073622"}},
	{file = "probe1.json", stage = "after garbage collection", query = "*", total = 4, keys = {"gc:3", "gc:4", "gc:5", "gc:1"}, scores = {"1.0324909753351617", "1.0324909753351617", "1.0324909753351617", "0.9137380177456658"}},
	{file = "probe1.json", stage = "after a second garbage collection", query = "same", total = 4, keys = {"gc:3", "gc:4", "gc:5", "gc:1"}, scores = {"0.07651581244910725", "0.07651581244910725", "0.07651581244910725", "0.06771527157489278"}},
	{file = "probe1.json", stage = "after a second garbage collection", query = "@g:{x}", total = 3, keys = {"gc:3", "gc:5", "gc:1"}, scores = {"0.10878378157336471", "0.10878378157336471", "0.09627190872584343"}},
	{file = "probe1.json", stage = "after a second garbage collection", query = "same @g:{x}", total = 3, keys = {"gc:3", "gc:5", "gc:1"}, scores = {"0.18529959402247198", "0.18529959402247198", "0.16398718030073622"}},
	{file = "probe1.json", stage = "after a second garbage collection", query = "*", total = 4, keys = {"gc:3", "gc:4", "gc:5", "gc:1"}, scores = {"1.0324909753351617", "1.0324909753351617", "1.0324909753351617", "0.9137380177456658"}},
	{file = "probe2.json", stage = "before collection", query = "same", total = 4, keys = {"gc:3", "gc:4", "gc:5", "gc:1"}, scores = {"0.07651581244910725", "0.07651581244910725", "0.07651581244910725", "0.06771527157489278"}},
	{file = "probe2.json", stage = "before collection", query = "@g:{x}", total = 3, keys = {"gc:3", "gc:5", "gc:1"}, scores = {"0.10878378157336471", "0.10878378157336471", "0.09627190872584343"}},
	{file = "probe2.json", stage = "after collection", query = "same", total = 4, keys = {"gc:3", "gc:4", "gc:5", "gc:1"}, scores = {"0.10878378157336471", "0.10878378157336471", "0.10878378157336471", "0.09627190872584343"}},
	{file = "probe2.json", stage = "after collection", query = "@g:{x}", total = 3, keys = {"gc:3", "gc:5", "gc:1"}, scores = {"0.36826366074491595", "0.36826366074491595", "0.3259074562541238"}},
	{file = "probe2.json", stage = "after collection", query = "lonely", total = 0, keys = {}, scores = {}},
}
