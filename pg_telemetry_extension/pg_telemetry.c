#include "postgres.h"
#include "fmgr.h"
#include "executor/executor.h"
#include "tcop/utility.h"
#include "miscadmin.h"
#include "utils/builtins.h"
#include "commands/dbcommands.h"
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

PG_MODULE_MAGIC;

/* Presence of this file is the on/off switch for logging.
 * Created by logger.sh on "start", removed on "stop", so that
 * this extension can be started/stopped without restarting Postgres. */
#define CASCE_LOGGING_FLAG "/dataset_workspace/.casce_logging_active"

void _PG_init(void);
void _PG_fini(void);

static ExecutorStart_hook_type prev_ExecutorStart = NULL;
static ExecutorRun_hook_type prev_ExecutorRun = NULL;
static ExecutorFinish_hook_type prev_ExecutorFinish = NULL;
static ExecutorEnd_hook_type prev_ExecutorEnd = NULL;
static ProcessUtility_hook_type prev_ProcessUtility = NULL;

static void log_casce_event(const char* event_type, const char* query) {
    FILE *fp;
    char safe_query[2048] = {0};
    int i;
    const char* dbname = "unknown";
    const char* username = "unknown";

    if (!query) return;

    // Logging is toggled on/off by logger.sh via this flag file's presence.
    if (access(CASCE_LOGGING_FLAG, F_OK) != 0) return;

    // Open file to append structured event log for collector
    fp = fopen("/dataset_workspace/postgres_events.json", "a");
    if (!fp) return;
    
    // Very basic JSON escaping (replacing quotes/newlines)
    snprintf(safe_query, sizeof(safe_query)-1, "%s", query);
    for(i=0; safe_query[i]; i++) {
        if(safe_query[i] == '"' || safe_query[i] == '\n' || safe_query[i] == '\r' || safe_query[i] == '\\') 
            safe_query[i] = ' ';
    }

    dbname = get_database_name(MyDatabaseId);
    if (!dbname) dbname = "unknown";
    
    username = GetUserNameFromId(GetUserId(), true);
    if (!username) username = "unknown";

    fprintf(fp, "{\"session_id\": %d, \"backend_pid\": %d, \"timestamp\": %ld, \"event_type\": \"%s\", \"query\": \"%s\", \"database\": \"%s\", \"username\": \"%s\"}\n",
        MyProcPid, MyProcPid, (long)time(NULL), event_type, safe_query, dbname, username);
    fclose(fp);
}

static void casce_ExecutorStart(QueryDesc *queryDesc, int eflags) {
    if (queryDesc && queryDesc->sourceText) {
        log_casce_event("ExecutorStart", queryDesc->sourceText);
    }
    if (prev_ExecutorStart) prev_ExecutorStart(queryDesc, eflags);
    else standard_ExecutorStart(queryDesc, eflags);
}

static void casce_ExecutorRun(QueryDesc *queryDesc, ScanDirection direction, uint64 count, bool execute_once) {
    log_casce_event("ExecutorRun", queryDesc->sourceText);
    if (prev_ExecutorRun) prev_ExecutorRun(queryDesc, direction, count, execute_once);
    else standard_ExecutorRun(queryDesc, direction, count, execute_once);
}

static void casce_ExecutorFinish(QueryDesc *queryDesc) {
    log_casce_event("ExecutorFinish", queryDesc->sourceText);
    if (prev_ExecutorFinish) prev_ExecutorFinish(queryDesc);
    else standard_ExecutorFinish(queryDesc);
}

static void casce_ExecutorEnd(QueryDesc *queryDesc) {
    log_casce_event("ExecutorEnd", queryDesc->sourceText);
    if (prev_ExecutorEnd) prev_ExecutorEnd(queryDesc);
    else standard_ExecutorEnd(queryDesc);
}

static void casce_ProcessUtility(PlannedStmt *pstmt, const char *queryString,
#if PG_VERSION_NUM >= 140000
    bool readOnlyTree,
#endif
    ProcessUtilityContext context, ParamListInfo params, QueryEnvironment *queryEnv, DestReceiver *dest, QueryCompletion *qc) {
    
    log_casce_event("ProcessUtility", queryString);
    
    if (prev_ProcessUtility) {
#if PG_VERSION_NUM >= 140000
        prev_ProcessUtility(pstmt, queryString, readOnlyTree, context, params, queryEnv, dest, qc);
#else
        prev_ProcessUtility(pstmt, queryString, context, params, queryEnv, dest, qc);
#endif
    } else {
#if PG_VERSION_NUM >= 140000
        standard_ProcessUtility(pstmt, queryString, readOnlyTree, context, params, queryEnv, dest, qc);
#else
        standard_ProcessUtility(pstmt, queryString, context, params, queryEnv, dest, qc);
#endif
    }
}

void _PG_init(void) {
    prev_ExecutorStart = ExecutorStart_hook;
    ExecutorStart_hook = casce_ExecutorStart;
    
    prev_ExecutorRun = ExecutorRun_hook;
    ExecutorRun_hook = casce_ExecutorRun;
    
    prev_ExecutorFinish = ExecutorFinish_hook;
    ExecutorFinish_hook = casce_ExecutorFinish;
    
    prev_ExecutorEnd = ExecutorEnd_hook;
    ExecutorEnd_hook = casce_ExecutorEnd;
    
    prev_ProcessUtility = ProcessUtility_hook;
    ProcessUtility_hook = casce_ProcessUtility;
}

void _PG_fini(void) {
    ExecutorStart_hook = prev_ExecutorStart;
    ExecutorRun_hook = prev_ExecutorRun;
    ExecutorFinish_hook = prev_ExecutorFinish;
    ExecutorEnd_hook = prev_ExecutorEnd;
    ProcessUtility_hook = prev_ProcessUtility;
}
