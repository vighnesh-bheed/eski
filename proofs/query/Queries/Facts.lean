import Queries.Parser

namespace Queries

theorem minus_groups_one : parseQuery 1 [45, 120, 32, 121] = .tree (.neg (.inter [.tok [120], .tok [121]])) := by rfl

theorem minus_binds_term_two : parseQuery 2 [45, 120, 32, 121] = .tree (.inter [.neg (.tok [120]), .tok [121]]) := by rfl

theorem tilde_groups_one : parseQuery 1 [126, 120, 32, 121] = .tree (.opt (.inter [.tok [120], .tok [121]])) := by rfl

theorem tilde_binds_term_two : parseQuery 2 [126, 120, 32, 121] = .tree (.inter [.opt (.tok [120]), .tok [121]]) := by rfl

theorem or_below_and_one : parseQuery 1 [120, 32, 124, 32, 121, 32, 122] = .tree (.union [.tok [120], .inter [.tok [121], .tok [122]]]) := by rfl

theorem or_below_and_two : parseQuery 2 [120, 32, 124, 32, 121, 32, 122] = .tree (.union [.tok [120], .inter [.tok [121], .tok [122]]]) := by rfl

theorem or_chain_flat_one : parseQuery 1 [120, 32, 124, 32, 121, 32, 124, 32, 122] = .tree (.union [.tok [120], .tok [121], .tok [122]]) := by rfl

theorem or_chain_flat_two : parseQuery 2 [120, 32, 124, 32, 121, 32, 124, 32, 122] = .tree (.union [.tok [120], .tok [121], .tok [122]]) := by rfl

theorem group_nested_one : parseQuery 1 [120, 32, 40, 121, 32, 122, 41] = .tree (.inter [.tok [120], .inter [.tok [121], .tok [122]]]) := by rfl

theorem group_merged_two : parseQuery 2 [120, 32, 40, 121, 32, 122, 41] = .tree (.inter [.tok [121], .tok [122], .tok [120]]) := by rfl

theorem prefix_inside_negation_two : parseQuery 2 [45, 120, 32, 121, 42] = .tree (.neg (.inter [.tok [120], .pre [121]])) := by rfl

theorem stop_word_empty : parseQuery 2 [116, 104, 101] = .tree .null := by rfl

theorem stop_word_dropped_one : parseQuery 1 [120, 32, 116, 104, 101, 32, 121] = .tree (.inter [.tok [120], .tok [121]]) := by rfl

theorem stop_word_dropped_two : parseQuery 2 [120, 32, 116, 104, 101, 32, 121] = .tree (.inter [.tok [120], .tok [121]]) := by rfl

theorem double_negation : parseQuery 2 [45, 45, 120] = .tree (.tok [120]) := by rfl

theorem negated_group : parseQuery 2 [120, 32, 45, 40, 121, 32, 124, 32, 122, 41] = .tree (.inter [.tok [120], .neg (.union [.tok [121], .tok [122]])]) := by rfl

theorem patterns_merge_two : parseQuery 2 [42, 120, 121, 42, 32, 42, 122, 32, 113, 42] = .tree (.inter [.suf [122], .pre [113], .inf [120, 121]]) := by rfl

theorem patterns_append_one : parseQuery 1 [42, 120, 121, 42, 32, 42, 122, 32, 113, 42] = .tree (.inter [.inf [120, 121], .suf [122], .pre [113]]) := by rfl

theorem empty_query : parseQuery 1 [] = .tree .null := by rfl

theorem open_group_error : parseQuery 1 [40, 120] = .failure ⟨1, [120]⟩ := by rfl

theorem close_group_error : parseQuery 2 [120, 32, 41] = .failure ⟨2, [120]⟩ := by rfl

theorem dangling_or_error : parseQuery 1 [120, 32, 124] = .failure ⟨2, [120]⟩ := by rfl

theorem bare_star_unsupported : parseQuery 2 [42] = .unsupported := by rfl

end Queries
