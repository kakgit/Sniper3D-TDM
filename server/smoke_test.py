#!/usr/bin/env python3
"""End to end check of the accounts API.

Starts auth_api.py and walks the whole flow: register, duplicate register,
login, wrong password, token check, logout.

    python3 server/smoke_test.py

With no DATABASE_URL that is a throwaway SQLite file, so the run repeats freely
and leaves nothing behind. With DATABASE_URL set, the same checks run against
that Postgres instead, using a fresh username each run. The account it creates
there stays in the database.

Exits 0 when every check passes, 1 otherwise.
"""

import json
import os
import secrets
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
API = os.path.join(HERE, "auth_api.py")
PORT = 8799
BASE = "http://127.0.0.1:%d" % PORT

PASS = "correct-horse-battery"
# A real Postgres keeps its accounts between runs, so every run registers a name
# of its own. The SQLite database is a fresh temp file, so it can stay fixed.
POSTGRES = bool(os.environ.get("DATABASE_URL"))
USER = ("smoke_" + secrets.token_hex(4)) if POSTGRES else "smoke_user"

passed = 0
failed = 0


def call(method, path, body=None, token=None):
    """Returns (status, parsed_json_or_none)."""
    url = BASE + path
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as err:
        raw = err.read()
        return err.code, (json.loads(raw) if raw else None)


def check(name, got, want):
    global passed, failed
    ok = got == want
    if ok:
        passed += 1
        print("PASS  %s" % name)
    else:
        failed += 1
        print("FAIL  %s: got %r, wanted %r" % (name, got, want))


def wait_for_server(proc, timeout=15.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if proc.poll() is not None:
            return False
        try:
            status, _ = call("GET", "/v1/health")
            if status == 200:
                return True
        except Exception:
            pass
        time.sleep(0.2)
    return False


def main():
    print("backend: %s" % ("postgres (DATABASE_URL)" if POSTGRES else "sqlite (temp file)"))
    print("account: %s" % USER)

    db_path = ""
    if not POSTGRES:
        db_fd, db_path = tempfile.mkstemp(prefix="auth_smoke_", suffix=".db")
        os.close(db_fd)
        os.unlink(db_path)      # let the server create it fresh

    env = dict(os.environ)
    if not POSTGRES:
        env["AUTH_DB"] = db_path
    env["AUTH_PORT"] = str(PORT)
    env["AUTH_HOST"] = "127.0.0.1"

    proc = subprocess.Popen(
        [sys.executable, API],
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.STDOUT,
    )
    try:
        if not wait_for_server(proc):
            print("FAIL  server did not come up")
            return 1

        status, body = call("GET", "/v1/health")
        check("health returns 200", status, 200)
        check("health reports ok", bool(body and body.get("ok")), True)
        # Proves which storage the server actually opened, rather than assuming
        # DATABASE_URL was picked up.
        check(
            "health reports the expected backend",
            (body or {}).get("storage"),
            "postgres" if POSTGRES else "sqlite",
        )

        status, body = call(
            "POST", "/v1/register", {"username": USER, "password": PASS}
        )
        check("register returns 201", status, 201)
        check("register returns a token", bool(body and body.get("token")), True)
        check("register returns the username", body and body.get("username"), USER)
        token = (body or {}).get("token", "")

        status, body = call(
            "POST", "/v1/register", {"username": USER, "password": PASS}
        )
        check("duplicate register is refused", status, 409)
        check("duplicate error name", body and body.get("error"), "username_taken")

        status, body = call(
            "POST", "/v1/register", {"username": "ab", "password": PASS}
        )
        check("too short username refused", status, 400)

        status, body = call(
            "POST", "/v1/register", {"username": "smoke_two", "password": "short"}
        )
        check("too short password refused", status, 400)

        status, body = call(
            "POST", "/v1/login", {"username": USER, "password": PASS}
        )
        check("login returns 200", status, 200)
        check("login returns a token", bool(body and body.get("token")), True)
        login_token = (body or {}).get("token", "")
        check("login token differs from register token", login_token != token, True)

        status, body = call(
            "POST", "/v1/login", {"username": USER, "password": "wrong-password"}
        )
        check("wrong password refused", status, 401)

        status, body = call(
            "POST", "/v1/login", {"username": "nobody_here", "password": PASS}
        )
        check("unknown user refused", status, 401)

        status, body = call("GET", "/v1/me", token=login_token)
        check("me returns 200 with a good token", status, 200)
        check("me returns the username", body and body.get("username"), USER)

        status, body = call("GET", "/v1/me")
        check("me without a token is refused", status, 401)

        status, body = call("GET", "/v1/me", token="not-a-real-token")
        check("me with a bad token is refused", status, 401)

        status, body = call("POST", "/v1/logout", token=login_token)
        check("logout returns 204", status, 204)

        status, body = call("GET", "/v1/me", token=login_token)
        check("token is dead after logout", status, 401)

        status, body = call("GET", "/nope")
        check("unknown path is refused", status, 404)

        status, body = call("POST", "/v1/login")
        check("login without a body is refused", status, 400)

        if POSTGRES:
            # The stored row is the database's business and this test holds no
            # database credentials, so the hash is only inspected in the SQLite
            # mode. The hashing code itself is shared by both backends.
            print("SKIP  password is not stored in the clear (sqlite mode only)")
        else:
            check(
                "password is not stored in the clear",
                PASS.encode("utf-8") not in open(db_path, "rb").read(),
                True,
            )
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
        if not POSTGRES:
            for suffix in ("", "-journal", "-wal"):
                path = db_path + suffix
                if os.path.exists(path):
                    os.unlink(path)

    print("")
    print("%d passed, %d failed" % (passed, failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
