#!/usr/bin/env python3
"""
load_seed.py <seed_commands.json> <dbname>

Runs each string in the JSON list as its own SQL statement against dbname.
Failures on individual statements are reported but don't abort the run.
"""
import sys
import json
import psycopg2

def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)

    seed_path, dbname = sys.argv[1], sys.argv[2]
    with open(seed_path) as f:
        commands = json.load(f)

    if not isinstance(commands, list):
        print("seed file must be a JSON list of SQL strings")
        sys.exit(1)

    conn = psycopg2.connect(dbname=dbname, user="postgres", host="/var/run/postgresql")
    conn.autocommit = True
    cur = conn.cursor()

    ok, failed = 0, 0
    for i, sql in enumerate(commands):
        try:
            cur.execute(sql)
            ok += 1
        except Exception as e:
            failed += 1
            print(f"[seed:{i}] FAILED: {e}", file=sys.stderr)

    cur.close()
    conn.close()
    print(f"Seed complete: {ok} succeeded, {failed} failed.")

if __name__ == "__main__":
    main()