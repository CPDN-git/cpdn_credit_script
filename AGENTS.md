# CPDN Credit Script Analysis

## Overview

This repository builds a BOINC daemon that continuously processes trickle-up messages and awards credit for CPDN results. It has two functional paths:

1. Normal trickle processing from `msg_from_host` rows (`handled=0`), where trickle XML is parsed and used to update credit.
2. A special fallback path for completed WAH2 Darwin/macOS workunits that still have zero granted credit.

The core processing logic is in `cpdn_credit.cpp`. The loop/framework for polling and marking trickles as handled is in `cpdn_trickle_handler.cpp`.

## Data Flow Through the Code

1. Startup and DB initialization:
   - `main()` parses BOINC config and opens the main BOINC DB.
   - `handle_trickle_init()` opens the experiment DB and loads `model` rows into `g_dbModel[]`.

2. Main loop (`main_loop()`):
   - Runs `handle_wah2_darwin_workunits()` for Darwin fallback credit.
   - Runs `do_trickle_scan()` to process unhandled trickle-up messages.
   - Sleeps 30 seconds and repeats (unless `--one_pass`).

3. Trickle scan and handling:
   - `do_trickle_scan()` enumerates `msg_from_host where handled=0`.
   - Each message goes to `handle_trickle()`.
   - After processing attempt, message is marked handled (`mfh.handled = true; mfh.update()`).

4. Per-trickle processing (`handle_trickle()`):
   - Parse XML tags into `TRICKLE_MSG`: `result_name`, `ph`, `ts`, `cp`, `vr`.
   - Look up BOINC `result` by `result_name`.
   - Use `result.appid` to select model config (`credit_per_timestep`).
   - Compute credit from timesteps (`ts`) and model rate, then apply 9% correction factor.
   - Compute incremental credit vs existing `result.granted_credit`.
   - Update host/user/team totals via `credit_grant()`.
   - Update `result.granted_credit` and `result.claimed_credit`.
   - Insert a normalized row into experiment `trickle` table.
   - Update `result.opaque` (last handled time) and `result.app_version_num` (stored timestep count).

## Database Table Reads and Writes (Detailed)

### Reads

1. Experiment DB `model` table:
   - `handle_trickle_init()` loops model IDs and calls `g_dbModel[i].lookup("WHERE modelid=%d")`.

2. BOINC DB tables for trickle handling:
   - `DB_HOST::lookup_id(msg.hostid)` in `handle_trickle()`.
   - `DB_RESULT::lookup(where name='<result_name>')` in `handle_trickle()`.

3. BOINC DB for fallback Darwin path:
   - `DB_RESULT::enumerate("where outcome = 1 and granted_credit = 0 and appid = 30")`.
   - Raw SQL join in `lookup(resultid)` across:
     - main DB: `result`, `host`
     - experiment DB: `cpdn_workunit`, `cpdn_batch`

4. BOINC message queue table:
   - `DB_MSG_FROM_HOST::enumerate("where handled=0")` in `do_trickle_scan()`.

### Writes

1. Mark message handled:
   - `mfh.handled = true; mfh.update();` in `do_trickle_scan()`.

2. Result credit fields (normal trickle path):
   - `result.update_field("granted_credit=..., claimed_credit=...")`.

3. Result tracking fields:
   - `result.update_field("opaque=..., app_version_num=...")`.

4. Insert trickle row into experiment DB:
   - `insert_trickle()` executes SQL:
     - `insert into <expt>.trickle(msghostid, userid, hostid, resultid, workunitid, phase, timestep, cputime, clientdate, trickledate, ipaddr) values (...)`

5. Host/user/team credit totals and RAC-like averages:
   - `host.update_field(...)`
   - `user.update_field(...)`
   - `team.update_field(...)` when user has a team

6. Darwin fallback path also writes:
   - `result.granted_credit`, `result.claimed_credit`
   - host/user/team totals through `credit_grant()`

## How “Trickle” Relates to Awarding Credit

The trickle is treated as the incremental progress signal from a client in XML form. The script reads it from `msg.xml`, extracts `ts` (timesteps), and calculates credit as:

- `base_credit = ts * model.credit_per_timestep`
- `final_credit = base_credit * 1.09`

Then it compares this to current result credit and grants only the incremental delta to host/user/team. It also records trickle metadata in a dedicated experiment `trickle` table for audit/reporting.

`ph` (phase) is currently parsed and stored in the `trickle` table, but current credit calculation uses `ts`, not `ph`.

## Planned Changes for New Trickle Type (Credit Logic Not Changed Yet)

Goal: retain existing trickle behavior while adding a new trickle with:

- `<data>` string payload (VARCHAR(512)) stored in the existing `trickle` table
- trickle type identified by `msg_from_host.variety` (`orig` vs `general`)

### Code Areas That Need Changes

1. `TRICKLE_MSG` parsing (`cpdn_credit.h`):
   - Add field for `data`.
   - Parse `<data>` while retaining existing `<ph>`, `<ts>`, `<cp>`, `<vr>`.
   - Source trickle type from `MSG_FROM_HOST.variety` in DB (not from XML).

2. `handle_trickle()` branching (`cpdn_credit.cpp`):
   - Branch on `msg.variety`:
     - `orig`: existing behavior unchanged.
     - `general`: accept/store `data`; `ph` may be present or empty.
   - Keep credit calculation identical for all varieties (always driven by `ts`).

3. Trickle insert SQL (`insert_trickle()` in `cpdn_credit.cpp`):
   - Extend insert columns/values to persist `data`.
   - Ensure proper SQL escaping for `data` string.
   - Preserve ability to write existing `orig` rows.
   - `orig` with empty `<data></data>` should store `NULL` (not empty string).
   - For invalid `data` content, continue credit processing but store `NULL`.

4. DB trickle model mapping (`cpdn_db.h` and `cpdn_db.cpp`):
   - Extend `TRICKLE` struct with `data`.
   - Update `DB_TRICKLE::db_parse()` and `DB_TRICKLE::db_print()` accordingly.

5. DB schema migration (external to this code):
   - Add `data` column to existing experiment `trickle` table.
   - Keep current columns (`phase`, etc.) so `orig` remains supported.

### Implementation Caution

`TRICKLE_MSG::parse()` currently initializes `nsteps` and `result_name`, but not all numeric fields if tags are missing. Introducing `general` (without `ph`) should include explicit initialization/defaulting so missing tags do not produce undefined values.

## Build and Test Update

Build and test infrastructure now uses BOINC source paths and static BOINC libs:

1. Top-level `CMakeLists.txt` builds `cpdn_credit`.
2. Configurable CMake variables:
   - `BOINC_SRC`
   - `BOINC_SCHED_STATIC`
   - `BOINC_CRYPT_STATIC`
   - `BOINC_CORE_STATIC`
   - `MYSQL_INCLUDE_DIR`
   - `MYSQL_LIBRARY_DIR`
   - `MYSQL_EXTRA_LIBRARY_DIR`
3. CTest registration (opt-in via `-DENABLE_CPDN_TEST=ON`) for:
   - `credit_varieties`
4. Test script:
   - `test/run_test.sh`
5. Test docs:
   - `test/README.md`

Header include model:

1. This project includes BOINC headers directly from BOINC source directories.
2. CMake adds `${BOINC_SRC}`, `${BOINC_SRC}/lib`, `${BOINC_SRC}/db`, and `${BOINC_SRC}/sched`.

Test behavior:

1. Checks for `mariadb`/`mysql` client.
2. Seeds temporary fixtures (`result`, `model`, and two `msg_from_host` rows: `orig` and `general`).
3. Generates a minimal BOINC `config.xml` in `CPDN_RUN_DIR` if missing.
4. Creates `CPDN_RUN_DIR/cgi-bin` if missing so BOINC treats it as a project directory.
5. Runs `cpdn_credit --one_pass`.
6. Verifies:
   - both messages are marked handled
   - expected credit is awarded
   - `orig` and `general` credit values are equal
   - trickle rows are inserted for both
   - `orig` row has `data IS NULL`
   - `general` row has expected `data` value
7. Cleans up fixtures by default (optional keep mode for debugging).
