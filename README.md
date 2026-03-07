# CPDN Credit Awarding Code

## Purpose

`cpdn_credit` is a BOINC daemon that:

1. Processes unhandled trickle-up messages from `msg_from_host`.
2. Awards/updates BOINC credit.
3. Writes normalized trickle records into the CPDN experiment `trickle` table.
4. Handles a fallback Darwin/macOS credit path for specific completed workunits.

Two trickle `variety` tags are supported: `orig` and `general`. The first is a 
subset of `general` as it doesn't use the `data` field; it was used by the UKMO
models. `general` is used by the OpenIFS models to return small data values
for diagnostics (such as model spread).

Code originally adapted by Andy Bowery from BOINC credit code for CPDN.
Later changes/additions by Glenn Carver. Test code/structure developed
by GPT-5.4 and tweaked by Glenn.

## Repository Placement

This project builds against BOINC source-tree headers and BOINC static compiled libraries.
It does not need to be placed under the BOINC source tree to compile, 
but CMake must be given the BOINC source path.

It should be compiled on the same machine as the BOINC server using the same
source code as the server.

## Prerequisites

1. BOINC source downloaded from github and built (no `make install` required).
2. CMake 3.16+.
3. C++ compiler.
4. MySQL/MariaDB development headers and client libraries.

### BOINC

Download the BOINC repo and check out the same branch as used for the server (8.0.2 in this example).
You may also need to install additional system software such as mariadb,
curl, etc, if not present on the machine. Check the output from the configure log or see BOINC install instructions.

To build boinc (adjust install --prefix as needed)

```bash
./_autosetup
./configure --prefix="${HOME}/github/boinc-8.0.2-x86_64"  \
            --enable-server --enable-client --enable-libraries --disable-apps --disable-manager  \
            --build=i686-pc-linux-gnu --host=i686-pc-linux-gnu   \
              "CFLAGS=-g -O2" "CXXFLAGS=-g -O2"
make
```

Note: '--enable-server --enable-libraries' must be specified.

No 'make install' step is needed as this code needs to reference headers directly in the 
source tree, which are not copied to the install location on a make install.

#### Python2 distutils problem

If the BOINC build fails with the python error:

```bash
Making all in py
make[2]: Entering directory '/home/glenn/github/boinc/py'
python setup.py build --build-base=../py
Traceback (most recent call last):
  File "/home/glenn/github/boinc/py/setup.py", line 3, in <module>
    from distutils.core import setup
ModuleNotFoundError: No module named 'distutils'
```

1. Make sure the following packages are installed on the system:

```bash
sudo apt install python3 python-is-python3 python3-setuptools
```

2. py/setup.py in BOINC (v8.0.2) uses distutils which was removed in Python 3.12. Also the py/Makefile.am
hardcodes 'python' not 'python3'.  Patch the BOINC python script:

```bash
cd boinc    # location of the cloned boinc repo
sed -i 's/from distutils.core import setup/from setuptools import setup/' py/setup.py.in py/setup.py
```

3. Then rerun the autosetup & configures steps above to remake the Makefiles.

#### Manually compile libsched

If the BOINC make step still fails and the library sched/libsched.a is not built, it can be built
manually by:

```bash
make -C /home/glenn/github/boinc/sched libsched.a
```

## Build cpdn_credit with CMake

The top-level `CMakeLists.txt` uses these BOINC variables:

1. `BOINC_SRC` (path to BOINC source tree; required)
2. `BOINC_SCHED_STATIC` (default: `${BOINC_SRC}/sched/libsched.a`)
3. `BOINC_CRYPT_STATIC` (default: `${BOINC_SRC}/lib/libboinc_crypt.a`)
4. `BOINC_CORE_STATIC` (default: `${BOINC_SRC}/lib/libboinc.a`)

### 1) Set build environment (example)

```bash
export BOINC_SRC="${HOME}/github/boinc"
```

If MariaDB is not installed in a standard directory, also set:

```bash
export MYSQL_INCLUDE_DIR=/usr/include/mysql
export MYSQL_LIBRARY_DIR=/usr/lib64
export MYSQL_EXTRA_LIBRARY_DIR=/usr/lib64/mysql
```

### 2) Configure

```bash
cmake -S . -B build  -DBOINC_SRC="${BOINC_SRC}"
```

If the BOINC libraries or MYSQL files are located in non-standard
directories, these paths can also be set:

```bash
  -DBOINC_SCHED_STATIC="${BOINC_SRC}/sched/libsched.a" \
  -DBOINC_CRYPT_STATIC="${BOINC_SRC}/lib/libboinc_crypt.a" \
  -DBOINC_CORE_STATIC="${BOINC_SRC}/lib/libboinc.a" \
  -DMYSQL_INCLUDE_DIR="${MYSQL_INCLUDE_DIR}" \
  -DMYSQL_LIBRARY_DIR="${MYSQL_LIBRARY_DIR}" \
  -DMYSQL_EXTRA_LIBRARY_DIR="${MYSQL_EXTRA_LIBRARY_DIR}
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
2. Either an accessible BOINC main DB and CPDN experiment DB, or permission to let `test/setup_test.sh` bootstrap minimal local test DBs.
3. Writable `CPDN_RUN_DIR` (the test auto-generates a minimal `config.xml` if missing).
4. If you point the test at an existing experiment DB, `trickle.data` must already exist there.

### Run the test

See test/README.md for further instructions and details.
