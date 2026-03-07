#include "cpdn_db.h"
#include "lib/str_util.h"

DB_CONN cpdn_db;

#define ESCAPE(x) escape_string(x, sizeof(x))
#define UNESCAPE(x) unescape_string(x, sizeof(x))

DB_TRICKLE::DB_TRICKLE(DB_CONN* dc) :
    DB_BASE("trickle", dc ? dc : &cpdn_db)
{
}

void TRICKLE::clear()
{
   memset(this, 0x00, sizeof(TRICKLE));
}

void DB_TRICKLE::db_print(char* buf){
    // BOINC DB_BASE callers hand db_print() a buffer sized to MAX_QUERY_LEN
    // (or larger for insert()), so use that bound here rather than sprintf().
    ESCAPE(ipaddr);
    ESCAPE(data);
    if (data[0]) {
        snprintf(buf, MAX_QUERY_LEN,
            "trickleid=%d, msghostid=%d, userid=%d, "
            "hostid=%d, resultid=%d, workunitid=%d, "
            "phase=%d, timestep=%d, cputime=%d, "
            "clientdate=%d, trickledate=unix_timestamp(), ipaddr='%s', data='%s' ",
            trickleid, msghostid, userid,
            hostid, resultid, workunitid,
            phase, timestep, cputime,
            clientdate, ipaddr, data
        );
    } else {
        snprintf(buf, MAX_QUERY_LEN,
            "trickleid=%d, msghostid=%d, userid=%d, "
            "hostid=%d, resultid=%d, workunitid=%d, "
            "phase=%d, timestep=%d, cputime=%d, "
            "clientdate=%d, trickledate=unix_timestamp(), ipaddr='%s', data=NULL ",
            trickleid, msghostid, userid,
            hostid, resultid, workunitid,
            phase, timestep, cputime,
            clientdate, ipaddr
        );
    }
    UNESCAPE(ipaddr);
    UNESCAPE(data);
}

void DB_TRICKLE::db_parse(MYSQL_ROW &r) {
    int i=0;
    clear();
    trickleid = atol(r[i++]);
    msghostid = atol(r[i++]);
    userid = atol(r[i++]);
    hostid = atol(r[i++]);
    resultid = atol(r[i++]);
    workunitid = atol(r[i++]);
    phase = atol(r[i++]);
    timestep = atol(r[i++]);
    cputime = atol(r[i++]);
    clientdate = atol(r[i++]);
    trickledate = atol(r[i++]);
    if (r[i])
       strlcpy(ipaddr, r[i], sizeof(ipaddr));
    i++;
    if (r[i])
       strlcpy(data, r[i], sizeof(data));
}

void MODEL::clear()
{
   memset(this, 0x00, sizeof(MODEL));
}

DB_MODEL::DB_MODEL(DB_CONN* dc) :
    DB_BASE("model", dc ? dc : &cpdn_db)
{
}

void DB_MODEL::db_parse(MYSQL_ROW &r)
{
    int i=0;
    clear();
    modelid = atol(r[i++]);
    if (r[i]) {
        strlcpy(description, r[i], sizeof(description));
    }
    i++;
    phase = atol(r[i++]);
    timestep = atol(r[i++]);
    workunit = atol(r[i++]);
    //strcpy(archive, r[i++]);
    i++; // just increment, we never use archive!
    benchmark = atol(r[i++]);
    timestep_per_year = atol(r[i++]);
    credit_per_timestep = atof(r[i++]);
    if (r[i]) {
        strlcpy(boinc_name, r[i], sizeof(boinc_name));
    }
    i++;
    trickle_timestep = atol(r[i++]);
}

void DB_MODEL::db_print(char* buf)
{  // note archive isn't used
   // BOINC DB_BASE callers hand db_print() a buffer sized to MAX_QUERY_LEN
   // (or larger for insert()), so use that bound here rather than sprintf().
   ESCAPE(description);
   ESCAPE(boinc_name);
   snprintf(buf, MAX_QUERY_LEN,
    "modelid=%d, description='%s', "
    "phase=%d, timestep=%d, workunit=%d, "
    "benchmark=%d, "
    "timestep_per_year=%d, credit_per_timestep=%f, "
    "boinc_name='%s', trickle_timestep=%d ",
    modelid,
    description,
    phase,
    timestep,
    workunit,
    benchmark,
    timestep_per_year,
    credit_per_timestep,
    boinc_name,
    trickle_timestep
   );
   UNESCAPE(description);
   UNESCAPE(boinc_name);
}
