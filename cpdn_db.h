// based off of boinc/db/boinc_db.h
// Included headers are from the boinc source directory.

#ifndef _CPDN_DB_
#define _CPDN_DB_

#include <cstddef>
#include <string.h>
#include <cstdio>
#include <vector>

// BOINC specific headers from boinc source directory
#include "db/db_base.h"

extern DB_CONN cpdn_db;

// Sizes of text buffers in memory, corresponding to database BLOBs.
// Large is for fields with user-supplied text, and preferences

#include "db/boinc_db.h"

#define LARGE_BLOB_SIZE APP_VERSION_XML_BLOB_SIZE

// Shared fixed-width text buffer sizes. Keep schema/protocol-aligned widths
// here where they exist, and keep legacy fixed buffers named in one place.
constexpr std::size_t kResultNameBufferSize = 256;
constexpr std::size_t kTrickleIpAddrBufferSize = 25;
constexpr std::size_t kTrickleDataBufferSize = 513;
constexpr std::size_t kModelDescriptionBufferSize = 129;
constexpr std::size_t kLegacyModelArchiveBufferSize = 20;
constexpr std::size_t kModelBoincNameBufferSize = 255;

// A compilation target, i.e. a architecture/OS combination.
// The core client will be given only applications with the same platform
//
struct TRICKLE
{
    int trickleid;
    int msghostid;
    int userid;
    int hostid;
    int resultid;
    int workunitid;
    int phase;
    int timestep;
    int cputime;
    int clientdate;
    int trickledate;
    char ipaddr[kTrickleIpAddrBufferSize];
    char data[kTrickleDataBufferSize];
    void clear();
};

// model information
struct MODEL
{
    int modelid;
    char description[kModelDescriptionBufferSize];
    int phase;
    int timestep;
    int workunit;
    char archive[kLegacyModelArchiveBufferSize];
    int benchmark;
    int timestep_per_year;
    float credit_per_timestep;
    char boinc_name[kModelBoincNameBufferSize];
    int trickle_timestep;
    void clear();
};

class DB_TRICKLE : public DB_BASE, public TRICKLE
{
public:
    DB_TRICKLE(DB_CONN *dc = 0);
    void db_print(char *buf);
    void db_parse(MYSQL_ROW &row);
};

class DB_MODEL : public DB_BASE, public MODEL
{
public:
    DB_MODEL(DB_CONN *dc = 0);
    void db_print(char *buf);
    void db_parse(MYSQL_ROW &row);
};

#endif
