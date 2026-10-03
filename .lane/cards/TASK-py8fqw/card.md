---
id: TASK-py8fqw
title: "test/run acceptance (676 cases)"
status: backlog
type: task
priority: 3
parent: EPIC-d7c7yw
deps:
- TASK-6bschq
created: "2026-10-03T15:21:52.891946Z"
updated: "2026-10-03T15:21:52.891946Z"
---

Wire package-main binary (thin wrapper over package kak main_*), KAKOUNE_RUNTIME=repo rc/, patched runner (harness hardcodes src/kak; json-UI fifos + kak -p). Gate: test/run green vs C++ baseline. Blocked by commands merge.