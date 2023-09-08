// credit-granting script for CPDN
//
// This script uses two (otherwise unused) fields of the result table:
// opaque: time the last trickle was handled
// app_version_num: # timesteps at last trickle

#include "parse.h"
#include "util.h"
#include "boinc_db.h"
#include "credit.h"
#include "cpdn_trickle_handler.h"
#include "cpdn_db.h"
#include "cpdn_credit.h"

DB_MODEL g_dbModel[MAX_MODELS];
char strDB[64];
char strExpt[64];
double total_credit = 0;
double credit = 0;

int lookup(const int resultid);
void db_parse(MYSQL_ROW &r);
int credit_grant(DB_HOST &host, double start_time, double credit);
int insert_trickle(MSG_FROM_HOST &msg,TRICKLE_MSG &trickle_msg,DB_RESULT &result);

// Do CPDN-specific initialization.
// Namely, open the experiment DB and read the models.
//
int handle_trickle_init(int argc, char** argv) {
    char strQuery[32];
    int retval;

    // SUBSITUTE IN NAMES OF DATABASES HERE
    if (!strcmp(config.db_name, "NAME_OF_MAIN_DATABASE")) {
      // production database
      strcpy(strDB, "MAIN_DATABASE");
      strcpy(strExpt, "EXPERIMENT_DATABASE");
    } else if (!strcmp(config.db_name, "NAME_OF_MAIN_TEST_DATABASE")) {
      // second test site database
      strcpy(strDB, "MAIN_DATABASE");
      strcpy(strExpt, "EXPERIMENT_DATABASE");
    } else {
      // first test site database
      strcpy(strDB, "MAIN_DATABASE");
      strcpy(strExpt, "EXPERIMENT_DATABASE");
    }

    log_messages.printf(MSG_NORMAL,"Main database is: %s\n", strDB);
    log_messages.printf(MSG_NORMAL,"Expt database is: %s\n", strExpt);

    retval = cpdn_db.open(
      strExpt, config.db_host, config.db_user, config.db_passwd
    );
    if (retval) {
      log_messages.printf(MSG_CRITICAL,
        "Can't open experiment DB %s!\n", strExpt
      );
      return retval;
    }
    log_messages.printf(MSG_NORMAL, "Experiment DB opened.\n");

    // read models
    bool bModel = false;
    for (int i = 1; i < MAX_MODELS; i++) {
      sprintf(strQuery, "WHERE modelid=%d", i);
      g_dbModel[i].clear();
      g_dbModel[i].lookup(strQuery);
      if (g_dbModel[i].modelid) {
        bModel = true;
        log_messages.printf(MSG_NORMAL,
          "Loaded info for: modelid=%d,credit_per_timestep=%1.6f,timestep_per_year=%d,boinc_name=%s,trickle_timestep=%d\n",
          g_dbModel[i].modelid, g_dbModel[i].credit_per_timestep, g_dbModel[i].timestep_per_year,
          g_dbModel[i].boinc_name, g_dbModel[i].trickle_timestep
        );
      }
    }
    if (!bModel) {
      log_messages.printf(MSG_CRITICAL,
        "No models found -- please check your expt database model table!\n"
      );
      return -1;
    }
    
    return 0;
}

int handle_trickle(MSG_FROM_HOST& msg) {
    DB_HOST host;
    TRICKLE_MSG trickle_msg;
    MIOFILE mf;
    char buf[256];
    double incremental_credit = 0;

    int retval = host.lookup_id(msg.hostid);
    if (retval) {
      log_messages.printf(MSG_NORMAL,
        "Message %ld: can't find host %ld\n", msg.id, msg.hostid
      );
      return retval;
    }

    mf.init_buf_read(msg.xml);
    XML_PARSER xp(&mf);
    retval = trickle_msg.parse(xp);
    if (retval) {
      log_messages.printf(MSG_NORMAL,
        "Message %ld: can't parse message %s\n", msg.id, msg.xml
      );
      return retval;
    }

    // find the result
    DB_RESULT result;
    sprintf(buf, "where name='%s'", trickle_msg.result_name);
    retval = result.lookup(buf);
    if (retval) {
      log_messages.printf(MSG_NORMAL,
        "Message %ld: can't find result %s\n", msg.id,
        trickle_msg.result_name
      );
      return retval;
    }

    DB_MODEL& model = g_dbModel[result.appid];

    log_messages.printf(MSG_NORMAL,
      "appid: %ld, Credit per timestep: %1.6f\n", result.appid, model.credit_per_timestep
    );

    if (trickle_msg.nsteps > MAX_STEPS_PER_TRICKLE) {
      log_messages.printf(MSG_NORMAL,
        "Message %ld: too many timesteps %d\n", msg.id, trickle_msg.nsteps
      );
    } else if (trickle_msg.nsteps < 0) {
      log_messages.printf(MSG_NORMAL,
        "Message %ld: timesteps<0 %d\n", msg.id, trickle_msg.nsteps
      );
    } else {
      credit = trickle_msg.nsteps * model.credit_per_timestep;

      log_messages.printf(MSG_NORMAL,
        "result_id=%d, credit=%1.6f, trickle_step_number=%ld, credit_per_timestep=%1.6f\n", result.id, credit, trickle_msg.nsteps, model.credit_per_timestep
      );

      double start_time;
      // the time of the previous trickle
      // is stored in result.opaque
      if (result.opaque) {
        start_time = result.opaque;
      } else {
        start_time = result.sent_time;
      }

      log_messages.printf(MSG_NORMAL,
        "Start time: %f\n", start_time
      );

      // Calculate the incremental credit to add to the host, user and team credits
      // The additional factor of 9% was tuned to match as much as possible the previous credit system
      incremental_credit = (labs(credit - result.granted_credit)) * 1.09;
      credit = credit * 1.09;

      log_messages.printf(MSG_NORMAL,
        "result_id=%ld, host_id=%ld, incremental_credit=%1.6f\n", result.id, host.id, incremental_credit
      );

      // update the host, user and team total_credit values
      retval = credit_grant(host, start_time, incremental_credit);
      if (retval) {
        log_messages.printf(MSG_CRITICAL,
          "Update of host and user for result ID: %ld failed, error code: %s\n", result.id, boincerror(retval)
        );
      }

      // update the result granted_credit and claimed_credit values
      sprintf(
        buf, "granted_credit=%f,claimed_credit=%f",
        credit,credit
      );

      retval = result.update_field(buf);
      if (retval) {
        log_messages.printf(MSG_CRITICAL,
          "Update of result %lu failed: %s\n",
          result.id, boincerror(retval)
        );
      }

      // Insert details of the trickle into the trickle table
      retval = insert_trickle(msg,trickle_msg,result);
      if (retval) {
        log_messages.printf(MSG_CRITICAL,
          "Insertion of trickle %ld into trickle table failed: %s\n",
          msg.id, boincerror(retval)
        );
      }        
    }

    // update opaque and app_version_num fields in result
    sprintf(buf, "opaque=%f, app_version_num=%d", dtime(), trickle_msg.nsteps);
    retval = result.update_field(buf);
    if (retval) {
      log_messages.printf(MSG_CRITICAL,
        "Message %ld: result updated failed: %s\n", msg.id, boincerror(retval)
      );
    }
    return 0;
}

bool handle_wah2_darwin_workunits() {
    DB_RESULT result;
    char buf[256];
    int retval;

    log_messages.printf(MSG_NORMAL, "Now in handle_wah2_darwin_workunits\n");

    // find completed WAH2 workunits that have been run on a Darwin machine and do not have credit awarded
    sprintf(buf, "where outcome = 1 and granted_credit = 0 and appid = 30");
    while (1) {
        //log_messages.printf(MSG_NORMAL, "Now in handle_wah2_darwin_workunits loop\n");
        retval = result.enumerate(buf);
        if (retval) {
            if (retval != ERR_DB_NOT_FOUND) {
                fprintf(stderr, "lost DB conn\n");
                exit(1);
            }
            break;
        }
        retval = calc_wah2_darwin_credit(result);
        if (retval) {
            log_messages.printf(MSG_CRITICAL,
                "calc_wah2_darwin_credit(): %s\n", boincerror(retval)
            );
        }
    }
    return 0;
}

bool calc_wah2_darwin_credit(DB_RESULT& result) {
    DB_HOST host;
    char buf[256];

    log_messages.printf(MSG_NORMAL,
      "Looking up host ID %ld\n", result.hostid);

    // Lookup host
    host.clear();
    int retval = host.lookup_id(result.hostid);
    if (retval) {
      log_messages.printf(MSG_NORMAL,
        "Result ID %ld: can't find host ID %ld\n", result.id, result.hostid
      );
      return retval;
    }

    log_messages.printf(MSG_NORMAL,
      "Looking up result ID %ld: with host ID %ld\n", result.id, result.hostid);

    total_credit = 0;
    retval = lookup(result.id);

    if (retval) {
      log_messages.printf(MSG_CRITICAL,
        "Result ID %ld: result lookup failed, error code: %s\n", result.id, boincerror(retval)
      );
    }
    
    // Apply correction factor of 9%
    credit = total_credit * 1.09;

    log_messages.printf(MSG_NORMAL,
      "Awarding %f: to host ID %ld\n", credit, result.hostid);

    // update the result granted_credit and claimed_credit values
    sprintf(
      buf, "granted_credit=%f,claimed_credit=%f",
      credit,credit
    );

    retval = result.update_field(buf);
    if (retval) {
      log_messages.printf(MSG_CRITICAL,
        "Update of result %lu failed: %s\n",
        result.id, boincerror(retval)
      );
    }

    // update the host, user and team total_credit values   
    retval = credit_grant(host, result.sent_time, credit);
    
    if (retval) {
      log_messages.printf(MSG_CRITICAL,
        "Update of host and user for result ID: %ld failed, error code: %s\n", result.id, boincerror(retval)
      );
    }
    return 0;
}

int credit_grant(DB_HOST &host, double start_time, double credit) {
    DB_USER user;
    DB_TEAM team;
    int retval;
    char buf[256];
    double now = dtime();

    log_messages.printf(MSG_NORMAL,
      "Awarding (inside credit_grant) %f\n", credit);

    // first, process the host
    update_average(
      now,
      start_time, credit, CREDIT_HALF_LIFE,
      host.expavg_credit, host.expavg_time
    );

    host.total_credit += credit;

    // update the host total_credit value
    sprintf(
      buf, "total_credit=%f",
      host.total_credit
    );

    retval = host.update_field(buf);
    if (retval) {
      log_messages.printf(MSG_CRITICAL,
        "Update of host %lu failed: %s\n",
        host.id, boincerror(retval)
      );
    }

    // update the user total_credit value
    user.clear();
    retval = user.lookup_id(host.userid);
    if (retval) {
      log_messages.printf(MSG_CRITICAL,
        "Lookup of user %lu failed: %s\n",
        host.userid, boincerror(retval)
      );
      return retval;
    }

    update_average(
      now,
      start_time, credit, CREDIT_HALF_LIFE,
      user.expavg_credit, user.expavg_time
    );

    sprintf(
      buf, "total_credit=total_credit+%f, expavg_credit=%.15e, expavg_time=%.15e",
      credit,  user.expavg_credit, user.expavg_time
    );

    retval = user.update_field(buf);
    if (retval) {
      log_messages.printf(MSG_CRITICAL,
        "Update of user %lu failed: %s\n",
        host.userid, boincerror(retval)
      );
    }


    // update the team total_credit value
    if (user.teamid) {
      team.clear();
      retval = team.lookup_id(user.teamid);
      if (retval) {
        log_messages.printf(MSG_CRITICAL,
          "Lookup of team %lu failed: %s\n",
          user.teamid, boincerror(retval)
        );
        return retval;
      }
      update_average(
        now,
        start_time, credit, CREDIT_HALF_LIFE,
        team.expavg_credit, team.expavg_time
      );
      sprintf(buf,
        "total_credit=total_credit+%f, expavg_credit=%.15e, expavg_time=%.15e",
        credit,  team.expavg_credit, team.expavg_time
      );
      retval = team.update_field(buf);
      if (retval) {
        log_messages.printf(MSG_CRITICAL,
          "Update of team %lu failed: %s\n",
          team.id, boincerror(retval)
        );
      }
    }
    return 0;
}

int lookup(const int resultid) {
    char query[512];
    int retval;
    MYSQL_ROW row;
    MYSQL_RES* rp;

    // lookup all Darwin workunits and calculate credit
    // based on the number of upload files 
    
    // SUBSITUTE IN BATCH_TABLE AND WORKUNIT_TABLE NAMES
    sprintf(query,
      "select 761.548*(cb.ul_files-1) "
      "from %s.result r, %s.host h, %s.WORKUNIT_TABLE cw, %s.BATCH_TABLE cb "
      "where r.id=%d and r.hostid=h.id and h.os_name='Darwin' and "
      "r.workunitid=cw.wuid and cw.BATCH_TABLE=cb.id",
      strDB,strDB,strExpt,strExpt,resultid
    );

    retval = cpdn_db.do_query(query);
    if (retval) return retval;
    rp = mysql_store_result(cpdn_db.mysql);
    if (!rp) return -1;
    row = mysql_fetch_row(rp);
    if (row) db_parse(row);
    mysql_free_result(rp);
    if (row == 0) return -2;
    return 0;
}

void db_parse(MYSQL_ROW &r) {
    int i=0;
    total_credit = atof(r[i++]);
}

int insert_trickle(MSG_FROM_HOST &msg,TRICKLE_MSG &trickle_msg,DB_RESULT &result) {
  char query[512];
  int retval;

  //log_messages.printf(MSG_NORMAL,"Database: %s\n",strExpt);
  //log_messages.printf(MSG_NORMAL,"Trickle id: %d\n",msg.id);
  //log_messages.printf(MSG_NORMAL,"User id: %d\n",result.userid);
  //log_messages.printf(MSG_NORMAL,"Host id: %d\n",msg.hostid);
  //log_messages.printf(MSG_NORMAL,"result.id: %d\n",result.id);
  //log_messages.printf(MSG_NORMAL,"workunit id: %d\n",result.workunitid);
  //log_messages.printf(MSG_NORMAL,"Phase: %d\n",trickle_msg.phase);
  //log_messages.printf(MSG_NORMAL,"Number of trickle steps: %d\n",trickle_msg.nsteps);
  //log_messages.printf(MSG_NORMAL,"cputime: %d\n",trickle_msg.cputime);
  //log_messages.printf(MSG_NORMAL,"Create time: %d\n",msg.create_time);

  // Insert new details of trickle into trickle table
  sprintf(query,
   "insert into %s.trickle"
   "(msghostid,userid,hostid,resultid,workunitid,phase,"
   "timestep,cputime,clientdate,trickledate,ipaddr) "
   "values(%d,%d,%d,%d,%d,%d,%d,%d,%d,unix_timestamp(),'')",
   strExpt, msg.id, result.userid, msg.hostid,
   result.id, result.workunitid, trickle_msg.phase,
   trickle_msg.nsteps, trickle_msg.cputime, msg.create_time
  );    

  log_messages.printf(MSG_NORMAL,"Inserting into trickle table: %s\n",query);
  retval = cpdn_db.do_query(query);
  if (retval) return retval;
  return 0;
}
