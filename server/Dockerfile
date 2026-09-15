# Accounts API for TDM Sniper Arena.
# One source file plus the Postgres driver. Without DATABASE_URL the service
# falls back to the SQLite file on the volume and needs nothing extra.

FROM python:3.12-slim

# Unbuffered so the startup line and request log reach the host's log viewer.
# AUTH_DB applies to the SQLite fallback only; with DATABASE_URL set the
# service uses Postgres and ignores it.
ENV PYTHONUNBUFFERED=1 \
    AUTH_HOST=0.0.0.0 \
    AUTH_DB=/data/auth.db

WORKDIR /app

# Requirements first, so editing the service does not reinstall the driver.
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

COPY auth_api.py /app/auth_api.py

# The sqlite fallback's file lives on the mounted volume, not in the image.
RUN mkdir -p /data \
    && useradd --create-home --uid 10001 appuser \
    && chown -R appuser /data

USER appuser

# Informational only: the real port comes from the PORT variable the host
# injects, which auth_api.py picks up automatically.
EXPOSE 8787

CMD ["python", "auth_api.py"]
