#!/usr/bin/env bash
# run_test.sh executes the DB-backed end-to-end test for cpdn_credit. It seeds
# temporary DB fixtures, runs `cpdn_credit --one_pass`, validates credit/trickle
# results for both `orig` and `general`, then cleans up unless told not to.
#
# Typical use through CTest:
#   ctest --test-dir build -R credit_varieties --output-on-failure
#
# Direct use:
#   export CPDN_DB_USER=boinc
#   export CPDN_DB_PASS=testpass123   # same password chosen during setup
#   ./test/run_test.sh ./build/cpdn_credit
#
# If the local DB user does not exist yet, provision it first:
#   ./test/setup_test.sh
set -euo pipefail

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

warn() {
    echo "WARN: $*" >&2
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local label="$3"
    if [[ "$expected" != "$actual" ]]; then
        fail "${label}: expected '${expected}', got '${actual}'"
    fi
}

assert_float_close() {
    local actual="$1"
    local expected="$2"
    local tolerance="$3"
    local label="$4"
    if ! awk -v a="$actual" -v e="$expected" -v t="$tolerance" 'BEGIN { d=a-e; if (d<0) d=-d; exit !(d<=t) }'; then
        fail "${label}: expected ${expected}, got ${actual}, tolerance ${tolerance}"
    fi
}

is_greater() {
    local a="$1"
    local b="$2"
    awk -v av="$a" -v bv="$b" 'BEGIN { exit !(av > bv) }'
}

sql_escape() {
    printf "%s" "$1" | sed "s/'/''/g"
}

xml_escape() {
    printf "%s" "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

find_mysql_client() {
    if command -v mariadb >/dev/null 2>&1; then
        echo "mariadb"
        return
    fi
    if command -v mysql >/dev/null 2>&1; then
        echo "mysql"
        return
    fi
    echo ""
}

trim() {
    printf "%s" "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

read_config_value() {
    local file_path="$1"
    local key="$2"
    if [[ ! -f "${file_path}" ]]; then
        return 0
    fi
    awk -v key="${key}" '
        {
            while (match($0, "<" key ">[^<]*</" key ">")) {
                value = substr($0, RSTART, RLENGTH)
                gsub("^<" key ">", "", value)
                gsub("</" key ">$", "", value)
                print value
                exit
                $0 = substr($0, RSTART + RLENGTH)
            }
        }
    ' "${file_path}"
}

BIN_PATH="${1:-}"
if [[ -z "${BIN_PATH}" || ! -x "${BIN_PATH}" ]]; then
    fail "First argument must be an executable cpdn_credit binary path"
fi

MYSQL_CLIENT="$(find_mysql_client)"
if [[ -z "${MYSQL_CLIENT}" ]]; then
    echo "SKIP: mysql/mariadb client not found in PATH"
    exit 0
fi

RUN_DIR="${CPDN_RUN_DIR:-$(pwd)}"

TRICKLE_TS="${CPDN_TS:-1000}"
TRICKLE_CP="${CPDN_CP:-100}"
TRICKLE_PHASE="${CPDN_PHASE:-60}"
TRICKLE_VR="${CPDN_VR:-6.09}"
TRICKLE_DATA="${CPDN_DATA:-12.4,14.5,16.5,18.7,19.5}"
MODEL_CPT="${CPDN_CREDIT_PER_TIMESTEP:-0.001}"

ASSERT_HOST_USER_TEAM="${CPDN_ASSERT_HOST_USER_TEAM:-0}"
KEEP_FIXTURES="${CPDN_KEEP_FIXTURES:-0}"
TEMPLATE_RESULT_ID="${CPDN_TEMPLATE_RESULT_ID:-}"

if [[ ! -d "${RUN_DIR}" ]]; then
    fail "CPDN_RUN_DIR is not a directory: ${RUN_DIR}"
fi

generated_config_xml=0
generated_cgi_bin=0
config_xml_path="${RUN_DIR}/config.xml"
cgi_bin_path="${RUN_DIR}/cgi-bin"

config_db_name="$(trim "$(read_config_value "${config_xml_path}" "db_name")")"
config_db_host="$(trim "$(read_config_value "${config_xml_path}" "db_host")")"
config_db_user="$(trim "$(read_config_value "${config_xml_path}" "db_user")")"
config_db_pass="$(trim "$(read_config_value "${config_xml_path}" "db_passwd")")"

DB_HOST="${CPDN_DB_HOST:-${config_db_host:-127.0.0.1}}"
DB_PORT="${CPDN_DB_PORT:-3306}"
DB_USER="${CPDN_DB_USER:-${config_db_user:-boinc}}"
DB_PASS="${CPDN_DB_PASS:-${config_db_pass:-}}"
MAIN_DB="${CPDN_MAIN_DB:-${config_db_name:-cpdnboinc}}"
EXPT_DB="${CPDN_EXPT_DB:-cpdnexpt}"

if [[ ! -f "${config_xml_path}" ]]; then
    db_name_xml="$(xml_escape "${MAIN_DB}")"
    db_host_xml="$(xml_escape "${DB_HOST}")"
    db_user_xml="$(xml_escape "${DB_USER}")"
    db_pass_xml="$(xml_escape "${DB_PASS}")"

    cat > "${config_xml_path}" <<EOF
<boinc>
  <config>
    <db_name>${db_name_xml}</db_name>
    <db_host>${db_host_xml}</db_host>
    <db_user>${db_user_xml}</db_user>
    <db_passwd>${db_pass_xml}</db_passwd>
  </config>
</boinc>
EOF
    generated_config_xml=1
    echo "Generated ${config_xml_path} from CPDN_DB_* and CPDN_MAIN_DB"
fi

if [[ ! -d "${cgi_bin_path}" ]]; then
    mkdir -p "${cgi_bin_path}"
    generated_cgi_bin=1
    echo "Created ${cgi_bin_path} so BOINC treats CPDN_RUN_DIR as a project dir"
fi

MYSQL_ARGS=(-h "${DB_HOST}" -P "${DB_PORT}" -u "${DB_USER}")
if [[ -n "${DB_PASS}" ]]; then
    MYSQL_ARGS+=(-p"${DB_PASS}")
fi

sql_exec() {
    "${MYSQL_CLIENT}" "${MYSQL_ARGS[@]}" -e "$1"
}

sql_scalar() {
    "${MYSQL_CLIENT}" "${MYSQL_ARGS[@]}" -N -B -e "$1"
}

assert_db_access() {
    local stderr_file
    stderr_file="$(mktemp)"
    if ! "${MYSQL_CLIENT}" "${MYSQL_ARGS[@]}" -N -B -e "SELECT 1" > /dev/null 2> "${stderr_file}"; then
        local err_text
        err_text="$(cat "${stderr_file}")"
        rm -f "${stderr_file}"
        fail "Unable to connect to MySQL as '${DB_USER}' on ${DB_HOST}:${DB_PORT}. Set CPDN_DB_USER/CPDN_DB_PASS explicitly, provide matching credentials in ${config_xml_path}, or run test/setup_test.sh to provision a local test user. mysql said: ${err_text}"
    fi
    rm -f "${stderr_file}"
}

require_table() {
    local db="$1"
    local table="$2"
    local found
    found="$(sql_scalar "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${db}' AND table_name='${table}'")"
    assert_eq "1" "${found}" "table ${db}.${table} existence check"
}

require_column() {
    local db="$1"
    local table="$2"
    local col="$3"
    local found
    found="$(sql_scalar "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='${db}' AND table_name='${table}' AND column_name='${col}'")"
    assert_eq "1" "${found}" "column ${db}.${table}.${col} existence check"
}

result_orig_id=""
result_general_id=""
msg_orig_id=""
msg_general_id=""
test_appid=""

host_id=""
user_id=""
team_id=""

host_total=""
host_expavg=""
host_time=""
user_total=""
user_expavg=""
user_time=""
team_total=""
team_expavg=""
team_time=""

cleanup() {
    if [[ "${KEEP_FIXTURES}" == "1" ]]; then
        return
    fi
    set +e
    if [[ -n "${msg_orig_id}" ]]; then
        sql_exec "DELETE FROM \`${EXPT_DB}\`.\`trickle\` WHERE msghostid=${msg_orig_id}"
        sql_exec "DELETE FROM \`${MAIN_DB}\`.\`msg_from_host\` WHERE id=${msg_orig_id}"
    fi
    if [[ -n "${msg_general_id}" ]]; then
        sql_exec "DELETE FROM \`${EXPT_DB}\`.\`trickle\` WHERE msghostid=${msg_general_id}"
        sql_exec "DELETE FROM \`${MAIN_DB}\`.\`msg_from_host\` WHERE id=${msg_general_id}"
    fi
    if [[ -n "${result_orig_id}" ]]; then
        sql_exec "DELETE FROM \`${MAIN_DB}\`.\`result\` WHERE id=${result_orig_id}"
    fi
    if [[ -n "${result_general_id}" ]]; then
        sql_exec "DELETE FROM \`${MAIN_DB}\`.\`result\` WHERE id=${result_general_id}"
    fi
    if [[ -n "${test_appid}" ]]; then
        sql_exec "DELETE FROM \`${EXPT_DB}\`.\`model\` WHERE modelid=${test_appid}"
    fi
    if [[ -n "${host_id}" && -n "${host_total}" && -n "${host_expavg}" && -n "${host_time}" ]]; then
        sql_exec "UPDATE \`${MAIN_DB}\`.\`host\` SET total_credit='${host_total}', expavg_credit='${host_expavg}', expavg_time='${host_time}' WHERE id=${host_id}"
    fi
    if [[ -n "${user_id}" && -n "${user_total}" && -n "${user_expavg}" && -n "${user_time}" ]]; then
        sql_exec "UPDATE \`${MAIN_DB}\`.\`user\` SET total_credit='${user_total}', expavg_credit='${user_expavg}', expavg_time='${user_time}' WHERE id=${user_id}"
    fi
    if [[ -n "${team_id}" && "${team_id}" != "0" && -n "${team_total}" && -n "${team_expavg}" && -n "${team_time}" ]]; then
        sql_exec "UPDATE \`${MAIN_DB}\`.\`team\` SET total_credit='${team_total}', expavg_credit='${team_expavg}', expavg_time='${team_time}' WHERE id=${team_id}"
    fi
    if [[ "${generated_config_xml}" == "1" ]]; then
        rm -f "${config_xml_path}"
    fi
    if [[ "${generated_cgi_bin}" == "1" ]]; then
        rmdir "${cgi_bin_path}" 2>/dev/null || true
    fi
}

trap cleanup EXIT

assert_db_access

require_table "${MAIN_DB}" "result"
require_table "${MAIN_DB}" "host"
require_table "${MAIN_DB}" "user"
require_table "${MAIN_DB}" "team"
require_table "${MAIN_DB}" "msg_from_host"
require_table "${EXPT_DB}" "model"
require_table "${EXPT_DB}" "trickle"

require_column "${MAIN_DB}" "msg_from_host" "variety"
require_column "${EXPT_DB}" "trickle" "data"

if [[ -z "${TEMPLATE_RESULT_ID}" ]]; then
    TEMPLATE_RESULT_ID="$(sql_scalar "SELECT id FROM \`${MAIN_DB}\`.\`result\` WHERE hostid>0 AND userid>0 LIMIT 1")"
fi
if [[ -z "${TEMPLATE_RESULT_ID}" ]]; then
    fail "No template result found; set CPDN_TEMPLATE_RESULT_ID to a valid result ID"
fi

run_tag="$(date +%s)_${RANDOM}"
orig_result_name="orig_${run_tag}"
general_result_name="general_${run_tag}"

clone_result() {
    local src_id="$1"
    local new_name="$2"
    local new_name_sql
    new_name_sql="$(sql_escape "${new_name}")"
    sql_scalar "
        SET @cols = (
            SELECT GROUP_CONCAT(CONCAT('\`', COLUMN_NAME, '\`') ORDER BY ORDINAL_POSITION)
            FROM information_schema.columns
            WHERE table_schema='${MAIN_DB}' AND table_name='result' AND column_name<>'id' AND column_name<>'name'
        );
        SET @q = CONCAT(
            'INSERT INTO \`${MAIN_DB}\`.\`result\` (\`name\`, ', @cols, ') ',
            'SELECT ''${new_name_sql}'', ', @cols, ' FROM \`${MAIN_DB}\`.\`result\` WHERE id=${src_id} LIMIT 1'
        );
        PREPARE stmt FROM @q;
        EXECUTE stmt;
        DEALLOCATE PREPARE stmt;
        SELECT LAST_INSERT_ID();
    "
}

result_orig_id="$(clone_result "${TEMPLATE_RESULT_ID}" "${orig_result_name}")"
result_general_id="$(clone_result "${TEMPLATE_RESULT_ID}" "${general_result_name}")"
if [[ -z "${result_orig_id}" || -z "${result_general_id}" ]]; then
    fail "Unable to clone template result rows"
fi

host_id="$(sql_scalar "SELECT hostid FROM \`${MAIN_DB}\`.\`result\` WHERE id=${result_orig_id}")"
if [[ -z "${host_id}" || "${host_id}" == "0" ]]; then
    fail "Template result does not have a valid hostid"
fi

user_id="$(sql_scalar "SELECT userid FROM \`${MAIN_DB}\`.\`host\` WHERE id=${host_id}")"
if [[ -z "${user_id}" || "${user_id}" == "0" ]]; then
    fail "Host ${host_id} does not have a valid userid"
fi

team_id="$(sql_scalar "SELECT COALESCE(teamid,0) FROM \`${MAIN_DB}\`.\`user\` WHERE id=${user_id}")"

IFS=$'\t' read -r host_total host_expavg host_time <<< "$(sql_scalar "SELECT total_credit, expavg_credit, expavg_time FROM \`${MAIN_DB}\`.\`host\` WHERE id=${host_id}")"
IFS=$'\t' read -r user_total user_expavg user_time <<< "$(sql_scalar "SELECT total_credit, expavg_credit, expavg_time FROM \`${MAIN_DB}\`.\`user\` WHERE id=${user_id}")"
if [[ "${team_id}" != "0" ]]; then
    IFS=$'\t' read -r team_total team_expavg team_time <<< "$(sql_scalar "SELECT total_credit, expavg_credit, expavg_time FROM \`${MAIN_DB}\`.\`team\` WHERE id=${team_id}")"
fi

if [[ -n "${CPDN_TEST_APPID:-}" ]]; then
    test_appid="${CPDN_TEST_APPID}"
else
    for candidate in $(seq 1 99); do
        if [[ "${candidate}" == "30" ]]; then
            continue
        fi
        exists="$(sql_scalar "SELECT COUNT(*) FROM \`${EXPT_DB}\`.\`model\` WHERE modelid=${candidate}")"
        if [[ "${exists}" == "0" ]]; then
            test_appid="${candidate}"
            break
        fi
    done
fi
if [[ -z "${test_appid}" ]]; then
    fail "Unable to choose a unique test appid"
fi

exists="$(sql_scalar "SELECT COUNT(*) FROM \`${EXPT_DB}\`.\`model\` WHERE modelid=${test_appid}")"
if [[ "${exists}" != "0" ]]; then
    fail "Requested test appid (${test_appid}) already exists in ${EXPT_DB}.model"
fi

sql_exec "
    INSERT INTO \`${EXPT_DB}\`.\`model\`
    (modelid, description, phase, timestep, workunit, archive, benchmark, timestep_per_year, credit_per_timestep, boinc_name, trickle_timestep)
    VALUES
    (${test_appid}, 'test model', 0, 0, 0, '', 0, 1, ${MODEL_CPT}, 'test', 1)
"

sql_exec "
    UPDATE \`${MAIN_DB}\`.\`result\`
    SET appid=${test_appid}, granted_credit=0, claimed_credit=0, opaque=0, app_version_num=0
    WHERE id=${result_orig_id}
"
sql_exec "
    UPDATE \`${MAIN_DB}\`.\`result\`
    SET appid=${test_appid}, granted_credit=0, claimed_credit=0, opaque=0, app_version_num=0
    WHERE id=${result_general_id}
"

now_epoch="$(date +%s)"

xml_orig="<result_name>${orig_result_name}</result_name><ph>${TRICKLE_PHASE}</ph><data></data><ts>${TRICKLE_TS}</ts><cp>${TRICKLE_CP}</cp><vr>${TRICKLE_VR}</vr>"
xml_general="<result_name>${general_result_name}</result_name><ph>${TRICKLE_PHASE}</ph><data>${TRICKLE_DATA}</data><ts>${TRICKLE_TS}</ts><cp>${TRICKLE_CP}</cp><vr>${TRICKLE_VR}</vr>"
xml_orig_sql="$(sql_escape "${xml_orig}")"
xml_general_sql="$(sql_escape "${xml_general}")"

msg_orig_id="$(sql_scalar "
    INSERT INTO \`${MAIN_DB}\`.\`msg_from_host\` (create_time, hostid, variety, handled, xml)
    VALUES (${now_epoch}, ${host_id}, 'orig', 0, '${xml_orig_sql}');
    SELECT LAST_INSERT_ID();
")"

msg_general_id="$(sql_scalar "
    INSERT INTO \`${MAIN_DB}\`.\`msg_from_host\` (create_time, hostid, variety, handled, xml)
    VALUES (${now_epoch}, ${host_id}, 'general', 0, '${xml_general_sql}');
    SELECT LAST_INSERT_ID();
")"

if [[ -z "${msg_orig_id}" || -z "${msg_general_id}" ]]; then
    fail "Unable to insert msg_from_host rows for test"
fi

echo "Running cpdn_credit test with msg IDs ${msg_orig_id}/${msg_general_id}"
( cd "${RUN_DIR}" && "${BIN_PATH}" --one_pass )

handled_orig="$(sql_scalar "SELECT handled FROM \`${MAIN_DB}\`.\`msg_from_host\` WHERE id=${msg_orig_id}")"
handled_general="$(sql_scalar "SELECT handled FROM \`${MAIN_DB}\`.\`msg_from_host\` WHERE id=${msg_general_id}")"
assert_eq "1" "${handled_orig}" "orig message handled flag"
assert_eq "1" "${handled_general}" "general message handled flag"

credit_expected="$(awk -v ts="${TRICKLE_TS}" -v cpt="${MODEL_CPT}" 'BEGIN { printf "%.12f", ts*cpt*1.09 }')"
credit_orig="$(sql_scalar "SELECT granted_credit FROM \`${MAIN_DB}\`.\`result\` WHERE id=${result_orig_id}")"
credit_general="$(sql_scalar "SELECT granted_credit FROM \`${MAIN_DB}\`.\`result\` WHERE id=${result_general_id}")"
assert_float_close "${credit_orig}" "${credit_expected}" "0.000001" "orig granted_credit"
assert_float_close "${credit_general}" "${credit_expected}" "0.000001" "general granted_credit"
assert_float_close "${credit_orig}" "${credit_general}" "0.000001" "orig/general credit parity"

trickle_orig_count="$(sql_scalar "SELECT COUNT(*) FROM \`${EXPT_DB}\`.\`trickle\` WHERE msghostid=${msg_orig_id}")"
trickle_general_count="$(sql_scalar "SELECT COUNT(*) FROM \`${EXPT_DB}\`.\`trickle\` WHERE msghostid=${msg_general_id}")"
assert_eq "1" "${trickle_orig_count}" "orig trickle row count"
assert_eq "1" "${trickle_general_count}" "general trickle row count"

orig_data_is_null="$(sql_scalar "SELECT IF(data IS NULL, 1, 0) FROM \`${EXPT_DB}\`.\`trickle\` WHERE msghostid=${msg_orig_id} ORDER BY trickleid DESC LIMIT 1")"
general_data_value="$(sql_scalar "SELECT COALESCE(data, '__NULL__') FROM \`${EXPT_DB}\`.\`trickle\` WHERE msghostid=${msg_general_id} ORDER BY trickleid DESC LIMIT 1")"
assert_eq "1" "${orig_data_is_null}" "orig trickle data should be NULL"
assert_eq "${TRICKLE_DATA}" "${general_data_value}" "general trickle data value"

IFS=$'\t' read -r orig_phase orig_ts orig_cp <<< "$(sql_scalar "SELECT COALESCE(phase,0), COALESCE(timestep,0), COALESCE(cputime,0) FROM \`${EXPT_DB}\`.\`trickle\` WHERE msghostid=${msg_orig_id} ORDER BY trickleid DESC LIMIT 1")"
IFS=$'\t' read -r general_phase general_ts general_cp <<< "$(sql_scalar "SELECT COALESCE(phase,0), COALESCE(timestep,0), COALESCE(cputime,0) FROM \`${EXPT_DB}\`.\`trickle\` WHERE msghostid=${msg_general_id} ORDER BY trickleid DESC LIMIT 1")"
assert_eq "${TRICKLE_PHASE}" "${orig_phase}" "orig trickle phase"
assert_eq "${TRICKLE_TS}" "${orig_ts}" "orig trickle timestep"
assert_eq "${TRICKLE_CP}" "${orig_cp}" "orig trickle cputime"
assert_eq "${TRICKLE_PHASE}" "${general_phase}" "general trickle phase"
assert_eq "${TRICKLE_TS}" "${general_ts}" "general trickle timestep"
assert_eq "${TRICKLE_CP}" "${general_cp}" "general trickle cputime"

post_host_total="$(sql_scalar "SELECT total_credit FROM \`${MAIN_DB}\`.\`host\` WHERE id=${host_id}")"
post_user_total="$(sql_scalar "SELECT total_credit FROM \`${MAIN_DB}\`.\`user\` WHERE id=${user_id}")"
if ! is_greater "${post_host_total}" "${host_total}"; then
    if [[ "${ASSERT_HOST_USER_TEAM}" == "1" ]]; then
        fail "host.total_credit did not increase"
    fi
    warn "host.total_credit did not increase"
fi
if ! is_greater "${post_user_total}" "${user_total}"; then
    if [[ "${ASSERT_HOST_USER_TEAM}" == "1" ]]; then
        fail "user.total_credit did not increase"
    fi
    warn "user.total_credit did not increase"
fi

if [[ "${team_id}" != "0" ]]; then
    post_team_total="$(sql_scalar "SELECT total_credit FROM \`${MAIN_DB}\`.\`team\` WHERE id=${team_id}")"
    if ! is_greater "${post_team_total}" "${team_total}"; then
        if [[ "${ASSERT_HOST_USER_TEAM}" == "1" ]]; then
            fail "team.total_credit did not increase"
        fi
        warn "team.total_credit did not increase"
    fi
fi

echo "test passed"
