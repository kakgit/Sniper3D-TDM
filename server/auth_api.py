#!/usr/bin/env python3
"""Accounts API for TDM Sniper Arena.

No framework: one source file plus one driver. Run it locally with

    python3 server/auth_api.py

Storage is Postgres when DATABASE_URL is set, SQLite otherwise, so a laptop
needs no database installed and a host gets the durable one. Configuration
comes from the environment:

    DATABASE_URL   postgresql://...        switches storage to Postgres
    AUTH_HOST      interface to bind       (default 127.0.0.1, or 0.0.0.0 when PORT is set)
    AUTH_PORT      port to listen on       (default 8787, or PORT when the host sets one)
    AUTH_DB        path to the sqlite file (default auth.db next to this file)

Postgres needs its driver:  pip install "psycopg[binary]"
(The image in this folder installs it already.)

The host lines matter when deploying. A container platform (Railway, Fly, Cloud
Run) injects PORT and needs the process listening on 0.0.0.0, so on a host both
are picked up automatically. Run by hand on a laptop there is no PORT, so it
still binds 127.0.0.1:8787 and the development copy is never exposed to the
local network unless you ask for it.

Endpoints (all JSON):

    GET  /v1/health                     -> {"ok": true, "version": 1, "storage": "..."}
    POST /v1/register {username,password} -> 201 {user_id,username,token,expires_at}
    POST /v1/login    {username,password} -> 200 {user_id,username,token,expires_at}
    GET  /v1/me       Authorization: Bearer <token> -> 200 {user_id,username}
    POST /v1/logout   Authorization: Bearer <token> -> 204

Passwords are stored as scrypt hashes with a per user salt. Tokens are random
and only their SHA-256 is stored, so a copy of the database cannot be used to
impersonate anyone. Usernames are unique ignoring case: a unique index on
lower(username) in Postgres, COLLATE NOCASE in SQLite. This server speaks plain
HTTP; the host terminates TLS in front of it.
"""

import hashlib
import hmac
import json
import os
import secrets
import sqlite3
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

try:
    import psycopg
    from psycopg.rows import dict_row
except ImportError:      # a laptop without the driver still runs on SQLite
    psycopg = None
    dict_row = None

VERSION = 1
TOKEN_TTL = 60 * 60 * 24 * 30          # a login lasts 30 days
MAX_BODY = 4096                        # small JSON bodies only
MIN_USERNAME = 3
MAX_USERNAME = 20
MIN_PASSWORD = 8
MAX_PASSWORD = 200

# scrypt cost. n=2**14 keeps a login under ~100 ms on a small host.
SCRYPT_N = 2 ** 14
SCRYPT_R = 8
SCRYPT_P = 1
SCRYPT_DKLEN = 32

# A crude throttle: too many failed logins from one address in a window.
FAIL_WINDOW = 300.0
FAIL_LIMIT = 10

HERE = os.path.dirname(os.path.abspath(__file__))
DB_PATH = os.environ.get("AUTH_DB") or os.path.join(HERE, "auth.db")
# A hosting platform sets PORT and expects a 0.0.0.0 bind. A laptop has no PORT and
# keeps the loopback default, so a local run stays private.
PORT = int(os.environ.get("AUTH_PORT") or os.environ.get("PORT") or "8787")
HOST = os.environ.get("AUTH_HOST") or ("0.0.0.0" if os.environ.get("PORT") else "127.0.0.1")

# Postgres when the host supplies a connection string, SQLite otherwise. libpq
# understands both schemes, but normalise the short one so there is one form.
DATABASE_URL = os.environ.get("DATABASE_URL") or ""
if DATABASE_URL.startswith("postgres://"):
    DATABASE_URL = "postgresql://" + DATABASE_URL[len("postgres://"):]
USING_POSTGRES = bool(DATABASE_URL)
STORAGE = "postgres" if USING_POSTGRES else "sqlite"

if USING_POSTGRES and psycopg is None:
    raise SystemExit(
        'DATABASE_URL is set but the Postgres driver is missing.\n'
        'Install it with:  pip install "psycopg[binary]"'
    )

# psycopg raises this on a unique index violation, the Postgres twin of sqlite's
# IntegrityError. Left as None on a laptop that never installed the driver.
DUPLICATE = psycopg.errors.UniqueViolation if psycopg is not None else None

_db_lock = threading.Lock()
_fails = {}
_fails_lock = threading.Lock()


# --- storage ---------------------------------------------------------------
#
# One small shim over two backends. Every call site below uses connect(),
# with conn: and conn.execute(), so nothing else in this file cares which
# database is live. The only dialect differences are the placeholder ("?" and
# psycopg's "%s"), the schema, and how a new row reports its id.


class Conn:
    """The handful of connection methods this file uses, over either backend."""

    def __init__(self, raw, postgres):
        self.raw = raw
        self.postgres = postgres

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        # sqlite's own context manager commits, and psycopg's is autocommit in
        # disguise. Ours does it explicitly so both behave the same way.
        if exc_type is None:
            self.raw.commit()
        else:
            self.raw.rollback()
        return False

    def execute(self, sql, params=()):
        if self.postgres:
            return self.raw.execute(sql.replace("?", "%s"), params)
        return self.raw.execute(sql, params)

    def close(self):
        self.raw.close()


def connect():
    """One connection per request. Caller closes it."""
    if USING_POSTGRES:
        raw = psycopg.connect(DATABASE_URL, row_factory=dict_row, connect_timeout=10)
        return Conn(raw, True)
    raw = sqlite3.connect(DB_PATH, timeout=10.0)
    raw.row_factory = sqlite3.Row
    raw.execute("PRAGMA foreign_keys = ON")
    return Conn(raw, False)


SQLITE_SCHEMA = [
    """CREATE TABLE IF NOT EXISTS users (
           id INTEGER PRIMARY KEY AUTOINCREMENT,
           username TEXT NOT NULL UNIQUE COLLATE NOCASE,
           pw_hash BLOB NOT NULL,
           salt BLOB NOT NULL,
           created_at INTEGER NOT NULL
       )""",
    """CREATE TABLE IF NOT EXISTS tokens (
           token_hash TEXT PRIMARY KEY,
           user_id INTEGER NOT NULL,
           created_at INTEGER NOT NULL,
           expires_at INTEGER NOT NULL,
           FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
       )""",
    "CREATE INDEX IF NOT EXISTS tokens_user ON tokens(user_id)",
]

POSTGRES_SCHEMA = [
    """CREATE TABLE IF NOT EXISTS users (
           id BIGSERIAL PRIMARY KEY,
           username TEXT NOT NULL,
           pw_hash BYTEA NOT NULL,
           salt BYTEA NOT NULL,
           created_at BIGINT NOT NULL
       )""",
    # COLLATE NOCASE has no Postgres equivalent, so case-insensitive uniqueness
    # comes from an index on lower(username) instead of an extension.
    "CREATE UNIQUE INDEX IF NOT EXISTS users_username ON users (lower(username))",
    """CREATE TABLE IF NOT EXISTS tokens (
           token_hash TEXT PRIMARY KEY,
           user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
           created_at BIGINT NOT NULL,
           expires_at BIGINT NOT NULL
       )""",
    "CREATE INDEX IF NOT EXISTS tokens_user ON tokens(user_id)",
]


def init_db():
    conn = connect()
    try:
        with conn:
            for statement in (POSTGRES_SCHEMA if USING_POSTGRES else SQLITE_SCHEMA):
                conn.execute(statement)
    finally:
        conn.close()


def insert_user(conn, username, pw_hash, salt):
    """Returns the new user id, or None when that username is already taken."""
    params = (username, pw_hash, salt, int(time.time()))
    if conn.postgres:
        try:
            with conn:
                cur = conn.execute(
                    "INSERT INTO users (username, pw_hash, salt, created_at)"
                    " VALUES (?, ?, ?, ?) RETURNING id",
                    params,
                )
                return int(cur.fetchone()["id"])
        except DUPLICATE:
            return None           # the with block already rolled back
    try:
        with conn:
            cur = conn.execute(
                "INSERT INTO users (username, pw_hash, salt, created_at)"
                " VALUES (?, ?, ?, ?)",
                params,
            )
            return int(cur.lastrowid)
    except sqlite3.IntegrityError:
        return None


# --- passwords and tokens --------------------------------------------------


def hash_password(password, salt):
    return hashlib.scrypt(
        password.encode("utf-8"),
        salt=salt,
        n=SCRYPT_N,
        r=SCRYPT_R,
        p=SCRYPT_P,
        dklen=SCRYPT_DKLEN,
    )


def new_token():
    """Returns (token shown to the player, hash stored in the database)."""
    token = secrets.token_urlsafe(32)
    return token, hashlib.sha256(token.encode("utf-8")).hexdigest()


def issue_token(conn, user_id):
    token, token_hash = new_token()
    now = int(time.time())
    expires = now + TOKEN_TTL
    with conn:
        conn.execute(
            "INSERT INTO tokens (token_hash, user_id, created_at, expires_at)"
            " VALUES (?, ?, ?, ?)",
            (token_hash, user_id, now, expires),
        )
    return token, expires


def user_for_token(conn, token):
    """The user row behind a live token, or None."""
    if not token:
        return None
    token_hash = hashlib.sha256(token.encode("utf-8")).hexdigest()
    row = conn.execute(
        "SELECT u.id, u.username, t.expires_at FROM tokens t"
        " JOIN users u ON u.id = t.user_id WHERE t.token_hash = ?",
        (token_hash,),
    ).fetchone()
    if row is None:
        return None
    if int(row["expires_at"]) < int(time.time()):
        with conn:
            conn.execute("DELETE FROM tokens WHERE token_hash = ?", (token_hash,))
        return None
    return row


# --- validation ------------------------------------------------------------

# Deliberately ASCII only. str.isalnum() also accepts letters from every other
# script, and SQLite's lower() is ASCII-only while Postgres' follows the locale,
# so a non-ASCII name could be unique on one backend and a duplicate on the
# other. Restricting the alphabet removes the difference and the lookalike names.
ASCII_USERNAME = set(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"
)


def check_credentials(username, password):
    """Returns an error message, or None when the pair is acceptable."""
    if not isinstance(username, str) or not isinstance(password, str):
        return "username and password must be text"
    if not (MIN_USERNAME <= len(username) <= MAX_USERNAME):
        return "username must be %d-%d characters" % (MIN_USERNAME, MAX_USERNAME)
    if not all(c in ASCII_USERNAME for c in username):
        return "username may only use letters, digits and underscore"
    if not (MIN_PASSWORD <= len(password) <= MAX_PASSWORD):
        return "password must be at least %d characters" % MIN_PASSWORD
    return None


def throttled(ip):
    now = time.time()
    with _fails_lock:
        recent = [t for t in _fails.get(ip, []) if now - t < FAIL_WINDOW]
        _fails[ip] = recent
        return len(recent) >= FAIL_LIMIT


def note_failure(ip):
    with _fails_lock:
        _fails.setdefault(ip, []).append(time.time())


def clear_failures(ip):
    with _fails_lock:
        _fails.pop(ip, None)


# --- request handling ------------------------------------------------------


class Handler(BaseHTTPRequestHandler):
    server_version = "TDMAccounts/%d" % VERSION
    protocol_version = "HTTP/1.1"

    # quiet, single line logging
    def log_message(self, fmt, *args):
        sys.stdout.write("%s %s\n" % (self.address_string(), fmt % args))
        sys.stdout.flush()

    def _send(self, code, payload=None):
        body = b""
        if payload is not None:
            body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        if body:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _error(self, code, name, message):
        self._send(code, {"error": name, "message": message})

    def _body(self):
        """Parsed JSON body, or None when it is missing or unusable."""
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            return None
        if length <= 0 or length > MAX_BODY:
            return None
        raw = self.rfile.read(length)
        try:
            data = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return None
        return data if isinstance(data, dict) else None

    def _bearer(self):
        header = self.headers.get("Authorization") or ""
        if not header.startswith("Bearer "):
            return ""
        return header[7:].strip()

    def _ip(self):
        return self.client_address[0]

    # routes
    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/v1/health":
            # Liveness only: this says the process is up and which database it
            # was told to use. It deliberately does not touch the database, so a
            # database blip does not get the container restarted.
            self._send(200, {"ok": True, "version": VERSION, "storage": STORAGE})
            return
        if path == "/v1/me":
            conn = connect()
            try:
                row = user_for_token(conn, self._bearer())
                if row is None:
                    self._error(401, "unauthorized", "sign in again")
                    return
                self._send(200, {"user_id": int(row["id"]), "username": row["username"]})
            finally:
                conn.close()
            return
        self._error(404, "not_found", "no such endpoint")

    def do_POST(self):
        path = urlparse(self.path).path
        if path == "/v1/register":
            self._register()
            return
        if path == "/v1/login":
            self._login()
            return
        if path == "/v1/logout":
            self._logout()
            return
        self._error(404, "not_found", "no such endpoint")

    def _register(self):
        data = self._body()
        if data is None:
            self._error(400, "invalid_body", "expected a JSON object")
            return
        username = str(data.get("username", "")).strip()
        password = str(data.get("password", ""))
        problem = check_credentials(username, password)
        if problem:
            self._error(400, "invalid_credentials", problem)
            return
        salt = secrets.token_bytes(16)
        pw_hash = hash_password(password, salt)
        conn = connect()
        try:
            with _db_lock:
                user_id = insert_user(conn, username, pw_hash, salt)
            if user_id is None:
                self._error(409, "username_taken", "that username is taken")
                return
            token, expires = issue_token(conn, user_id)
            self._send(
                201,
                {
                    "user_id": user_id,
                    "username": username,
                    "token": token,
                    "expires_at": expires,
                },
            )
        finally:
            conn.close()

    def _login(self):
        if throttled(self._ip()):
            self._error(429, "too_many_attempts", "too many attempts, wait a minute")
            return
        data = self._body()
        if data is None:
            self._error(400, "invalid_body", "expected a JSON object")
            return
        username = str(data.get("username", "")).strip()
        password = str(data.get("password", ""))
        conn = connect()
        try:
            row = conn.execute(
                "SELECT id, username, pw_hash, salt FROM users"
                " WHERE lower(username) = lower(?)",
                (username,),
            ).fetchone()
            # hash either way, so a missing user and a wrong password take
            # about the same time
            salt = row["salt"] if row is not None else b"0" * 16
            candidate = hash_password(password, salt)
            stored = row["pw_hash"] if row is not None else b"1" * SCRYPT_DKLEN
            if row is None or not hmac.compare_digest(candidate, stored):
                note_failure(self._ip())
                self._error(401, "invalid_credentials", "wrong username or password")
                return
            clear_failures(self._ip())
            token, expires = issue_token(conn, int(row["id"]))
            self._send(
                200,
                {
                    "user_id": int(row["id"]),
                    "username": row["username"],
                    "token": token,
                    "expires_at": expires,
                },
            )
        finally:
            conn.close()

    def _logout(self):
        token = self._bearer()
        conn = connect()
        try:
            if user_for_token(conn, token) is None:
                self._error(401, "unauthorized", "sign in again")
                return
            token_hash = hashlib.sha256(token.encode("utf-8")).hexdigest()
            with conn:
                conn.execute("DELETE FROM tokens WHERE token_hash = ?", (token_hash,))
            self._send(204)
        finally:
            conn.close()


def ensure_db_dir():
    """The sqlite file may sit on a volume that is not created until deploy time."""
    if USING_POSTGRES:
        return
    parent = os.path.dirname(os.path.abspath(DB_PATH))
    if parent and not os.path.isdir(parent):
        os.makedirs(parent, exist_ok=True)


def main():
    ensure_db_dir()
    init_db()
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print("accounts api v%d on http://%s:%d" % (VERSION, HOST, PORT))
    print("storage: %s" % ("postgres" if USING_POSTGRES else "sqlite %s" % DB_PATH))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("stopping")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
