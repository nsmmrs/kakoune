---
id: TASK-xd9qbf
title: "Port knot remainders (wave 5c)"
status: done
type: task
priority: 3
parent: EPIC-d7c7yw
created: "2026-10-03T13:03:59.618950Z"
updated: "2026-10-03T13:45:52.071448Z"
---



Fill remainder stubs inside merged modules: CommandParser+command_expand (command_manager.cc), options_registry+option_get_* (option_manager/scope), local_scope.hh, ScopedEdition/ScopedSelectionEdition. Edit existing files only where stubs live. Gate: odin test + vet/strict-style green. No commits.