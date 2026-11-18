# Hong Scanner single-container contract (Northflank Phase-0, PR-2;
# runtime supervisor PR-4): one always-running process — the cloud
# runtime supervisor (tools/container/cloud_supervisor.py, contract:
# tools/container/README.md §7), which itself starts and supervises the
# read-only API server (tools/api/serve.py, contract:
# tools/api/README.md §1/§5).
#
# Build context contract (tools/container/README.md §2): this Dockerfile
# COPYs relative paths only. A Docker COPY can never reach outside the
# build context (leading/trailing ".." path components are normalized
# away — docs.docker.com). Whoever builds the image stages the needed
# files into a fresh directory first (mktemp) and passes THAT directory
# as the context:
#   Dockerfile · bin/hongscanner · bin/collector · tools/api/serve.py
#   tools/container/cloud_supervisor.py
#   tools/collector/sidecar.py · tools/collector/requirements.txt
#   tools/notify/{notify_dispatcher,notify_config,notify_fcm,
#                 notify_ledger}.py
#   calendars/CALENDAR_INDEX.sha256
# The production image is built the same way by the attestation job
# (attest.yml, PR-5) from the two attested CI_BUILD_OUT binaries. This
# file is the shared build contract, never a build-from-source recipe.
#
# Binary contract (tools/container/README.md §3): test binaries and the
# production binary are separate artifacts. An image carrying a locally
# compiled (test) binary MUST carry the
# org.hongscanner.image-purpose=ci-test label — a not-for-deployment
# marker asserted by tests/test_container_contract.sh; the production
# image (PR-5) carries no such marker. The dev build left at the
# repository root (./hongscanner) is an accident leftover: never use,
# delete or overwrite it.
#
# Calendar trust boundary (tools/container/README.md §4): the
# git-tracked calendars/CALENDAR_INDEX.sha256 (canonical main source)
# is baked into the image. The actual calendars/*.json are gitignored
# user data and never enter an image or a build context
# (.dockerignore); in operation the Northflank persistent volume
# supplies them and is cross-checked against the baked index (run
# enforced from PR-4).
FROM python:3.13-slim

# Secret boundary (tools/container/README.md §8): NO credential ever
# enters this image or its build context — APP_KEY_MOCK / APP_SECRET_MOCK
# and the FCM service-account JSON are runtime secrets injected by the
# Northflank Secret Group env; the .dockerignore whitelist passes none of
# them, and nothing here bakes, mounts or references any credential.

# serve.py is standard library only (http.server) — nothing is installed
# for it, ever (tools/api/README.md §0). The one pip install below
# belongs to the collector sidecar and is exactly the version-pinned
# dependency its wire contract is measured against
# (tools/collector/requirements.txt: websockets==17.3).
COPY tools/api/serve.py /opt/hongscanner/serve.py
# The session-time authority (P30) keeps its repo-relative tools/ path in
# the image: serve.py and the notify dispatcher both resolve
# market_time.py through the same directory they use in the checkout
# (serve.py's bootstrap below, dispatcher's _TOOLS_DIR).
COPY tools/market_time.py /opt/hongscanner/tools/market_time.py
COPY bin/hongscanner /opt/hongscanner/bin/hongscanner
COPY calendars/CALENDAR_INDEX.sha256 /opt/hongscanner/CALENDAR_INDEX.sha256

# PR-5 supply chain (tools/container/README.md §8): the collector binary
# and the sidecar/notify adapters join the image. collector.nim resolves
# the sidecar SCRIPT next to its own binary (getAppDir()/sidecar.py,
# collector.nim:74-79) and the sidecar INTERPRETER through
# $HSCOLLECTOR_PYTHON first (collector.nim:62-72) — pinned by ENV below.
# The notify dispatcher imports its siblings flat (notify_clock /
# notify_config / notify_fcm / notify_ledger), so all five live in one
# directory. notify_clock was the second missing module of the
# market_time class: the dispatcher's module-level import failed inside
# the image while every suite stayed green (tests/test_container_contract.sh
# now derives this set from the imports instead of trusting this list). The
# final entry-point wiring (which process the supervisor starts with
# which args/env) is PR-4's cloud_supervisor surface: after PR-4 merges,
# the supervisor's environment variables name these paths (README §8).
COPY bin/collector /opt/hongscanner/bin/collector
COPY tools/collector/sidecar.py /opt/hongscanner/bin/sidecar.py
COPY tools/collector/requirements.txt /opt/hongscanner/tools/collector/requirements.txt
COPY tools/notify/notify_dispatcher.py /opt/hongscanner/tools/notify/notify_dispatcher.py
COPY tools/notify/notify_clock.py /opt/hongscanner/tools/notify/notify_clock.py
COPY tools/notify/notify_config.py /opt/hongscanner/tools/notify/notify_config.py
COPY tools/notify/notify_fcm.py /opt/hongscanner/tools/notify/notify_fcm.py
COPY tools/notify/notify_ledger.py /opt/hongscanner/tools/notify/notify_ledger.py

# PR-4 runtime supervisor (tools/container/README.md §7): the container
# process. Standard library only — nothing is installed for it, ever.
COPY tools/container/cloud_supervisor.py /opt/hongscanner/cloud_supervisor.py

RUN pip install --no-cache-dir \
      -r /opt/hongscanner/tools/collector/requirements.txt

# collector.nim checks $HSCOLLECTOR_PYTHON before the venv-slice and
# system fallbacks; the image pins the base interpreter explicitly so the
# sidecar runs on the interpreter pip installed websockets==17.3 into.
ENV HSCOLLECTOR_PYTHON=python3

# Supervisor env pins (PR-4): exactly the cloud_supervisor.py defaults,
# made explicit so the image surface carries its own wiring (README §7).
# Platform-side env (Northflank Secret Group) may override these; that
# is the documented override path, not a setup requirement.
ENV HS_API_BIND=0.0.0.0 \
    HS_API_PORT=8080 \
    HS_SUPERVISOR_PROBE_PORT=8081 \
    HS_DATA_ROOT=/var/lib/hongscanner \
    HS_CALENDAR_DIR=/var/lib/hongscanner/calendars \
    HS_CALENDAR_INDEX=/opt/hongscanner/CALENDAR_INDEX.sha256

# Code lives under /opt/hongscanner, data under /var/lib/hongscanner:
# runs/ and notify/ are persistent-volume mount points (README §5) and
# never carry baked content — the ledger in particular is
# volume-supplied, never baked. The runs root must exist: serve.py
# exits 2 without an existing --runs directory.
RUN groupadd --system hongscanner \
 && useradd --system --gid hongscanner \
      --home-dir /var/lib/hongscanner --shell /usr/sbin/nologin \
      hongscanner \
 && mkdir -p /var/lib/hongscanner/runs /var/lib/hongscanner/notify \
 && chown -R hongscanner:hongscanner /var/lib/hongscanner \
 && chmod 0755 /opt/hongscanner/bin/hongscanner \
 && chmod 0755 /opt/hongscanner/bin/collector

USER hongscanner
WORKDIR /opt/hongscanner
EXPOSE 8080 8081
STOPSIGNAL SIGTERM

# PR-4 ENTRYPOINT (tools/container/README.md §7): the cloud runtime
# supervisor is the container process. It starts and restarts its
# children — the API server (serve.py) always, the collector/notify
# worker per KST session windows — and serves the Northflank probes
# (/startup · /ready · /live) on 8081. STOPSIGNAL SIGTERM drains it:
# the supervisor terminates its children and exits 0 (docker stop
# contract, exercised by tests/test_container_contract.sh).
#
# The API child binds 0.0.0.0 (ENV HS_API_BIND above) — container-only
# behind the Northflank platform ingress: this API has no
# authentication of its own, access control for 0.0.0.0 is delegated to
# the platform ingress Basic Auth, and direct internet exposure of a
# non-loopback bind is a contract violation (tools/api/README.md §1/§5).
# Local operation keeps the default 127.0.0.1.
ENTRYPOINT ["python3", "/opt/hongscanner/cloud_supervisor.py"]
