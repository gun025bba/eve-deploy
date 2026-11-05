# CI runner image: an ephemeral container in the isolated Linux VM (colima profile "eveci") on the deploy Mac.
# One container = one job. Non-root user, no sudo, no secrets in the image. Runner version and sha256 are pinned.
FROM ubuntu:24.04
ARG RUNNER_VERSION=2.338.2
ARG RUNNER_SHA256=670adb2f268fe21dcbb58b3db0e0aa9d5b3bddfe2c651481336e561ff86de945
ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git jq gnupg unzip zip xz-utils tzdata build-essential \
      python3 python3-venv python3-pip fonts-nanum fonts-noto-core \
 && install -d -m 0755 /etc/apt/keyrings \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli.gpg \
 && echo "deb [arch=arm64 signed-by=/etc/apt/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" >/etc/apt/sources.list.d/github-cli.list \
 && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /etc/apt/keyrings/pgdg.gpg \
 && echo "deb [signed-by=/etc/apt/keyrings/pgdg.gpg] https://apt.postgresql.org/pub/repos/apt noble-pgdg main" >/etc/apt/sources.list.d/pgdg.list \
 && apt-get update && apt-get install -y --no-install-recommends gh postgresql-17 postgresql-17-pgvector \
 && systemctl disable postgresql 2>/dev/null; rm -rf /var/lib/apt/lists/*
# Playwright browser + its system libraries (web tests; version = tests/requirements.txt of eve-web). The job's `playwright install chromium` is a
# no-op when the version matches and downloads the other one into this (container-local, throwaway) directory when it does not.
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers
RUN python3 -m venv /tmp/pwv && /tmp/pwv/bin/pip install --no-cache-dir playwright==1.64.1 \
 && /tmp/pwv/bin/python -m playwright install-deps chromium && /tmp/pwv/bin/python -m playwright install chromium \
 && chmod -R a+rwX /opt/pw-browsers && rm -rf /tmp/pwv /var/lib/apt/lists/*
RUN useradd -m -u 1001 -s /bin/bash runner \
 && mkdir -p /opt/actions-runner && cd /opt/actions-runner \
 && curl -fsSL --retry 5 -o r.tgz "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-arm64-${RUNNER_VERSION}.tar.gz" \
 && echo "${RUNNER_SHA256}  r.tgz" | sha256sum -c - && tar -xzf r.tgz && rm r.tgz \
 && ./bin/installdependencies.sh && rm -rf /var/lib/apt/lists/*
# postgresql-17-pgvector: the personal-memory migrations run CREATE EXTENSION vector against this cluster (production has the extension already)
# the postgres cluster in scripts/ci-pg.sh is created per job under $RUNNER_TEMP by the runner user
ENV CI_PG_BIN=/usr/lib/postgresql/17/bin
COPY entrypoint.sh /usr/local/bin/eve-ci-entrypoint
RUN chmod 0755 /usr/local/bin/eve-ci-entrypoint
USER runner
WORKDIR /home/runner
ENTRYPOINT ["/usr/local/bin/eve-ci-entrypoint"]
