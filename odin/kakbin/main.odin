// Runnable kak binary: thin `package main` wrapper over package kak.
//
// main() forwards os.args to kak.main_entry and exits with its status.
// All startup init (signal handlers, arg parsing, singletons, global
// scope, kakrc sourcing honoring $KAKOUNE_RUNTIME) lives in
// kak.main_entry / kak.main_run_server; nothing else needs wiring here.
package main

import "core:os"
import kak "../kak"

main :: proc() {
	status := kak.main_entry(os.args, context.allocator)
	os.exit(status)
}
