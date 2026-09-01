# Dashboard examples

These files are placeholders. Replace every `YOUR_*` and `C:\example\...` value with paths you actually own. Do not paste absolute user paths, live thread ids, receipts, tokens, or private registry names into issues.

- [config.placeholder.json](config.placeholder.json) — `telephone-line-dashboard-config-v1` listing descriptor files
- [project.placeholder.json](project.placeholder.json) — `telephone-line-dashboard-project-descriptor-v1` pointing at one StateRoot. Add optional `direct_job_roots` (unique, at most 32) and `session_events_root` when Telephone jobs and Direct jobs live in sibling directories. The observer correlates sibling jobs, then applies the Lead filter, and retires superseded Direct history when newer delivered current or successor truth owns the package. Optional `current_line_job_id` / `successor_line_job_id` identify the exact current or successor job; a resumed correction is authorized only together with the proven Direct session. Optional `supervisor_state_root` points at supervisor inbox/outbox/control evidence; the observer never mutates it.
- [closure.placeholder.json](closure.placeholder.json) — `telephone-line-dashboard-closure-v1` whose receipt identity must match a real receipt file

See [../../dashboard.md](../../dashboard.md).
