---
id: TASK-v2l2zh
title: "remote success-path Remote_UI/watcher leak"
status: backlog
type: task
priority: 3
parent: TASK-py8fqw
created: "2026-10-03T19:03:40.683548Z"
updated: "2026-10-03T19:03:40.683548Z"
---

remote_ui_destroy has one caller (failure path only). Success-path disconnect never destroys Remote_UI -> socket watcher stays registered -> event_manager teardown assert risk via kak -c disconnect + shutdown. Needs ownership design + socketpair test. Found during binary smoke (local-UI dispatch fixed in e464578a).