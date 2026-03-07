# Actions

## Code Review Actions

1. High priority: correct trickle error handling so failures from `handle_trickle()` write steps are propagated back to `do_trickle_scan()` instead of being treated as success and marked handled.
2. Replace the fixed `g_dbModel` array with a container keyed by appid/modelid so model cache bounds are data-driven rather than limited to `1..99`.
3. Distinguish expected "model row not present" cases from actual DB lookup failures during startup and log or fail clearly on unexpected errors while loading models.
4. Remove or document the legacy `MODEL::archive` buffer more clearly, since the production column is a `BLOB` and the field is not parsed or used.
5. Tighten `test/setup_test.sh` validation for existing databases so incompatible `model` or `trickle` schemas fail early with targeted diagnostics.
