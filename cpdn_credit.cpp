// credit-granting script for CPDN
//
// This script uses two (otherwise unused) fields of the result table:
// opaque: time the last trickle was handled
// app_version_num: # timesteps at last trickle.
//
// Modified by Glenn Carver, CPDN, March 2026.
//   Added a new trickle variety "general" that allows clients to send
//   arbitrary data in a new field "data" of the trickle message.
//   This data is stored in the trickle table if it is not empty
//   and does not contain control characters. The data is stored
//   as a string up to 512 characters long. If the data is not stored,
//   a NULL value is stored in the database for that trickle message.
//
//   The aim of this new 'data' field is provide small packets of
//   data from the models for plotting on the CPDN website. This could
//   be used to show the 'spread' of the model results across the batch.

// BOINC headers
#include "lib/parse.h"
#include "lib/str_util.h"
#include "lib/util.h"
#include "db/boinc_db.h"
#include "sched/credit.h"

#include "cpdn_trickle_handler.h"
#include "cpdn_db.h"
#include "cpdn_credit.h"
#include <cctype>
#include <iomanip>
#include <sstream>
#include "math.h"

DB_MODEL g_dbModel[kMaxModels];
std::string g_main_db_name;
std::string g_expt_db_name;
double total_credit = 0;
double credit = 0;

int lookup(const int resultid);
void db_parse(MYSQL_ROW &r);
int credit_grant(DB_HOST &host, double start_time, double credit);
int insert_trickle(MSG_FROM_HOST &msg, TRICKLE_MSG &trickle_msg, DB_RESULT &result);

static bool should_store_trickle_data(MSG_FROM_HOST &msg, TRICKLE_MSG &trickle_msg)
{
    if (strcmp(msg.variety, "general"))
    {
        return false;
    }
    if (!trickle_msg.data[0])
    {
        return false;
    }
    for (size_t i = 0; trickle_msg.data[i]; i++)
    {
        if (iscntrl(static_cast<unsigned char>(trickle_msg.data[i])))
        {
            return false;
        }
    }
    return true;
}

static std::string escape_sql_string(const char *value)
{
    size_t input_len = value ? strlen(value) : 0;
    std::vector<char> buffer(input_len * 2 + 1, '\0');

    if (value && input_len)
    {
        strlcpy(buffer.data(), value, buffer.size());
        escape_string(buffer.data(), buffer.size());
    }

    return std::string(buffer.data());
}

static std::string quote_sql_string(const char *value)
{
    return "'" + escape_sql_string(value) + "'";
}

static std::string format_sql_double(double value, int precision = 15)
{
    std::ostringstream stream;
    stream << std::setprecision(precision) << value;
    return stream.str();
}

// Do CPDN-specific initialization.
// Namely, open the experiment DB and read the models.
//
int handle_trickle_init(int argc, char **argv)
{
    int retval;

    if (!strcmp(config.db_name, "cpdnboinc"))
    {
        // production database
        g_main_db_name = "cpdnboinc";
        g_expt_db_name = "cpdnexpt";
    }
    else if (!strcmp(config.db_name, "cpdnboinc_dev"))
    {
        // development database
        g_main_db_name = "cpdnboinc_dev";
        g_expt_db_name = "cpdnexpt_dev";
    }
    else
    {
        // alpha test site database
        g_main_db_name = "cpdnboinc_alpha";
        g_expt_db_name = "cpdnexpt_alpha";
    }

    log_messages.printf(MSG_NORMAL, "Main database is: %s\n", g_main_db_name.c_str());
    log_messages.printf(MSG_NORMAL, "Expt database is: %s\n", g_expt_db_name.c_str());

    std::vector<char> expt_db_name(g_expt_db_name.begin(), g_expt_db_name.end());
    expt_db_name.push_back('\0');
    retval = cpdn_db.open(expt_db_name.data(), config.db_host, config.db_user, config.db_passwd);
    if (retval)
    {
        log_messages.printf(MSG_CRITICAL, "Can't open experiment DB %s!\n", g_expt_db_name.c_str());
        return retval;
    }
    log_messages.printf(MSG_NORMAL, "Experiment DB opened.\n");

    // read models
    bool bModel = false;
    for (int i = kFirstModelId; i < kMaxModels; i++)
    {
        std::ostringstream query;
        query << "WHERE modelid=" << i;
        g_dbModel[i].clear();
        g_dbModel[i].lookup(query.str().c_str());
        if (g_dbModel[i].modelid)
        {
            bModel = true;
            log_messages.printf(MSG_NORMAL,
                                "Loaded info for: modelid=%d,credit_per_timestep=%1.6f,timestep_per_year=%d,boinc_name=%s,trickle_timestep=%d\n",
                                g_dbModel[i].modelid, g_dbModel[i].credit_per_timestep, g_dbModel[i].timestep_per_year,
                                g_dbModel[i].boinc_name, g_dbModel[i].trickle_timestep);
        }
    }
    if (!bModel)
    {
        log_messages.printf(MSG_CRITICAL, "No models found -- please check your expt database model table!\n");
        return -1;
    }

    return 0;
}

int handle_trickle(MSG_FROM_HOST &msg)
{
    DB_HOST host;
    TRICKLE_MSG trickle_msg;
    MIOFILE mf;
    double incremental_credit = 0;

    int retval = host.lookup_id(msg.hostid);
    if (retval)
    {
        log_messages.printf(MSG_NORMAL, "Message %ld: can't find host %ld\n", msg.id, msg.hostid);
        return retval;
    }

    mf.init_buf_read(msg.xml);
    XML_PARSER xp(&mf);
    retval = trickle_msg.parse(xp);
    if (retval)
    {
        log_messages.printf(MSG_NORMAL, "Message %ld: can't parse message %s\n", msg.id, msg.xml);
        return retval;
    }

    // find the result
    DB_RESULT result;
    std::string lookup_clause = "where name=" + quote_sql_string(trickle_msg.result_name);
    retval = result.lookup(lookup_clause.c_str());
    if (retval)
    {
        log_messages.printf(MSG_NORMAL,
                            "Message %ld: can't find result %s\n", msg.id, trickle_msg.result_name);
        return retval;
    }

    DB_MODEL &model = g_dbModel[result.appid];

    log_messages.printf(MSG_NORMAL,
                        "appid: %ld, Credit per timestep: %1.6f\n", result.appid, model.credit_per_timestep);

    if (trickle_msg.nsteps > kMaxStepsPerTrickle)
    {
        log_messages.printf(MSG_NORMAL,
                            "Message %ld: too many timesteps %d\n", msg.id, trickle_msg.nsteps);
    }
    else if (trickle_msg.nsteps < 0)
    {
        log_messages.printf(MSG_NORMAL,
                            "Message %ld: timesteps<0 %d\n", msg.id, trickle_msg.nsteps);
    }
    else
    {
        credit = trickle_msg.nsteps * model.credit_per_timestep;

        log_messages.printf(MSG_NORMAL,
                            "result_id=%ld, credit=%1.6f, trickle_step_number=%d, credit_per_timestep=%1.6f\n",
                            result.id, credit, trickle_msg.nsteps, model.credit_per_timestep);

        double start_time;
        // the time of the previous trickle
        // can be stored in result.opaque
        if (result.opaque)
        {
            start_time = result.opaque;
        }
        else
        {
            start_time = result.sent_time;
        }

        log_messages.printf(MSG_NORMAL, "Start time: %f\n", start_time);

        // Calculate the incremental credit to add to the host, user and team credits
        // The additional factor of 9% was tuned to match as much as possible the previous credit system
        log_messages.printf(MSG_NORMAL, "credit: %f, result.granted_credit %f\n", credit, result.granted_credit);
        credit = credit * 1.09;
        incremental_credit = fabs(credit - result.granted_credit);

        log_messages.printf(MSG_NORMAL,
                            "result_id=%ld, host_id=%ld, incremental_credit=%1.6f\n", result.id, host.id, incremental_credit);

        // update the host, user and team total_credit values
        retval = credit_grant(host, start_time, incremental_credit);
        if (retval)
        {
            log_messages.printf(MSG_CRITICAL,
                                "Update of host and user for result ID: %ld failed, error code: %s\n", result.id, boincerror(retval));
        }

        // update the result granted_credit and claimed_credit values
        std::ostringstream result_credit_update;
        result_credit_update << "granted_credit=" << format_sql_double(credit)
                             << ",claimed_credit=" << format_sql_double(credit);

        retval = result.update_field(result_credit_update.str().c_str());
        if (retval)
        {
            log_messages.printf(MSG_CRITICAL,
                                "Update of result %lu failed: %s\n", result.id, boincerror(retval));
        }

        // Insert details of the trickle into the trickle table
        retval = insert_trickle(msg, trickle_msg, result);
        if (retval)
        {
            log_messages.printf(MSG_CRITICAL,
                                "Insertion of trickle %ld into trickle table failed: %s\n",
                                msg.id, boincerror(retval));
        }
    }

    // update opaque and app_version_num fields in result
    std::ostringstream result_progress_update;
    result_progress_update << "opaque=" << format_sql_double(dtime())
                           << ", app_version_num=" << trickle_msg.nsteps;
    retval = result.update_field(result_progress_update.str().c_str());
    if (retval)
    {
        log_messages.printf(MSG_CRITICAL,
                            "Message %ld: result updated failed: %s\n", msg.id, boincerror(retval));
    }
    return 0;
}

bool handle_wah2_darwin_workunits()
{
    DB_RESULT result;
    int retval;

    // find completed WAH2 workunits that have been run on a Darwin machine and do not have credit awarded
    const std::string where_clause = "where outcome = 1 and granted_credit = 0 and appid = 30";
    while (1)
    {
        retval = result.enumerate(where_clause.c_str());
        if (retval)
        {
            if (retval != ERR_DB_NOT_FOUND)
            {
                fprintf(stderr, "lost DB conn\n");
                exit(1);
            }
            break;
        }
        retval = calc_wah2_darwin_credit(result);
        if (retval)
        {
            log_messages.printf(MSG_CRITICAL,
                                "calc_wah2_darwin_credit(): %s\n", boincerror(retval));
        }
    }
    return 0;
}

bool calc_wah2_darwin_credit(DB_RESULT &result)
{
    DB_HOST host;

    log_messages.printf(MSG_NORMAL, "Looking up host ID %ld\n", result.hostid);

    // Lookup host
    host.clear();
    int retval = host.lookup_id(result.hostid);
    if (retval)
    {
        log_messages.printf(MSG_NORMAL, "Result ID %ld: can't find host ID %ld\n", result.id, result.hostid);
        return retval;
    }

    log_messages.printf(MSG_NORMAL, "Looking up result ID %ld: with host ID %ld\n", result.id, result.hostid);

    total_credit = 0;
    retval = lookup(result.id);

    if (retval)
    {
        log_messages.printf(MSG_NORMAL, "Result ID %ld: result lookup failed not a macOS host\n", result.id);
    }

    // Apply correction factor of 9%
    credit = total_credit * 1.09;

    log_messages.printf(MSG_NORMAL, "Awarding %f: to host ID %ld\n", credit, result.hostid);

    // update the result granted_credit and claimed_credit values
    std::ostringstream result_credit_update;
    result_credit_update << "granted_credit=" << format_sql_double(credit)
                         << ",claimed_credit=" << format_sql_double(credit);

    retval = result.update_field(result_credit_update.str().c_str());
    if (retval)
    {
        log_messages.printf(MSG_CRITICAL,
                            "Update of result %lu failed: %s\n", result.id, boincerror(retval));
    }

    // update the host, user and team total_credit values
    retval = credit_grant(host, result.sent_time, credit);

    if (retval)
    {
        log_messages.printf(MSG_CRITICAL,
                            "Update of host and user for result ID: %ld failed, error code: %s\n",
                            result.id, boincerror(retval));
    }
    return 0;
}

int credit_grant(DB_HOST &host, double start_time, double credit)
{
    DB_USER user;
    DB_TEAM team;
    int retval;
    double now = dtime();

    log_messages.printf(MSG_NORMAL, "Awarding (inside credit_grant) %f\n", credit);

    // first, process the host
    update_average(
        now,
        start_time, credit, CREDIT_HALF_LIFE,
        host.expavg_credit, host.expavg_time);

    host.total_credit += credit;

    // update the host total_credit value
    std::ostringstream host_update;
    host_update << "total_credit=" << format_sql_double(host.total_credit)
                << ", expavg_credit=" << format_sql_double(host.expavg_credit)
                << ", expavg_time=" << format_sql_double(host.expavg_time);

    retval = host.update_field(host_update.str().c_str());
    if (retval)
    {
        log_messages.printf(MSG_CRITICAL,
                            "Update of host %lu failed: %s\n", host.id, boincerror(retval));
    }

    // update the user total_credit value
    user.clear();
    retval = user.lookup_id(host.userid);
    if (retval)
    {
        log_messages.printf(MSG_CRITICAL,
                            "Lookup of user %lu failed: %s\n", host.userid, boincerror(retval));
        return retval;
    }

    update_average(
        now,
        start_time, credit, CREDIT_HALF_LIFE,
        user.expavg_credit, user.expavg_time);

    std::ostringstream user_update;
    user_update << "total_credit=total_credit+" << format_sql_double(credit)
                << ", expavg_credit=" << format_sql_double(user.expavg_credit)
                << ", expavg_time=" << format_sql_double(user.expavg_time);

    retval = user.update_field(user_update.str().c_str());
    if (retval)
    {
        log_messages.printf(MSG_CRITICAL,
                            "Update of user %lu failed: %s\n", host.userid, boincerror(retval));
    }

    // update the team total_credit value
    if (user.teamid)
    {
        team.clear();
        retval = team.lookup_id(user.teamid);
        if (retval)
        {
            log_messages.printf(MSG_CRITICAL,
                                "Lookup of team %lu failed: %s\n", user.teamid, boincerror(retval));
            return retval;
        }
        update_average(now, start_time, credit, CREDIT_HALF_LIFE,
                       team.expavg_credit, team.expavg_time);
        std::ostringstream team_update;
        team_update << "total_credit=total_credit+" << format_sql_double(credit)
                    << ", expavg_credit=" << format_sql_double(team.expavg_credit)
                    << ", expavg_time=" << format_sql_double(team.expavg_time);
        retval = team.update_field(team_update.str().c_str());
        if (retval)
        {
            log_messages.printf(MSG_CRITICAL,
                                "Update of team %lu failed: %s\n",
                                team.id, boincerror(retval));
        }
    }
    return 0;
}

int lookup(const int resultid)
{
    int retval;
    MYSQL_ROW row;
    MYSQL_RES *rp;

    // lookup all Darwin workunits and calculate credit
    // based on the number of upload files

    std::ostringstream query;
    query << "select 761.548*(cb.ul_files-1) "
          << "from " << g_main_db_name << ".result r, "
          << g_main_db_name << ".host h, "
          << g_expt_db_name << ".cpdn_workunit cw, "
          << g_expt_db_name << ".cpdn_batch cb "
          << "where r.id=" << resultid
          << " and r.hostid=h.id and h.os_name='Darwin' and "
          << "r.workunitid=cw.wuid and cw.cpdn_batch=cb.id";

    retval = cpdn_db.do_query(query.str().c_str());
    if (retval)
        return retval;
    rp = mysql_store_result(cpdn_db.mysql);
    if (!rp)
        return -1;
    row = mysql_fetch_row(rp);
    if (row)
        db_parse(row);
    mysql_free_result(rp);
    if (row == 0)
        return -2;
    return 0;
}

void db_parse(MYSQL_ROW &r)
{
    int i = 0;
    total_credit = atof(r[i++]);
}

int insert_trickle(MSG_FROM_HOST &msg, TRICKLE_MSG &trickle_msg, DB_RESULT &result)
{
    int retval;
    bool store_data = should_store_trickle_data(msg, trickle_msg);
    std::ostringstream query;

    if (store_data)
    {
        query << "insert into " << g_expt_db_name << ".trickle"
              << "(msghostid,userid,hostid,resultid,workunitid,phase,"
              << "timestep,cputime,clientdate,trickledate,ipaddr,data) "
              << "values(" << msg.id << "," << result.userid << "," << msg.hostid
              << "," << result.id << "," << result.workunitid << ","
              << trickle_msg.phase << "," << trickle_msg.nsteps << ","
              << trickle_msg.cputime << "," << msg.create_time
              << ",unix_timestamp(),'', " << quote_sql_string(trickle_msg.data) << ")";
    }
    else
    {
        query << "insert into " << g_expt_db_name << ".trickle"
              << "(msghostid,userid,hostid,resultid,workunitid,phase,"
              << "timestep,cputime,clientdate,trickledate,ipaddr,data) "
              << "values(" << msg.id << "," << result.userid << "," << msg.hostid
              << "," << result.id << "," << result.workunitid << ","
              << trickle_msg.phase << "," << trickle_msg.nsteps << ","
              << trickle_msg.cputime << "," << msg.create_time
              << ",unix_timestamp(),'', NULL)";
    }

    log_messages.printf(MSG_NORMAL, "Inserting into trickle table: %s\n", query.str().c_str());
    retval = cpdn_db.do_query(query.str().c_str());
    if (retval)
        return retval;
    return 0;
}
