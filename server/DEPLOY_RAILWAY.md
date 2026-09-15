# Hosting the accounts API on Railway

`server/auth_api.py` is the real service, not a placeholder: scrypt password
hashes, bearer tokens, throttled logins, and a durable store. It now speaks to
whichever database the environment points at:

| Environment | Storage | Set up by |
| --- | --- | --- |
| `DATABASE_URL` set | Postgres | the host (Railway's Postgres service) |
| `DATABASE_URL` unset | SQLite file | nothing - it just works, for local runs |

That is the whole reason the same file runs on your laptop and in the cloud. On
Railway, `DATABASE_URL` exists, so accounts live in Postgres and survive every
redeploy.

The parts I cannot do from here are creating the hosting account, clicking
Deploy, and holding your credentials. Those are your steps, and they are short.

## Run it locally first

The smoke test starts a server of its own on a throwaway database and port, so
nothing is left behind:

    cd "D:/Game Projects/TDM/new-game-project"
    python server/smoke_test.py

Use `python`, not `python3`, on Windows. With no `DATABASE_URL` it exercises the
SQLite path, which needs no installation at all, and a good run ends in
`24 passed, 0 failed`.

### Then the same test against your local Postgres

That is the run that matters, because it executes the Postgres code on this
machine instead of finding out about it on the host. Postgres 18 is installed and
the driver is already in place, so it is one command:

    python server/setup_local_db.py

It prompts for your `postgres` superuser password, creates the role `tdm` and the
database `tdm_accounts`, and writes `server/.env.local` holding the connection
string. The prompt uses getpass, so the password is not echoed and does not reach
your shell history, and `.gitignore` line 21 keeps that file out of git. If the
driver is ever missing on a fresh machine:

    pip install -r server/requirements.txt

Then run the test again:

    python server/smoke_test.py

   A good run starts with `backend: postgres (DATABASE_URL)` and ends in
   `23 passed, 0 failed` with one `SKIP`. The skip is the raw-file password check,
   which needs database credentials the test deliberately does not hold; the
   hashing it covers is shared with the SQLite path, which does check it.

In this mode the test registers a randomly named account each run, so repeated
runs do not collide - and those accounts stay in the database. Each run also
checks the backend the server actually opened, so a silent fallback to SQLite
shows up as a failure instead of passing quietly.

The same checks run against whichever database you point it at: register,
duplicate register, short username, short password, login, wrong password,
unknown user, token check, logout, dead token, unknown path, empty body, and (on
SQLite only) a check that the password is not sitting in the database in the
clear. On Postgres that last one is skipped, because reading the table needs
credentials the test deliberately does not have.

## What was added for hosting

| File | Why |
| --- | --- |
| `server/Dockerfile` | Builds the service image and installs the Postgres driver. |
| `server/requirements.txt` | `psycopg[binary]`, so the image needs no compiler. |
| `server/.dockerignore` | Keeps the build context to the service files. |
| `server/railway.json` | Tells Railway to use the Dockerfile and to health check `/v1/health`. |
| `server/auth_api.py` | Reads the platform's `PORT`, binds `0.0.0.0` when the platform sets one, chooses Postgres when `DATABASE_URL` exists, and creates a missing SQLite directory. |

## Deploy steps

### 1. Put the project on GitHub

Railway deploys from a repository, so the flow is: commit locally, push to
GitHub, and Railway redeploys by itself whenever that branch moves. This project
is already a Git repo with the current work committed, so what is left is
creating the empty GitHub repo and pushing to it. Everything after this step is
one-time setup; after that, pushing is the whole deploy.

`server/auth.db`, `server/.env.local` and `/build/` are ignored, so a local
database, a local password and the APK never get pushed.

### 2. Create the service

1. Sign in at railway.app and create an empty project.
2. Add a service from your repository.
3. In the service settings, set **Root Directory** to `server`.

   This is the important one. The service root is the folder holding the
   `Dockerfile`, not the Godot project, so the game's assets never enter the
   build.

### 3. Add Postgres

Add a database to the same project and choose Postgres. Railway creates it and
publishes a `DATABASE_URL` variable on that database service.

### 4. Point the API at the database

On the **API** service, add a variable named `DATABASE_URL` whose value is a
reference to the database service's `DATABASE_URL` (Railway's variable editor
has an "Add Reference" option for this; the stored value looks like
`${{Postgres.DATABASE_URL}}`).

Use the reference rather than pasting the connection string. The string contains
the database password, and a reference keeps it out of your service settings, out
of this chat, and correct if Railway ever rotates it. If the dashboard wording
has moved since this was written, the goal is unchanged: a `DATABASE_URL`
variable on the API service that resolves to the Postgres connection string.

You do not need a volume any more. One is only relevant if you deliberately
unset `DATABASE_URL` and want the SQLite fallback to persist, in which case mount
it at `/data` to match `AUTH_DB` in the Dockerfile.

### 5. Give it a public domain

In the service's networking settings, generate a domain. Railway terminates TLS,
so the service ends up reachable at `https://<your-service>.up.railway.app`.
Behind that proxy the service itself keeps speaking plain HTTP, which is exactly
how it was written to be deployed.

### 6. Confirm the deployed copy

Open `https://<your-service>.up.railway.app/v1/health` in a browser. You want:

    {"ok": true, "version": 1, "storage": "postgres"}

`"storage": "postgres"` is the line that matters. If it says `sqlite`, the
`DATABASE_URL` variable is not reaching the service and accounts would be living
in the container instead of the database. That is the same endpoint Railway uses
as its health check, so a green deploy plus that response means the code you
tested locally is answering on the internet against real Postgres.

## Keep the credentials out of chat

The database password lives in Railway's variables, and that is where it should
stay. My code reads the variable by name and never needs to see its value. If a
connection string with a password ever does land in a message, rotate it in the
dashboard rather than leaving it there.

No secret is required to run the service itself today, so nothing is missing for
a first deploy.

## What is still missing on the game side

The backend can be deployed and healthy right now, but the game does not call it
yet. There is no HTTP client code in the project, so the login screen cannot be
tested against a live server until the accounts step is built. When it is, the
base URL belongs in one constant in the client pointing at the domain from step
5. That constant does not exist yet, and I did not add a config file for a client
that has not been written.

The headless Godot room server is separate work. It speaks UDP, and whether a
given host passes UDP is something I would verify against their current docs
rather than assume. Rooms and bots are milestone 4 in
`mobile-multiplayer.plan.md`.

## Honest limits

- The container is written but unbuilt, and I have no Docker here to build it
  with. Step 2 either builds it or shows an error, and a build error is cheap to
  read and fix.
- The Postgres path is what the local run above exists to cover. Until that run
  has actually happened against a real database it is unproven code, so treat the
  first Postgres result as the moment it becomes trustworthy rather than assuming
  it from the SQLite pass.
- The image is Python 3.12 and installs psycopg from `server/requirements.txt`.
  Locally that resolved to psycopg 3.3.5 on Python 3.14, so the exact patch
  version in the image may differ. Same major version and same API.
- Railway is a paid service billed by usage, and a Postgres service adds to that.
  I am not quoting a price because the plans change; check their current pricing
  before you commit. This API is tiny - a few megabytes of idle memory and a fast
  request path - so the cost is dominated by platform minimums, not this code.
- Free tiers come and go, and a sleeping instance means a login takes a few
  seconds to wake up. Restart on failure is already set in `railway.json`.
