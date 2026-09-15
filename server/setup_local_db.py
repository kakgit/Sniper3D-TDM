#!/usr/bin/env python3
"""One time setup: create the local Postgres role and database, and write
server/.env.local so the accounts API and its smoke test can reach them.

    python server/setup_local_db.py

It asks for your postgres superuser password (the one chosen when PostgreSQL was
installed) and for a password for the game's own role. Neither is echoed, and
neither is written anywhere except server/.env.local, which is gitignored.

Non-interactive alternative, if prompts are awkward in your terminal:

    PGSUPERPASS=... TDMPASS=... python server/setup_local_db.py

Nothing here touches the Godot project. It only creates a role, a database and
that one ignored file.
"""

import getpass
import os
import sys
from urllib.parse import quote

try:
    import psycopg
    from psycopg import sql
except ImportError:
    sys.exit(
        "psycopg is missing. Install it first:\n"
        "    pip install -r server/requirements.txt"
    )

HOST = os.environ.get("PGHOST") or "127.0.0.1"
PORT = int(os.environ.get("PGPORT") or "5432")
SUPERUSER = os.environ.get("PGSUPERUSER") or "postgres"
ROLE = os.environ.get("TDM_ROLE") or "tdm"
DBNAME = os.environ.get("TDM_DB") or "tdm_accounts"

HERE = os.path.dirname(os.path.abspath(__file__))
ENV_PATH = os.path.join(HERE, ".env.local")


def ask_secret(env_key, prompt):
    """Password from the environment when provided, otherwise a hidden prompt."""
    value = os.environ.get(env_key)
    if value:
        return value
    try:
        return getpass.getpass(prompt)
    except (EOFError, KeyboardInterrupt):
        sys.exit("\ncancelled, nothing was changed")


def main():
    print(
        "local Postgres at %s:%d - setting up role %r and database %r"
        % (HOST, PORT, ROLE, DBNAME)
    )
    print("")

    superpass = ask_secret("PGSUPERPASS", "postgres superuser password (not shown): ")
    ownpass = ask_secret("TDMPASS", "password for role %s (not shown): " % ROLE)
    if not ownpass:
        sys.exit("the role password cannot be empty")

    try:
        # autocommit: CREATE DATABASE cannot run inside a transaction block.
        conn = psycopg.connect(
            host=HOST,
            port=PORT,
            user=SUPERUSER,
            password=superpass,
            dbname="postgres",
            autocommit=True,
        )
    except psycopg.OperationalError as err:
        return "could not connect as %s at %s:%d: %s" % (SUPERUSER, HOST, PORT, err)

    try:
        row = conn.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (ROLE,)).fetchone()
        if row:
            conn.execute(
                sql.SQL("ALTER ROLE {} WITH LOGIN PASSWORD {}").format(
                    sql.Identifier(ROLE), sql.Literal(ownpass)
                )
            )
            print("role %s already existed, password reset" % ROLE)
        else:
            conn.execute(
                sql.SQL("CREATE ROLE {} WITH LOGIN PASSWORD {}").format(
                    sql.Identifier(ROLE), sql.Literal(ownpass)
                )
            )
            print("role %s created" % ROLE)

        row = conn.execute(
            "SELECT 1 FROM pg_database WHERE datname = %s", (DBNAME,)
        ).fetchone()
        if row:
            print("database %s already existed, left as it is" % DBNAME)
        else:
            conn.execute(
                sql.SQL("CREATE DATABASE {} OWNER {}").format(
                    sql.Identifier(DBNAME), sql.Identifier(ROLE)
                )
            )
            print("database %s created, owned by %s" % (DBNAME, ROLE))
    except psycopg.Error as err:
        return "the database refused the setup: %s" % err
    finally:
        conn.close()

    # quote() percent-encodes anything awkward in the password, so a random
    # password with @ : / or # in it still produces a valid URL.
    url = "postgresql://%s:%s@%s:%d/%s" % (
        quote(ROLE, safe=""),
        quote(ownpass, safe=""),
        HOST,
        PORT,
        quote(DBNAME, safe=""),
    )
    with open(ENV_PATH, "w", encoding="utf-8") as handle:
        handle.write("# Written by server/setup_local_db.py. Gitignored: never commit this.\n")
        handle.write("DATABASE_URL=%s\n" % url)
    print("wrote %s (contains the password, and git ignores it)" % ENV_PATH)
    print("")
    print("next:  python server/smoke_test.py")
    print("the first line should read:  backend: postgres (DATABASE_URL)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
