# CPDN Credit Script

## Purpose

`cpdn_credit` is a BOINC daemon that:

1. Processes unhandled trickle-up messages from `msg_from_host`.
2. Awards/updates BOINC credit.
3. Writes normalized trickle records into the CPDN experiment `trickle` table.
4. Handles a fallback Darwin/macOS credit path for specific completed workunits.

## Repository Placement

This project now builds against BOINC source-tree headers and BOINC static archives.
It does not need to live under the BOINC source tree, but CMake must be given the BOINC source path.

## Prerequisites

1. BOINC source downloaded from github and built (no `make install` required).
2. CMake 3.16+.
3. C++ compiler (e.g. `g++`).
4. MySQL/MariaDB development headers and client libraries.

### BOINC

Download the BOINC repo and check out the same branch as used for the server (8.0.2 in this example).
You may also need to install additional system software such as mariadb (for myself),
curl, etc. Check the output from the configure log or see BOINC install instructions.

To build boinc (adjust install --prefix as needed)

```bash
./_autosetup
./configure --prefix="${HOME}/github/boinc-8.0.2-x86_64"  \
            --enable-server --enable-client --disable-apps --enable-libraries  \
            --build=i686-pc-linux-gnu --host=i686-pc-linux-gnu   \
              "CFLAGS=-g -O2 ${M32}" "CXXFLAGS=-g -O2"
make
```

'--enable-server --enable-libraries' must be specified.

No 'make install' step is needed as this code needs to reference headers directly in the 
source tree, which are not copied to the install location on a make install.

#### Python2 distutils problem

If BOINC builds fails with python error:

```bash
Making all in py
make[2]: Entering directory '/home/glenn/github/boinc/py'
python setup.py build --build-base=../py
Traceback (most recent call last):
  File "/home/glenn/github/boinc/py/setup.py", line 3, in <module>
    from distutils.core import setup
ModuleNotFoundError: No module named 'distutils'
```

Make sure the following packages are installed on the system:

```bash
sudo apt install python3 python-is-python3 python3-setuptools
```

py/setup.py in BOINC (v8.0.2) uses distutils which was removed in Python 3.12. Also the py/Makefile.am
hardcodes 'python' not 'python3'.

Patch the BOINC python script:

```bash
cd boinc    # location of the cloned boinc repo
sed -i 's/from distutils.core import setup/from setuptools import setup/' py/setup.py.in py/setup.py
```

Then rerun the autosetup & configures steps above to remake the Makefiles.

#### Manually compile libsched

If the BOINC make step still fails and the library sched/libsched.a is not built, it can be built
manually by:

```bash
make -C /home/glenn/github/boinc/sched libsched.a
```

## Build cpdn_credit with CMake

The top-level `CMakeLists.txt` now uses these BOINC variables:

1. `BOINC_SRC` (path to BOINC source tree; required)
2. `BOINC_SCHED_STATIC` (default: `${BOINC_SRC}/sched/libsched.a`)
3. `BOINC_CRYPT_STATIC` (default: `${BOINC_SRC}/lib/libboinc_crypt.a`)
4. `BOINC_CORE_STATIC` (default: `${BOINC_SRC}/lib/libboinc.a`)

### 1) Set build environment (example)

```bash
export BOINC_SRC="${HOME}/github/boinc"
export MYSQL_INCLUDE_DIR=/usr/include/mysql
export MYSQL_LIBRARY_DIR=/usr/lib64
export MYSQL_EXTRA_LIBRARY_DIR=/usr/lib64/mysql
```

### 2) Configure

```bash
cmake -S . -B build \
  -DBOINC_SRC="${BOINC_SRC}" \
  -DBOINC_SCHED_STATIC="${BOINC_SRC}/sched/libsched.a" \
  -DBOINC_CRYPT_STATIC="${BOINC_SRC}/lib/libboinc_crypt.a" \
  -DBOINC_CORE_STATIC="${BOINC_SRC}/lib/libboinc.a" \
  -DMYSQL_INCLUDE_DIR="${MYSQL_INCLUDE_DIR}" \
  -DMYSQL_LIBRARY_DIR="${MYSQL_LIBRARY_DIR}" \
  -DMYSQL_EXTRA_LIBRARY_DIR="${MYSQL_EXTRA_LIBRARY_DIR}"
```

### 3) Compile

```bash
cmake --build build
```

Binary output:

`build/cpdn_credit`

## Deploy

Move/copy `build/cpdn_credit` to the BOINC project `bin` directory.

To run as a BOINC daemon, add this to the project `config.xml` (adjust path):

```xml
<daemon>
  <cmd>cpdn_credit -dir /PROJECT_DIRECTORY/trickle/ </cmd>
</daemon>
```

Restart BOINC project daemons after updating config.

## Test (CTest)

A DB-backed end-to-end test is provided in `test/run_test.sh` and registered with CTest as `credit_varieties`.

It verifies both:

1. `msg_from_host.variety='orig'`
2. `msg_from_host.variety='general'`

and asserts both varieties produce identical credit for identical `ts`.

### Test prerequisites

1. `mariadb` or `mysql` client in `PATH`.
2. Accessible BOINC main DB and CPDN experiment DB.
3. Writable `CPDN_RUN_DIR` (the test auto-generates a minimal `config.xml` if missing).
4. `trickle.data` column exists in the experiment DB table.

### Enable test in CMake

```bash
cmake -S . -B build \
  -DBOINC_SRC="${BOINC_SRC}" \
  -DBOINC_SCHED_STATIC="${BOINC_SRC}/sched/libsched.a" \
  -DBOINC_CRYPT_STATIC="${BOINC_SRC}/lib/libboinc_crypt.a" \
  -DBOINC_CORE_STATIC="${BOINC_SRC}/lib/libboinc.a" \
  -DMYSQL_INCLUDE_DIR="${MYSQL_INCLUDE_DIR}" \
  -DMYSQL_LIBRARY_DIR="${MYSQL_LIBRARY_DIR}" \
  -DMYSQL_EXTRA_LIBRARY_DIR="${MYSQL_EXTRA_LIBRARY_DIR}" \
  -DENABLE_CPDN_TEST=ON
cmake --build build
```

### Set test environment (example)

```bash
export CPDN_MAIN_DB=cpdnboinc
export CPDN_EXPT_DB=cpdnexpt
export CPDN_DB_HOST=127.0.0.1
export CPDN_DB_PORT=3306
export CPDN_DB_USER=root
export CPDN_DB_PASS=
export CPDN_RUN_DIR=/path/to/boinc/projects/PROJECT
```

Optional:

```bash
export CPDN_TEMPLATE_RESULT_ID=12345
export CPDN_ASSERT_HOST_USER_TEAM=1
```

### Run

```bash
ctest --test-dir build -R credit_varieties --output-on-failure
```

For full variable list, see `test/README.md`.
