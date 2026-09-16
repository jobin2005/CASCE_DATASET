#include "postgres.h"
#include "fmgr.h"
#include "executor/executor.h"
#include "tcop/utility.h"
#include "miscadmin.h"
#include "utils/builtins.h"
#include "utils/guc.h"
#include "commands/dbcommands.h"
#include "libpq/libpq-be.h"
#include "storage/ipc.h"
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>

PG_MODULE_MAGIC;

/* Simulated-identity overrides. When the attack workload sets these via
 * `SET casce.sim_user = '...'` / `SET casce.sim_ip = '...'` at the start of
 * a session, the dataset generator can drive exactly which synthetic
 * username/IP shows up in postgres_events.json for that session, instead of
 * relying on the PID-derived fallback below. Left NULL/empty, behavior is
 * unchanged. */
static char *casce_sim_user = NULL;
static char *casce_sim_ip = NULL;

/* Presence of this file is the on/off switch for logging.
 * Created by logger.sh on "start", removed on "stop", so that
 * this extension can be started/stopped without restarting Postgres. */
#define CASCE_LOGGING_FLAG "/dataset_workspace/.casce_logging_active"

void _PG_init(void);
void _PG_fini(void);

static ExecutorStart_hook_type prev_ExecutorStart = NULL;

static ExecutorEnd_hook_type prev_ExecutorEnd = NULL;
static ProcessUtility_hook_type prev_ProcessUtility = NULL;

static long cached_session_start_time = 0;

static void log_casce_event(const char* event_type, const char* query) {
    int fd;
    char safe_query[2048] = {0};
    int i;
    const char* dbname = "unknown";
    const char* username = "unknown";
    const char* client_addr = "local";
    const char* client_port = "0";

    if (!query) return;

    // Logging is toggled on/off by logger.sh via this flag file's presence.
    if (access(CASCE_LOGGING_FLAG, F_OK) != 0) return;

    // Open file to append structured event log for collector
    fd = open("/dataset_workspace/postgres_events.json", O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (fd < 0) return;
    
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
    
    const char *spoofed_users[] = {"db_admin", "analyst_bob", "service_alice", "dev_charlie", "postgres"};
    if (strcmp(username, "postgres") == 0) {
        username = spoofed_users[MyProcPid % 5];
    }
    
    if (MyProcPort && MyProcPort->remote_host) client_addr = MyProcPort->remote_host;
    if (MyProcPort && MyProcPort->remote_port) client_port = MyProcPort->remote_port;

    char spoofed_ip[32];
    char spoofed_port[16];
    if (strcmp(client_addr, "[local]") == 0) {
        snprintf(spoofed_ip, sizeof(spoofed_ip), "192.168.1.%d", (MyProcPid % 254) + 1);
        snprintf(spoofed_port, sizeof(spoofed_port), "%d", 40000 + (MyProcPid % 25000));
        client_addr = spoofed_ip;
        client_port = spoofed_port;
    }

    /* Explicit per-session override from the attack-generator templates takes
     * precedence over both the real value and the PID-derived fallback above,
     * so each generated attack instance can be tagged with its own unique
     * synthetic username/IP. */
    if (casce_sim_user && casce_sim_user[0] != '\0') {
        username = casce_sim_user;
    }
    if (casce_sim_ip && casce_sim_ip[0] != '\0') {
        client_addr = casce_sim_ip;
    }

    if (cached_session_start_time == 0) {
        cached_session_start_time = (long)time(NULL);
    }

    
    dprintf(fd, "{\"session_id\": %d, \"session_start_time\": %ld, \"backend_pid\": %d, \"timestamp\": %ld, \"event_type\": \"%s\", \"query\": \"%s\", \"database\": \"%s\", \"username\": \"%s\", \"client_addr\": \"%s\", \"client_port\": \"%s\"}\n", MyProcPid, cached_session_start_time, MyProcPid, (long)time(NULL), event_type, safe_query, dbname, username, client_addr, client_port);

    close(fd);
}

/* Fires once per backend, right before it exits -- i.e. exactly when a
 * client session ends (normal disconnect, connection drop, or backend
 * termination). This is the only reliable "session closed" signal in the
 * pipeline; the live graph processor waits for this event before it will
 * persist that session's graph to disk. Query is passed as "" rather than
 * NULL since log_casce_event() early-returns on a NULL query. */
static void casce_on_proc_exit(int code, Datum arg) {
    log_casce_event("Disconnect", "");
}

static void casce_ExecutorStart(QueryDesc *queryDesc, int eflags) {
    if (queryDesc && queryDesc->sourceText) {
        log_casce_event("ExecutorStart", queryDesc->sourceText);
    }
    if (prev_ExecutorStart) prev_ExecutorStart(queryDesc, eflags);
    else standard_ExecutorStart(queryDesc, eflags);
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
    

    
    prev_ExecutorEnd = ExecutorEnd_hook;
    ExecutorEnd_hook = casce_ExecutorEnd;
    
    prev_ProcessUtility = ProcessUtility_hook;
    ProcessUtility_hook = casce_ProcessUtility;

    on_proc_exit(casce_on_proc_exit, 0);

    DefineCustomStringVariable(
        "casce.sim_user",
        "Synthetic username to record for this session in postgres_events.json (set by the attack-instance generator).",
        NULL,
        &casce_sim_user,
        NULL,
        PGC_USERSET,
        0,
        NULL, NULL, NULL);

    DefineCustomStringVariable(
        "casce.sim_ip",
        "Synthetic client IP to record for this session in postgres_events.json (set by the attack-instance generator).",
        NULL,
        &casce_sim_ip,
        NULL,
        PGC_USERSET,
        0,
        NULL, NULL, NULL);
}

void _PG_fini(void) {
    ExecutorStart_hook = prev_ExecutorStart;

    ExecutorEnd_hook = prev_ExecutorEnd;
    ProcessUtility_hook = prev_ProcessUtility;
}
