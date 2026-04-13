FROM python:3.11-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        jq \
        procps \
        tini \
    && rm -rf /var/lib/apt/lists/*

ARG HERMES_VERSION=v2026.3.17

COPY patch-hermes-runtime.py /tmp/patch-hermes-runtime.py
COPY minisweagent_path.py /tmp/minisweagent_path.py

# Hermes is not published to PyPI. Install from the pinned upstream release tarball.
RUN python -m pip install --no-cache-dir --upgrade pip \
    && python -m pip install --no-cache-dir \
        "hermes-agent[messaging,cron] @ https://github.com/NousResearch/hermes-agent/archive/refs/tags/${HERMES_VERSION}.tar.gz" \
    && python /tmp/patch-hermes-runtime.py \
    && rm /tmp/minisweagent_path.py /tmp/patch-hermes-runtime.py

ENV PYTHONDONTWRITEBYTECODE=1

COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

ENTRYPOINT ["/usr/bin/tini", "--", "/app/entrypoint.sh"]
