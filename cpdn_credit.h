#include <cassert>
#include <cstdio>
#include <vector>
#include <string>
#include <time.h>
using namespace std;

#ifndef _MAX_PATH
   #define _MAX_PATH 512
#endif

// 100 models should be enough
#define MAX_MODELS 100

#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/time.h>
#include <sys/resource.h>

#include "../../db/boinc_db.h"
#include "../../lib/util.h"
#include "../../lib/parse.h"
#include "../../lib/filesys.h"
#include "../../sched/sched_config.h"
#include "../../lib/sched_msgs.h"
#include "../../sched/sched_util.h"
#include "cpdn_db.h"

#define MAX_STEPS_PER_TRICKLE 6000000

bool calc_wah2_darwin_credit(DB_RESULT& result);
bool calc_openifs_credit(DB_RESULT& result);

struct TRICKLE_MSG {
    int nsteps;
    char result_name[256];
    int parse(XML_PARSER& xp) {
      nsteps = -1;
      strcpy(result_name, "");
      while (!xp.get_tag()) {
        if (nsteps>=0 && strlen(result_name)) {
          return 0;
        }
        if (xp.parse_int("ts", nsteps)) continue;
        if (xp.parse_str("result_name", result_name, sizeof(result_name))) {
          continue;
        }
      }
      return -1;
    }
};
