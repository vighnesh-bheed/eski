package label

import "core:fmt"
import "core:testing"

@(test)
names_are_canonicalised_and_validated :: proc(t: ^testing.T) {
	c: Config
	config_init(&c)
	defer config_destroy(&c)
	testing.expect_value(t, config_add_level(&c, "  unclassified "), Config_Error.None)
	testing.expect_value(t, config_add_level(&c, "Top \t  Secret"), Config_Error.None)
	testing.expect_value(t, config_level_name(&c, 0), "UNCLASSIFIED")
	testing.expect_value(t, config_level_name(&c, 1), "TOP SECRET")
	testing.expect_value(t, config_add_level(&c, "TOP SECRET"), Config_Error.Duplicate_Name)
	testing.expect_value(t, config_add_compartment(&c, "top secret"), Config_Error.Duplicate_Name)
	testing.expect_value(t, config_add_compartment(&c, "SI-G"), Config_Error.None)
	testing.expect_value(t, config_add_compartment(&c, "hcs_p"), Config_Error.None)
	testing.expect_value(t, config_compartment_name(&c, 1), "HCS_P")
	testing.expect_value(t, config_add_level(&c, ""), Config_Error.Empty_Name)
	testing.expect_value(t, config_add_level(&c, " \t "), Config_Error.Empty_Name)
	testing.expect_value(t, config_add_compartment(&c, "A/B"), Config_Error.Invalid_Name)
	testing.expect_value(t, config_add_compartment(&c, "CAFÉ"), Config_Error.Invalid_Name)
	testing.expect_value(t, config_add_compartment(&c, "A.B"), Config_Error.Invalid_Name)
	testing.expect_value(t, config_add_compartment(&c, "A\nB"), Config_Error.Invalid_Name)
	testing.expect_value(t, config_add_compartment(&c, "-"), Config_Error.Invalid_Name)
	testing.expect_value(t, config_add_compartment(&c, "_x"), Config_Error.Invalid_Name)
	testing.expect_value(t, config_add_compartment(&c, "A -B"), Config_Error.Invalid_Name)
	testing.expect(t, name_canonical("9X") && name_canonical("SI-G") && name_canonical("A B_C"))
	testing.expect(t, !name_canonical("A  B") && !name_canonical(" A") && !name_canonical("A ") && !name_canonical("a"))
	LONG :: "ABCDEFGHIJABCDEFGHIJABCDEFGHIJABCDEFGHIJABCDEFGHIJABCDEFGHIJABCD"
	testing.expect_value(t, len(LONG), NAME_MAX)
	testing.expect_value(t, config_add_compartment(&c, LONG), Config_Error.None)
	testing.expect_value(t, config_add_compartment(&c, "X" + LONG), Config_Error.Name_Too_Long)
	testing.expect_value(t, config_add_compartment(&c, "A                CDEFGHIJABCDEFGHIJABCDEFGHIJABCDEFGHIJABCDEFGHIJABCDEFGHIJABCD"), Config_Error.None)
	testing.expect_value(t, config_compartment_name(&c, 3), "A CDEFGHIJABCDEFGHIJABCDEFGHIJABCDEFGHIJABCDEFGHIJABCDEFGHIJABCD")
	testing.expect_value(t, config_level_count(&c), 2)
	testing.expect_value(t, config_compartment_count(&c), 4)
	_, found := config_find_level(&c, "top   SECRET ")
	testing.expect(t, found)
	_, found = config_find_level(&c, "TOPSECRET")
	testing.expect(t, !found)
	testing.expect_value(t, config_level_name(&c, 7), "")
	testing.expect_value(t, config_compartment_name(&c, -1), "")
}

@(test)
configuration_limits_are_enforced :: proc(t: ^testing.T) {
	c: Config
	wide_config(t, &c, LEVEL_LIMIT, COMPARTMENT_LIMIT)
	defer config_destroy(&c)
	testing.expect_value(t, config_add_level(&c, "ONE MORE"), Config_Error.Too_Many_Levels)
	testing.expect_value(t, config_add_compartment(&c, "ONE MORE"), Config_Error.Too_Many_Compartments)
	testing.expect_value(t, config_add_level(&c, "L0"), Config_Error.Too_Many_Levels)
	top, ok := config_top(&c)
	testing.expect(t, ok && int(top.level) == LEVEL_LIMIT - 1 && compartment_count(top) == COMPARTMENT_LIMIT)
	testing.expect(t, config_valid(&c, top))
	for i in 0 ..< COMPARTMENT_LIMIT {
		testing.expect_value(t, config_compartment_name(&c, i), fmt.tprintf("C%d", i))
	}
}

@(test)
default_configuration_has_one_level :: proc(t: ^testing.T) {
	c: Config
	testing.expect_value(t, config_default(&c), Config_Error.None)
	defer config_destroy(&c)
	testing.expect_value(t, config_level_count(&c), 1)
	testing.expect_value(t, config_compartment_count(&c), 0)
	top, ok := config_top(&c)
	testing.expect(t, ok && top == BOTTOM)
	l, f := parse(&c, "unclassified")
	testing.expect_value(t, f.error, Parse_Error.None)
	testing.expect(t, l == BOTTOM)
	empty: Config
	_, ok = config_top(&empty)
	testing.expect(t, !ok)
	testing.expect(t, !config_valid(&empty, BOTTOM))
}

@(test)
trust_names_have_their_own_namespace_and_renames_keep_indices :: proc(t: ^testing.T) {
	c: Config
	us_config(t, &c)
	defer config_destroy(&c)
	testing.expect_value(t, config_trust_count(&c), 3)
	testing.expect_value(t, config_trust_name(&c, 1), "VETTED")
	testing.expect_value(t, config_trust_name(&c, 3), "")
	testing.expect_value(t, config_add_trust(&c, "vetted"), Config_Error.Duplicate_Name)
	testing.expect_value(t, config_add_trust(&c, "SECRET"), Config_Error.None)
	testing.expect_value(t, config_add_trust(&c, "A/B"), Config_Error.Invalid_Name)
	testing.expect_value(t, config_add_trust(&c, ""), Config_Error.Empty_Name)
	testing.expect_value(t, config_add_level(&c, "WEB"), Config_Error.None)
	idx, found := config_find_trust(&c, " trusted ")
	testing.expect(t, found && idx == 2)
	testing.expect(t, config_labelled(&c))
	testing.expect_value(t, config_rename_level(&c, 2, "secret"), Config_Error.None)
	testing.expect_value(t, config_rename_level(&c, 2, "Top Secret"), Config_Error.Duplicate_Name)
	testing.expect_value(t, config_rename_level(&c, 2, "RESTRICTED"), Config_Error.None)
	testing.expect_value(t, config_level_name(&c, 2), "RESTRICTED")
	testing.expect_value(t, config_rename_level(&c, 9, "X"), Config_Error.Unknown_Index)
	testing.expect_value(t, config_rename_compartment(&c, 0, "tk"), Config_Error.Duplicate_Name)
	testing.expect_value(t, config_rename_compartment(&c, 0, "SCI"), Config_Error.None)
	testing.expect_value(t, config_compartment_name(&c, 0), "SCI")
	testing.expect_value(t, config_rename_trust(&c, 0, "web"), Config_Error.None)
	testing.expect_value(t, config_rename_trust(&c, 0, "trusted"), Config_Error.Duplicate_Name)
	testing.expect_value(t, config_rename_trust(&c, 0, "OPEN WEB"), Config_Error.None)
	testing.expect_value(t, config_trust_name(&c, 0), "OPEN WEB")
	testing.expect_value(t, config_rename_trust(&c, 7, "X"), Config_Error.Unknown_Index)
	l, f := parse(&c, "restricted//sci;open web")
	testing.expect_value(t, f.error, Parse_Error.None)
	testing.expect(t, l.level == 2 && l.trust == 0 && compartment_has(l, 0))
	testing.expect_value(t, label_text(&c, l), "RESTRICTED//SCI")
	l.trust = 2
	testing.expect_value(t, label_text(&c, l), "RESTRICTED//SCI;TRUSTED")
	l.trust = 4
	testing.expect(t, !config_valid(&c, l))
	plain: Config
	testing.expect_value(t, config_default(&plain), Config_Error.None)
	defer config_destroy(&plain)
	testing.expect(t, !config_labelled(&plain))
	testing.expect_value(t, config_trust_count(&plain), 1)
	testing.expect_value(t, config_add_trust(&plain, "LOW"), Config_Error.None)
	testing.expect(t, !config_labelled(&plain))
	testing.expect_value(t, config_add_trust(&plain, "HIGH"), Config_Error.None)
	testing.expect(t, config_labelled(&plain))
	wide: Config
	wide_config(t, &wide, 1, 0, TRUST_LIMIT)
	defer config_destroy(&wide)
	testing.expect_value(t, config_add_trust(&wide, "ONE MORE"), Config_Error.Too_Many_Trusts)
}
