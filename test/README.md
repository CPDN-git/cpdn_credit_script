# Test (CTest)

This directory contains a DB-backed test for `cpdn_credit` that validates both trickle paths:

- `msg_from_host.variety='orig'`
- `msg_from_host.variety='general'`

It asserts that both paths produce identical credit when `ts` is identical, and verifies trickle row insertion behavior for `data` (`NULL` for `orig`, populated for `general`).
The optional `test/setup_test.sh` helper can bootstrap a minimal local BOINC/expt schema for this test when no suitable local DB exists yet.

## Enable in CMake

Configure with:

```bash
cmake -S . -B build \
  -DBOINC_SRC="${HOME}/github/boinc" -DENABLE_CPDN_TEST=ON
```

Then run:

```bash
cmake --build build
ctest --test-dir build -R credit_varieties --output-on-failure
```

## Local Setup

If the local MySQL/MariaDB instance does not already have a usable test account, bootstrap one explicitly first:

```bash
export CPDN_DB_USER=boinc
export CPDN_DB_PASS=testpass123
./test/setup_test.sh
```

If the user does not exist, it will be created with the password specified.

On Debian/MariaDB systems, `setup_test.sh` prefers `sudo mariadb` socket auth automatically. 
It creates or resets the target user, grants access to `CPDN_MAIN_DB` and `CPDN_EXPT_DB`, 
and writes `CPDN_RUN_DIR/config.xml` unless `CPDN_SETUP_WRITE_CONFIG=0`.
If either test database does not exist, it bootstraps a minimal local schema and seed data needed by `credit_varieties`.
If a database already exists, `setup_test.sh` will not drop or rewrite it; it only validates 
that the required tables/columns are already present.

If socket auth is unavailable, force TCP admin mode instead:

```bash
export CPDN_SETUP_DB_ADMIN_MODE=tcp
export CPDN_SETUP_DB_ADMIN_USER=root
export CPDN_SETUP_DB_ADMIN_PASS=your_admin_password
./test/setup_test.sh
```

## Required Environment Variables

The test script reads these variables at runtime:

- `CPDN_MAIN_DB` (default: `db_name` from `CPDN_RUN_DIR/config.xml`, else `cpdnboinc`)
- `CPDN_EXPT_DB` (default: `cpdnexpt`)
- `CPDN_DB_HOST` (default: `db_host` from `CPDN_RUN_DIR/config.xml`, else `127.0.0.1`)
- `CPDN_DB_PORT` (default: `3306`)
- `CPDN_DB_USER` (default: `db_user` from `CPDN_RUN_DIR/config.xml`, else `boinc`)
- `CPDN_DB_PASS` (default: `db_passwd` from `CPDN_RUN_DIR/config.xml`, else empty)
- `CPDN_RUN_DIR` (defaults to current directory; if `config.xml` is missing, the script creates a minimal one)

Optional tuning:

- `CPDN_TEMPLATE_RESULT_ID`
- `CPDN_TS` (default: `1000`)
- `CPDN_CP` (default: `100`)
- `CPDN_PHASE` (default: `60`)
- `CPDN_VR` (default: `6.09`)
- `CPDN_DATA` (default: `12.4,14.5,16.5,18.7,19.5`)
- `CPDN_CREDIT_PER_TIMESTEP` (default: `0.001`)
- `CPDN_ASSERT_HOST_USER_TEAM` (`1` to make host/user/team increase mandatory)
- `CPDN_KEEP_FIXTURES` (`1` to skip cleanup on exit)
- `CPDN_TEST_APPID` (force appid for the temporary model row)

Setup-only variables:

- `CPDN_SETUP_DB_ADMIN_MODE` (`auto` by default; prefers `sudo mariadb`, or use `socket` / `tcp`)
- `CPDN_SETUP_DB_ADMIN_USER` / `CPDN_SETUP_DB_ADMIN_PASS` for a MySQL account that can `CREATE USER` and `GRANT` when using TCP admin mode
- `CPDN_SETUP_DB_ADMIN_HOST` / `CPDN_SETUP_DB_ADMIN_PORT` if admin access differs from the test connection
- `CPDN_SETUP_DB_GRANT_HOSTS` (default: `localhost,127.0.0.1`)
- `CPDN_SETUP_WRITE_CONFIG` (`1` by default; set `0` to avoid rewriting `config.xml`)

## Notes

- The script requires either `mariadb` or `mysql` client in `PATH`.
- If neither client is found, the script exits with a CTest skip-style pass (`exit 0` with `SKIP` message).
- The script no longer defaults to MySQL `root`; use `CPDN_DB_USER`/`CPDN_DB_PASS` or keep project credentials in `config.xml`.
- `setup_test.sh` is intentionally separate from `run_test.sh`; provisioning a DB user is privileged and should stay explicit.
- `setup_test.sh` resets the password for the target test account on each run via `ALTER USER`, so rerunning it repairs a stale local `boinc` account in the common case.
- If `CPDN_MAIN_DB` / `CPDN_EXPT_DB` do not exist, `setup_test.sh` creates them with a minimal BOINC-style test schema and seed rows.
- If either DB already exists but has the wrong schema, `setup_test.sh` stops instead of altering it.
- If `setup_test.sh` still says login fails after `ALTER USER`/`GRANT`, the account is likely constrained by host/plugin state outside the script's assumptions. Inspect `mysql.user` or use a different `CPDN_DB_USER`.
- The script creates temporary fixtures in DB tables and removes them on exit unless `CPDN_KEEP_FIXTURES=1`.
- The script also creates `config.xml` and `cgi-bin/` in `CPDN_RUN_DIR` when missing, then removes them on cleanup unless `CPDN_KEEP_FIXTURES=1`.
