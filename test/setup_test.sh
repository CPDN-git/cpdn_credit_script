#!/usr/bin/env bash
# setup_test.sh provisions a local MySQL/MariaDB test account for the DB-backed
# cpdn_credit CTest. On Debian-style MariaDB installs it prefers `sudo mariadb`
# socket auth, otherwise it can use explicit admin credentials.
# If the target test DBs do not exist, it bootstraps a minimal local schema for
# the test. Existing databases are not dropped or rewritten.
#
# Typical use:
#   export CPDN_DB_USER=boinc
#   export CPDN_DB_PASS=testpass123   # choose a new local test password
#   ./test/setup_test.sh
#
# Optional:
#   export CPDN_SETUP_DB_ADMIN_MODE=tcp
#   export CPDN_SETUP_DB_ADMIN_USER=root
#   export CPDN_SETUP_DB_ADMIN_PASS=your_admin_password
#   ./test/setup_test.sh
#
# After setup completes, run:
#   ctest --test-dir build -R credit_varieties --output-on-failure
set -euo pipefail

fail() {
    echo "ERROR: $*" >&2
    exit 1
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

sql_escape() {
    printf "%s" "$1" | sed "s/'/''/g"
}

sql_ident_escape() {
    printf "%s" "$1" | sed 's/`/``/g'
}

xml_escape() {
    printf "%s" "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
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
            }
        }
    ' "${file_path}"
}

random_password() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 16
        return
    fi
    date +%s%N
}

MYSQL_CLIENT="$(find_mysql_client)"
if [[ -z "${MYSQL_CLIENT}" ]]; then
    fail "mysql/mariadb client not found in PATH"
fi

SUDO_BIN=""
if command -v sudo >/dev/null 2>&1; then
    SUDO_BIN="$(command -v sudo)"
fi

RUN_DIR="${CPDN_RUN_DIR:-$(pwd)}"
if [[ ! -d "${RUN_DIR}" ]]; then
    fail "CPDN_RUN_DIR is not a directory: ${RUN_DIR}"
fi

config_xml_path="${RUN_DIR}/config.xml"
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
GRANT_HOSTS_RAW="${CPDN_SETUP_DB_GRANT_HOSTS:-localhost,127.0.0.1}"
WRITE_CONFIG="${CPDN_SETUP_WRITE_CONFIG:-1}"
ADMIN_MODE="${CPDN_SETUP_DB_ADMIN_MODE:-auto}"

ADMIN_HOST="${CPDN_SETUP_DB_ADMIN_HOST:-${DB_HOST}}"
ADMIN_PORT="${CPDN_SETUP_DB_ADMIN_PORT:-${DB_PORT}}"
ADMIN_USER="${CPDN_SETUP_DB_ADMIN_USER:-}"
ADMIN_PASS="${CPDN_SETUP_DB_ADMIN_PASS:-}"
USE_SUDO_SOCKET=0
created_main_db=0
created_expt_db=0

if [[ -z "${DB_PASS}" ]]; then
    DB_PASS="$(random_password)"
    echo "Generated CPDN_DB_PASS for local test user ${DB_USER}"
fi

TARGET_ARGS=(-h "${DB_HOST}" -P "${DB_PORT}" -u "${DB_USER}")
if [[ -n "${DB_PASS}" ]]; then
    TARGET_ARGS+=(-p"${DB_PASS}")
fi

build_admin_command() {
    case "${ADMIN_MODE}" in
        auto)
            if [[ -n "${SUDO_BIN}" && -z "${ADMIN_USER}" && -z "${ADMIN_PASS}" ]]; then
                USE_SUDO_SOCKET=1
            fi
            ;;
        socket)
            USE_SUDO_SOCKET=1
            ;;
        tcp)
            USE_SUDO_SOCKET=0
            ;;
        *)
            fail "Unsupported CPDN_SETUP_DB_ADMIN_MODE '${ADMIN_MODE}'. Use auto, socket, or tcp."
            ;;
    esac

    if [[ "${USE_SUDO_SOCKET}" == "1" ]]; then
        if [[ -z "${SUDO_BIN}" ]]; then
            fail "CPDN_SETUP_DB_ADMIN_MODE=${ADMIN_MODE} requires sudo, but sudo is not installed"
        fi
        ADMIN_CMD=("${SUDO_BIN}" mariadb)
        return
    fi

    ADMIN_CMD=("${MYSQL_CLIENT}" -h "${ADMIN_HOST}" -P "${ADMIN_PORT}")
    if [[ -n "${ADMIN_USER}" ]]; then
        ADMIN_CMD+=(-u "${ADMIN_USER}")
    fi
    if [[ -n "${ADMIN_PASS}" ]]; then
        ADMIN_CMD+=(-p"${ADMIN_PASS}")
    fi
}

admin_sql_exec() {
    "${ADMIN_CMD[@]}" -e "$1"
}

admin_sql_scalar() {
    "${ADMIN_CMD[@]}" -N -B -e "$1"
}

assert_admin_access() {
    local stderr_file
    stderr_file="$(mktemp)"
    if ! "${ADMIN_CMD[@]}" -N -B -e "SELECT CURRENT_USER()" > /dev/null 2> "${stderr_file}"; then
        local err_text
        err_text="$(cat "${stderr_file}")"
        rm -f "${stderr_file}"
        if [[ "${USE_SUDO_SOCKET}" == "1" ]]; then
            fail "Unable to connect with sudo mariadb socket auth. Run the script from a sudo-capable shell, or set CPDN_SETUP_DB_ADMIN_MODE=tcp with CPDN_SETUP_DB_ADMIN_USER/CPDN_SETUP_DB_ADMIN_PASS. mysql said: ${err_text}"
        fi
        fail "Unable to connect with setup credentials. Set CPDN_SETUP_DB_ADMIN_USER/CPDN_SETUP_DB_ADMIN_PASS, or use the default sudo mariadb socket-auth path. mysql said: ${err_text}"
    fi
    rm -f "${stderr_file}"
}

require_database() {
    local db="$1"
    local found
    found="$(admin_sql_scalar "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='$(sql_escape "${db}")'")"
    if [[ "${found}" != "1" ]]; then
        fail "Database ${db} does not exist"
    fi
}

database_exists() {
    local db="$1"
    local found
    found="$(admin_sql_scalar "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='$(sql_escape "${db}")'")"
    [[ "${found}" == "1" ]]
}

table_exists() {
    local db="$1"
    local table="$2"
    local found
    found="$(admin_sql_scalar "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$(sql_escape "${db}")' AND table_name='$(sql_escape "${table}")'")"
    [[ "${found}" == "1" ]]
}

column_exists() {
    local db="$1"
    local table="$2"
    local column="$3"
    local found
    found="$(admin_sql_scalar "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='$(sql_escape "${db}")' AND table_name='$(sql_escape "${table}")' AND column_name='$(sql_escape "${column}")'")"
    [[ "${found}" == "1" ]]
}

create_database_if_missing() {
    local db="$1"
    local ident
    ident="$(sql_ident_escape "${db}")"
    if database_exists "${db}"; then
        return 1
    fi
    admin_sql_exec "CREATE DATABASE \`${ident}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci"
    return 0
}

create_main_schema() {
    local db_ident
    local now_epoch
    db_ident="$(sql_ident_escape "${MAIN_DB}")"
    now_epoch="$(date +%s)"

    admin_sql_exec "
        CREATE TABLE \`${db_ident}\`.\`team\` (
            \`id\` BIGINT NOT NULL AUTO_INCREMENT,
            \`create_time\` INT NOT NULL DEFAULT 0,
            \`userid\` BIGINT NOT NULL DEFAULT 0,
            \`name\` VARCHAR(255) NOT NULL DEFAULT '',
            \`name_lc\` VARCHAR(255) NOT NULL DEFAULT '',
            \`url\` VARCHAR(255) NOT NULL DEFAULT '',
            \`type\` INT NOT NULL DEFAULT 0,
            \`name_html\` VARCHAR(255) NOT NULL DEFAULT '',
            \`description\` TEXT NULL,
            \`nusers\` INT NOT NULL DEFAULT 0,
            \`country\` VARCHAR(64) NOT NULL DEFAULT '',
            \`total_credit\` DOUBLE NOT NULL DEFAULT 0,
            \`expavg_credit\` DOUBLE NOT NULL DEFAULT 0,
            \`expavg_time\` DOUBLE NOT NULL DEFAULT 0,
            \`seti_id\` INT NOT NULL DEFAULT 0,
            \`ping_user\` INT NOT NULL DEFAULT 0,
            \`ping_time\` INT NOT NULL DEFAULT 0,
            PRIMARY KEY (\`id\`)
        )
    "

    admin_sql_exec "
        CREATE TABLE \`${db_ident}\`.\`user\` (
            \`id\` BIGINT NOT NULL AUTO_INCREMENT,
            \`create_time\` INT NOT NULL DEFAULT 0,
            \`email_addr\` VARCHAR(255) NOT NULL DEFAULT '',
            \`name\` VARCHAR(255) NOT NULL DEFAULT '',
            \`authenticator\` VARCHAR(255) NOT NULL DEFAULT '',
            \`country\` VARCHAR(64) NOT NULL DEFAULT '',
            \`postal_code\` VARCHAR(64) NOT NULL DEFAULT '',
            \`total_credit\` DOUBLE NOT NULL DEFAULT 0,
            \`expavg_credit\` DOUBLE NOT NULL DEFAULT 0,
            \`expavg_time\` DOUBLE NOT NULL DEFAULT 0,
            \`global_prefs\` TEXT NULL,
            \`project_prefs\` TEXT NULL,
            \`teamid\` BIGINT NOT NULL DEFAULT 0,
            \`venue\` VARCHAR(255) NOT NULL DEFAULT '',
            \`url\` VARCHAR(255) NOT NULL DEFAULT '',
            \`send_email\` INT NOT NULL DEFAULT 0,
            \`show_hosts\` INT NOT NULL DEFAULT 0,
            \`posts\` INT NOT NULL DEFAULT 0,
            \`seti_id\` INT NOT NULL DEFAULT 0,
            \`seti_nresults\` INT NOT NULL DEFAULT 0,
            \`seti_last_result_time\` INT NOT NULL DEFAULT 0,
            \`seti_total_cpu\` DOUBLE NOT NULL DEFAULT 0,
            \`signature\` TEXT NULL,
            \`has_profile\` INT NOT NULL DEFAULT 0,
            \`cross_project_id\` VARCHAR(255) NOT NULL DEFAULT '',
            \`passwd_hash\` VARCHAR(255) NOT NULL DEFAULT '',
            \`email_validated\` INT NOT NULL DEFAULT 0,
            \`donated\` INT NOT NULL DEFAULT 0,
            \`login_token\` VARCHAR(255) NOT NULL DEFAULT '',
            \`login_token_time\` DOUBLE NOT NULL DEFAULT 0,
            \`previous_email_addr\` VARCHAR(255) NOT NULL DEFAULT '',
            \`email_addr_change_time\` DOUBLE NOT NULL DEFAULT 0,
            PRIMARY KEY (\`id\`)
        )
    "

    admin_sql_exec "
        CREATE TABLE \`${db_ident}\`.\`host\` (
            \`id\` BIGINT NOT NULL AUTO_INCREMENT,
            \`create_time\` INT NOT NULL DEFAULT 0,
            \`userid\` BIGINT NOT NULL DEFAULT 0,
            \`rpc_seqno\` INT NOT NULL DEFAULT 0,
            \`rpc_time\` INT NOT NULL DEFAULT 0,
            \`total_credit\` DOUBLE NOT NULL DEFAULT 0,
            \`expavg_credit\` DOUBLE NOT NULL DEFAULT 0,
            \`expavg_time\` DOUBLE NOT NULL DEFAULT 0,
            \`timezone\` INT NOT NULL DEFAULT 0,
            \`domain_name\` VARCHAR(255) NOT NULL DEFAULT '',
            \`serialnum\` VARCHAR(255) NOT NULL DEFAULT '',
            \`last_ip_addr\` VARCHAR(64) NOT NULL DEFAULT '',
            \`nsame_ip_addr\` INT NOT NULL DEFAULT 0,
            \`on_frac\` DOUBLE NOT NULL DEFAULT 0,
            \`connected_frac\` DOUBLE NOT NULL DEFAULT 0,
            \`active_frac\` DOUBLE NOT NULL DEFAULT 0,
            \`cpu_efficiency\` DOUBLE NOT NULL DEFAULT 0,
            \`duration_correction_factor\` DOUBLE NOT NULL DEFAULT 0,
            \`p_ncpus\` INT NOT NULL DEFAULT 0,
            \`p_vendor\` VARCHAR(255) NOT NULL DEFAULT '',
            \`p_model\` VARCHAR(255) NOT NULL DEFAULT '',
            \`p_fpops\` DOUBLE NOT NULL DEFAULT 0,
            \`p_iops\` DOUBLE NOT NULL DEFAULT 0,
            \`p_membw\` DOUBLE NOT NULL DEFAULT 0,
            \`os_name\` VARCHAR(255) NOT NULL DEFAULT '',
            \`os_version\` VARCHAR(255) NOT NULL DEFAULT '',
            \`m_nbytes\` DOUBLE NOT NULL DEFAULT 0,
            \`m_cache\` DOUBLE NOT NULL DEFAULT 0,
            \`m_swap\` DOUBLE NOT NULL DEFAULT 0,
            \`d_total\` DOUBLE NOT NULL DEFAULT 0,
            \`d_free\` DOUBLE NOT NULL DEFAULT 0,
            \`d_boinc_used_total\` DOUBLE NOT NULL DEFAULT 0,
            \`d_boinc_used_project\` DOUBLE NOT NULL DEFAULT 0,
            \`d_boinc_max\` DOUBLE NOT NULL DEFAULT 0,
            \`n_bwup\` DOUBLE NOT NULL DEFAULT 0,
            \`n_bwdown\` DOUBLE NOT NULL DEFAULT 0,
            \`credit_per_cpu_sec\` DOUBLE NOT NULL DEFAULT 0,
            \`venue\` VARCHAR(255) NOT NULL DEFAULT '',
            \`nresults_today\` INT NOT NULL DEFAULT 0,
            \`avg_turnaround\` DOUBLE NOT NULL DEFAULT 0,
            \`host_cpid\` VARCHAR(255) NOT NULL DEFAULT '',
            \`external_ip_addr\` VARCHAR(64) NOT NULL DEFAULT '',
            \`max_results_day\` INT NOT NULL DEFAULT 0,
            \`error_rate\` DOUBLE NOT NULL DEFAULT 0,
            \`product_name\` VARCHAR(255) NOT NULL DEFAULT '',
            \`gpu_active_frac\` DOUBLE NOT NULL DEFAULT 0,
            PRIMARY KEY (\`id\`)
        )
    "

    admin_sql_exec "
        CREATE TABLE \`${db_ident}\`.\`result\` (
            \`id\` BIGINT NOT NULL AUTO_INCREMENT,
            \`create_time\` INT NOT NULL DEFAULT 0,
            \`workunitid\` BIGINT NOT NULL DEFAULT 0,
            \`server_state\` INT NOT NULL DEFAULT 0,
            \`outcome\` INT NOT NULL DEFAULT 0,
            \`client_state\` INT NOT NULL DEFAULT 0,
            \`hostid\` BIGINT NOT NULL DEFAULT 0,
            \`userid\` BIGINT NOT NULL DEFAULT 0,
            \`report_deadline\` INT NOT NULL DEFAULT 0,
            \`sent_time\` INT NOT NULL DEFAULT 0,
            \`received_time\` INT NOT NULL DEFAULT 0,
            \`name\` VARCHAR(255) NOT NULL DEFAULT '',
            \`cpu_time\` DOUBLE NOT NULL DEFAULT 0,
            \`xml_doc_in\` TEXT NULL,
            \`xml_doc_out\` TEXT NULL,
            \`stderr_out\` TEXT NULL,
            \`batch\` INT NOT NULL DEFAULT 0,
            \`file_delete_state\` INT NOT NULL DEFAULT 0,
            \`validate_state\` INT NOT NULL DEFAULT 0,
            \`claimed_credit\` DOUBLE NOT NULL DEFAULT 0,
            \`granted_credit\` DOUBLE NOT NULL DEFAULT 0,
            \`opaque\` DOUBLE NOT NULL DEFAULT 0,
            \`random\` INT NOT NULL DEFAULT 0,
            \`app_version_num\` INT NOT NULL DEFAULT 0,
            \`appid\` BIGINT NOT NULL DEFAULT 0,
            \`exit_status\` INT NOT NULL DEFAULT 0,
            \`teamid\` BIGINT NOT NULL DEFAULT 0,
            \`priority\` INT NOT NULL DEFAULT 0,
            \`mod_time\` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            \`elapsed_time\` DOUBLE NOT NULL DEFAULT 0,
            \`flops_estimate\` DOUBLE NOT NULL DEFAULT 0,
            \`app_version_id\` BIGINT NOT NULL DEFAULT 0,
            \`runtime_outlier\` INT NOT NULL DEFAULT 0,
            \`size_class\` INT NOT NULL DEFAULT 0,
            \`peak_working_set_size\` DOUBLE NOT NULL DEFAULT 0,
            \`peak_swap_size\` DOUBLE NOT NULL DEFAULT 0,
            \`peak_disk_usage\` DOUBLE NOT NULL DEFAULT 0,
            PRIMARY KEY (\`id\`),
            UNIQUE KEY \`result_name_uq\` (\`name\`)
        )
    "

    admin_sql_exec "
        CREATE TABLE \`${db_ident}\`.\`msg_from_host\` (
            \`id\` BIGINT NOT NULL AUTO_INCREMENT,
            \`create_time\` INT NOT NULL DEFAULT 0,
            \`hostid\` BIGINT NOT NULL DEFAULT 0,
            \`variety\` VARCHAR(255) NOT NULL DEFAULT '',
            \`handled\` TINYINT(1) NOT NULL DEFAULT 0,
            \`xml\` TEXT NULL,
            PRIMARY KEY (\`id\`)
        )
    "

    admin_sql_exec "
        INSERT INTO \`${db_ident}\`.\`team\`
            (\`id\`, \`create_time\`, \`userid\`, \`name\`, \`name_lc\`, \`url\`, \`type\`, \`name_html\`, \`description\`, \`nusers\`, \`country\`, \`total_credit\`, \`expavg_credit\`, \`expavg_time\`, \`seti_id\`, \`ping_user\`, \`ping_time\`)
        VALUES
            (1, ${now_epoch}, 1, 'Test Team', 'test team', '', 0, 'Test Team', 'Local CTest team', 1, 'GB', 0, 0, 0, 0, 0, 0)
    "

    admin_sql_exec "
        INSERT INTO \`${db_ident}\`.\`user\`
            (\`id\`, \`create_time\`, \`email_addr\`, \`name\`, \`authenticator\`, \`country\`, \`postal_code\`, \`total_credit\`, \`expavg_credit\`, \`expavg_time\`, \`global_prefs\`, \`project_prefs\`, \`teamid\`, \`venue\`, \`url\`, \`send_email\`, \`show_hosts\`, \`posts\`, \`seti_id\`, \`seti_nresults\`, \`seti_last_result_time\`, \`seti_total_cpu\`, \`signature\`, \`has_profile\`, \`cross_project_id\`, \`passwd_hash\`, \`email_validated\`, \`donated\`, \`login_token\`, \`login_token_time\`, \`previous_email_addr\`, \`email_addr_change_time\`)
        VALUES
            (1, ${now_epoch}, 'local-test@example.invalid', 'Local Test User', 'local-auth', 'GB', '', 0, 0, 0, '', '', 1, '', '', 0, 1, 0, 0, 0, 0, 0, '', 0, 'local-cpid', 'local-passwd', 1, 0, '', 0, '', 0)
    "

    admin_sql_exec "
        INSERT INTO \`${db_ident}\`.\`host\`
            (\`id\`, \`create_time\`, \`userid\`, \`rpc_seqno\`, \`rpc_time\`, \`total_credit\`, \`expavg_credit\`, \`expavg_time\`, \`timezone\`, \`domain_name\`, \`serialnum\`, \`last_ip_addr\`, \`nsame_ip_addr\`, \`on_frac\`, \`connected_frac\`, \`active_frac\`, \`cpu_efficiency\`, \`duration_correction_factor\`, \`p_ncpus\`, \`p_vendor\`, \`p_model\`, \`p_fpops\`, \`p_iops\`, \`p_membw\`, \`os_name\`, \`os_version\`, \`m_nbytes\`, \`m_cache\`, \`m_swap\`, \`d_total\`, \`d_free\`, \`d_boinc_used_total\`, \`d_boinc_used_project\`, \`d_boinc_max\`, \`n_bwup\`, \`n_bwdown\`, \`credit_per_cpu_sec\`, \`venue\`, \`nresults_today\`, \`avg_turnaround\`, \`host_cpid\`, \`external_ip_addr\`, \`max_results_day\`, \`error_rate\`, \`product_name\`, \`gpu_active_frac\`)
        VALUES
            (1, ${now_epoch}, 1, 0, 0, 0, 0, 0, 0, 'localhost', 'local-serial', '127.0.0.1', 1, 1, 1, 1, 1, 1, 1, 'Generic', 'Local Test Host', 1, 1, 1, 'Linux', 'local', 1, 1, 1, 1, 1, 0, 0, 1, 1, 1, 0, '', 0, 0, 'local-host-cpid', '127.0.0.1', 0, 0, 'Local Test Machine', 0)
    "

    admin_sql_exec "
        INSERT INTO \`${db_ident}\`.\`result\`
            (\`id\`, \`create_time\`, \`workunitid\`, \`server_state\`, \`outcome\`, \`client_state\`, \`hostid\`, \`userid\`, \`report_deadline\`, \`sent_time\`, \`received_time\`, \`name\`, \`cpu_time\`, \`xml_doc_in\`, \`xml_doc_out\`, \`stderr_out\`, \`batch\`, \`file_delete_state\`, \`validate_state\`, \`claimed_credit\`, \`granted_credit\`, \`opaque\`, \`random\`, \`app_version_num\`, \`appid\`, \`exit_status\`, \`teamid\`, \`priority\`, \`mod_time\`, \`elapsed_time\`, \`flops_estimate\`, \`app_version_id\`, \`runtime_outlier\`, \`size_class\`, \`peak_working_set_size\`, \`peak_swap_size\`, \`peak_disk_usage\`)
        VALUES
            (1, ${now_epoch}, 1, 0, 0, 0, 1, 1, ${now_epoch}, ${now_epoch}, 0, 'template_seed_result', 0, '', '', '', 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, NOW(), 0, 0, 0, 0, 0, 0, 0, 0)
    "
}

create_expt_schema() {
    local db_ident
    db_ident="$(sql_ident_escape "${EXPT_DB}")"

    admin_sql_exec "
        CREATE TABLE \`${db_ident}\`.\`model\` (
            \`modelid\` INT NOT NULL,
            \`description\` VARCHAR(128) NOT NULL DEFAULT '',
            \`phase\` INT NOT NULL DEFAULT 0,
            \`timestep\` INT NOT NULL DEFAULT 0,
            \`workunit\` INT NOT NULL DEFAULT 0,
            \`archive\` BLOB NULL,
            \`benchmark\` INT NOT NULL DEFAULT 0,
            \`timestep_per_year\` INT NOT NULL DEFAULT 0,
            \`credit_per_timestep\` DOUBLE NOT NULL DEFAULT 0,
            \`boinc_name\` VARCHAR(254) NULL,
            \`trickle_timestep\` INT NOT NULL DEFAULT 0,
            PRIMARY KEY (\`modelid\`)
        )
    "

    admin_sql_exec "
        CREATE TABLE \`${db_ident}\`.\`trickle\` (
            \`trickleid\` BIGINT NOT NULL AUTO_INCREMENT,
            \`msghostid\` BIGINT NOT NULL DEFAULT 0,
            \`userid\` BIGINT NOT NULL DEFAULT 0,
            \`hostid\` BIGINT NOT NULL DEFAULT 0,
            \`resultid\` BIGINT NOT NULL DEFAULT 0,
            \`workunitid\` BIGINT NOT NULL DEFAULT 0,
            \`phase\` INT DEFAULT 0,
            \`timestep\` INT DEFAULT 0,
            \`cputime\` INT DEFAULT 0,
            \`clientdate\` INT DEFAULT 0,
            \`trickledate\` INT DEFAULT 0,
            \`ipaddr\` VARCHAR(24) NULL,
            \`data\` VARCHAR(512) NULL,
            PRIMARY KEY (\`trickleid\`)
        )
    "
}

assert_existing_db_shape() {
    if database_exists "${MAIN_DB}"; then
        for table_name in result host user team msg_from_host; do
            if ! table_exists "${MAIN_DB}" "${table_name}"; then
                fail "Database ${MAIN_DB} already exists but is missing required table ${table_name}. Existing databases are left untouched; use a fresh test DB name or fix the schema manually."
            fi
        done
    fi

    if database_exists "${EXPT_DB}"; then
        for table_name in model trickle; do
            if ! table_exists "${EXPT_DB}" "${table_name}"; then
                fail "Database ${EXPT_DB} already exists but is missing required table ${table_name}. Existing databases are left untouched; use a fresh test DB name or fix the schema manually."
            fi
        done
        if ! column_exists "${EXPT_DB}" "trickle" "data"; then
            fail "Database ${EXPT_DB} already exists but ${EXPT_DB}.trickle is missing column data. Existing databases are left untouched; add the column manually or use a fresh test DB name."
        fi
    fi
}

assert_target_access() {
    local stderr_file
    stderr_file="$(mktemp)"
    if ! "${MYSQL_CLIENT}" "${TARGET_ARGS[@]}" -N -B -e "SELECT 1" > /dev/null 2> "${stderr_file}"; then
        local err_text
        err_text="$(cat "${stderr_file}")"
        rm -f "${stderr_file}"
        fail "Created/granted user '${DB_USER}' but login still failed. This usually means an existing account has a different auth plugin or password. Either drop/reset that user manually, or rerun setup with a different CPDN_DB_USER. mysql said: ${err_text}"
    fi
    rm -f "${stderr_file}"
}

write_config_xml() {
    local db_name_xml db_host_xml db_user_xml db_pass_xml
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
    echo "Wrote ${config_xml_path} with local test DB credentials"
}

build_admin_command
assert_admin_access

assert_existing_db_shape

if create_database_if_missing "${MAIN_DB}"; then
    created_main_db=1
    create_main_schema
fi

if create_database_if_missing "${EXPT_DB}"; then
    created_expt_db=1
    create_expt_schema
fi

require_database "${MAIN_DB}"
require_database "${EXPT_DB}"

IFS=',' read -r -a grant_hosts <<< "${GRANT_HOSTS_RAW}"
for grant_host in "${grant_hosts[@]}"; do
    grant_host="$(trim "${grant_host}")"
    [[ -z "${grant_host}" ]] && continue

    user_sql="$(sql_escape "${DB_USER}")"
    pass_sql="$(sql_escape "${DB_PASS}")"
    host_sql="$(sql_escape "${grant_host}")"
    main_db_sql="$(sql_escape "${MAIN_DB}")"
    expt_db_sql="$(sql_escape "${EXPT_DB}")"

    admin_sql_exec "CREATE USER IF NOT EXISTS '${user_sql}'@'${host_sql}' IDENTIFIED BY '${pass_sql}'"
    admin_sql_exec "ALTER USER '${user_sql}'@'${host_sql}' IDENTIFIED BY '${pass_sql}'"
    admin_sql_exec "GRANT SELECT, INSERT, UPDATE, DELETE ON \`${main_db_sql}\`.* TO '${user_sql}'@'${host_sql}'"
    admin_sql_exec "GRANT SELECT, INSERT, UPDATE, DELETE ON \`${expt_db_sql}\`.* TO '${user_sql}'@'${host_sql}'"
done

admin_sql_exec "FLUSH PRIVILEGES"
assert_target_access

if [[ "${WRITE_CONFIG}" == "1" ]]; then
    write_config_xml
fi

if [[ "${created_main_db}" == "1" ]]; then
    echo "Bootstrapped local main test database ${MAIN_DB}"
fi
if [[ "${created_expt_db}" == "1" ]]; then
    echo "Bootstrapped local experiment test database ${EXPT_DB}"
fi
echo "Local DB test user is ready"
echo "export CPDN_DB_USER=${DB_USER}"
echo "export CPDN_DB_PASS=${DB_PASS}"
echo "export CPDN_DB_HOST=${DB_HOST}"
echo "export CPDN_DB_PORT=${DB_PORT}"
echo "export CPDN_MAIN_DB=${MAIN_DB}"
echo "export CPDN_EXPT_DB=${EXPT_DB}"
