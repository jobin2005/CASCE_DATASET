-- ============================================================================
-- TPC-B (pgbench) Benchmark Schema
-- ============================================================================

DROP TABLE IF EXISTS pgbench_history CASCADE;
DROP TABLE IF EXISTS pgbench_accounts CASCADE;
DROP TABLE IF EXISTS pgbench_tellers CASCADE;
DROP TABLE IF EXISTS pgbench_branches CASCADE;

CREATE TABLE pgbench_branches (
    bid INTEGER NOT NULL PRIMARY KEY,
    bbalance INTEGER,
    filler CHAR(88)
);

CREATE TABLE pgbench_tellers (
    tid INTEGER NOT NULL PRIMARY KEY,
    bid INTEGER REFERENCES pgbench_branches(bid),
    tbalance INTEGER,
    filler CHAR(84)
);

CREATE TABLE pgbench_accounts (
    aid INTEGER NOT NULL PRIMARY KEY,
    bid INTEGER REFERENCES pgbench_branches(bid),
    abalance INTEGER,
    filler CHAR(84)
);

CREATE TABLE pgbench_history (
    tid INTEGER,
    bid INTEGER,
    aid INTEGER,
    delta INTEGER,
    mtime TIMESTAMP,
    filler CHAR(22)
);

CREATE INDEX idx_pgbench_accounts_bid ON pgbench_accounts(bid);
CREATE INDEX idx_pgbench_tellers_bid ON pgbench_tellers(bid);
