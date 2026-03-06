# Test (CTest)

This directory contains a DB-backed test for `cpdn_credit` that validates both trickle paths:

- `msg_from_host.variety='orig'`
- `msg_from_host.variety='general'`

It asserts that both paths produce identical credit when `ts` is identical, and verifies trickle row insertion behavior for `data` (`NULL` for `orig`, populated for `general`).

## Enable in CMake

Configure with:

```bash
cmake -S . -B build \
  -DBOINC_SRC="${HOME}/github/boinc" \
  -DBOINC_SCHED_STATIC="${HOME}/github/boinc/sched/libsched.a" \
  -DBOINC_CRYPT_STATIC="${HOME}/github/boinc/lib/libboinc_crypt.a" \
  -DBOINC_CORE_STATIC="${HOME}/github/boinc/lib/libboinc.a" \
  -DENABLE_CPDN_TEST=ON
```

Then run:

```bash
cmake --build build
ctest --test-dir build -R credit_varieties --output-on-failure
```

## Required Environment Variables

The test script reads these variables at runtime:

- `CPDN_MAIN_DB` (default: `cpdnboinc`)
- `CPDN_EXPT_DB` (default: `cpdnexpt`)
- `CPDN_DB_HOST` (default: `127.0.0.1`)
- `CPDN_DB_PORT` (default: `3306`)
- `CPDN_DB_USER` (default: `root`)
- `CPDN_DB_PASS` (default: empty)
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

## Notes

- The script requires either `mariadb` or `mysql` client in `PATH`.
- If neither client is found, the script exits with a CTest skip-style pass (`exit 0` with `SKIP` message).
- The script creates temporary fixtures in DB tables and removes them on exit unless `CPDN_KEEP_FIXTURES=1`.
- The script also creates `config.xml` and `cgi-bin/` in `CPDN_RUN_DIR` when missing, then removes them on cleanup unless `CPDN_KEEP_FIXTURES=1`.
