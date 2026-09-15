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
SQLite path, which needs no installation at all, and you want the run to end in
`21 passed, 0 failed`.

To exercise the Postgres path before you deploy anything, install the driver and
point the test at your database:

    pip install -r server/requirements.txt
    set DATABASE_URL=postgresql://user:pass@host:5432/dbname
    python server/smoke_test.py

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

### 1. Put the project in a Git repo

Railway deploys from a repository. This project is not one yet - say the word and
I will initialize it and commit what is there. `server/auth.db` is already
ignored, so a local database never gets committed.

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

    {"ok": true, "storage": "postgres", "version": 2}

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

- I have not run this container and I cannot run it from here: no terminal, no
  Docker. The image is written but unbuilt, and the Postgres path is new code
  that has not executed anywhere yet. Step 2 will either build it or show an
  error, and a build error is cheap to read and fix.
- Railway is a paid service billed by usage, and a Postgres service adds to that.
  I am not quoting a price because the plans change; check their current pricing
  before you commit. This API is tiny - a few megabytes of idle memory and a fast
  request path - so the cost is dominated by platform minimums, not this code.
- Free tiers come and go, and a sleeping instance means a login takes a few
  seconds to wake up. Restart on failure is already set in `railway.json`.
