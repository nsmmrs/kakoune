// Tests for the env_vars module ported from src/env_vars.cc.
// No C++ UnitTest covers env_vars; these assert the ported behavior.
package kak

import "core:os"
import "core:testing"

// Split at the first '=' only.
@(test)
env_vars_test_split_basic :: proc(t: ^testing.T) {
	name, value := env_vars_split_entry("FOO=bar")
	testing.expect_value(t, name, "FOO")
	testing.expect_value(t, value, "bar")
}

// Values may contain '='; only the first one splits.
@(test)
env_vars_test_split_value_with_equals :: proc(t: ^testing.T) {
	name, value := env_vars_split_entry("A=b=c=d")
	testing.expect_value(t, name, "A")
	testing.expect_value(t, value, "b=c=d")
}

// Entries without '=' map to "", like the C++ `(*value == '=') ? ... : String{}`.
@(test)
env_vars_test_split_no_equals :: proc(t: ^testing.T) {
	name, value := env_vars_split_entry("BARE")
	testing.expect_value(t, name, "BARE")
	testing.expect_value(t, value, "")
}

// Empty name, empty value, and empty entry edges.
@(test)
env_vars_test_split_edges :: proc(t: ^testing.T) {
	name, value := env_vars_split_entry("=v")
	testing.expect_value(t, name, "")
	testing.expect_value(t, value, "v")

	name, value = env_vars_split_entry("K=")
	testing.expect_value(t, name, "K")
	testing.expect_value(t, value, "")

	name, value = env_vars_split_entry("=")
	testing.expect_value(t, name, "")
	testing.expect_value(t, value, "")

	name, value = env_vars_split_entry("")
	testing.expect_value(t, name, "")
	testing.expect_value(t, value, "")
}

// get picks up the live environment, including a var set just for the test.
@(test)
env_vars_test_get_round_trip :: proc(t: ^testing.T) {
	os.set_env("KAK_ODIN_TEST_VAR", "kak-value=with=equals")
	defer os.unset_env("KAK_ODIN_TEST_VAR")
	m, err := env_vars_get()
	testing.expect_value(t, err, nil)
	defer env_vars_free(&m)
	testing.expect(t, len(m) > 0)
	v, ok := m["KAK_ODIN_TEST_VAR"]
	testing.expect(t, ok)
	testing.expect_value(t, v, "kak-value=with=equals")
	// The snapshot owns its strings: later changes do not alias the map.
	os.set_env("KAK_ODIN_TEST_VAR", "changed")
	v, _ = m["KAK_ODIN_TEST_VAR"]
	testing.expect_value(t, v, "kak-value=with=equals")
}

// free empties the map handle (nil) so double-free is impossible.
@(test)
env_vars_test_free_nils :: proc(t: ^testing.T) {
	m, err := env_vars_get()
	testing.expect_value(t, err, nil)
	env_vars_free(&m)
	testing.expect(t, m == nil)
}
