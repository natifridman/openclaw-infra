# OpenClaw Gateway - UBI 9 multi-stage build
# Clones source from GitHub, builds, and produces a minimal runtime image.
#
# Build:
#   podman build -t openclaw:latest .
#   podman build --build-arg OPENCLAW_REF=v1.2.3 -t openclaw:v1.2.3 .

# ── Stage 1: Build ──────────────────────────────────────────────
FROM registry.access.redhat.com/ubi9/nodejs-22 AS build

ARG OPENCLAW_REPO=https://github.com/openclaw/openclaw.git
ARG OPENCLAW_REF=main

WORKDIR /opt/app-root/src

# Clone the source from GitHub
USER 0
RUN dnf install -y --disablerepo='*' --enablerepo='ubi-*' git && dnf clean all
USER 1001
RUN git clone --depth 1 --branch "${OPENCLAW_REF}" "${OPENCLAW_REPO}" /tmp/openclaw && \
    cp -a /tmp/openclaw/. . && \
    rm -rf /tmp/openclaw

# Install the exact pnpm version declared in package.json
USER 0
RUN PNPM_VERSION=$(node -p "require('./package.json').packageManager?.split('@')[1] || '10'") && \
    npm install -g "pnpm@$PNPM_VERSION" && \
    chown -R 1001:0 /opt/app-root/src/.npm
USER 1001

# Install dependencies without running postinstall scripts,
# then selectively rebuild only the native addons the gateway needs.
# node-llama-cpp is skipped: it requires cmake and llama.cpp compilation
# for local LLM inference, which is not needed in a gateway deployment
# that connects to remote model providers.
RUN NODE_OPTIONS=--max-old-space-size=2048 pnpm install --frozen-lockfile --ignore-scripts && \
    pnpm rebuild esbuild sharp koffi protobufjs

# Build the A2UI canvas bundle. If this fails (e.g. cross-platform
# QEMU builds), create a stub so the build script's fallback succeeds.
RUN pnpm canvas:a2ui:bundle || \
    (echo "A2UI bundle: creating stub (non-fatal)" && \
     mkdir -p src/canvas-host/a2ui && \
     echo "/* A2UI bundle unavailable in this build */" > src/canvas-host/a2ui/a2ui.bundle.js && \
     echo "stub" > src/canvas-host/a2ui/.bundle.hash && \
     rm -rf vendor/a2ui apps/shared/OpenClawKit/Tools/CanvasA2UI)
RUN pnpm build

ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:build

# ── Stage 2: Runtime ───────────────────────────────────────────
FROM registry.access.redhat.com/ubi9/nodejs-22-minimal

LABEL org.opencontainers.image.source="https://github.com/openclaw/openclaw" \
      org.opencontainers.image.title="OpenClaw (UBI 9)" \
      org.opencontainers.image.description="OpenClaw gateway on UBI 9 Node.js 22 minimal"

WORKDIR /opt/app-root/src

COPY --from=build /opt/app-root/src/dist ./dist
COPY --from=build /opt/app-root/src/node_modules ./node_modules
COPY --from=build /opt/app-root/src/package.json .
COPY --from=build /opt/app-root/src/openclaw.mjs .
COPY --from=build /opt/app-root/src/extensions ./extensions
COPY --from=build /opt/app-root/src/docs ./docs

USER 0
RUN mkdir -p /data/openclaw && \
    chgrp -R 0 /data/openclaw && \
    chmod -R g=u /data/openclaw && \
    ln -sf /opt/app-root/src/openclaw.mjs /usr/local/bin/openclaw && \
    chmod 755 /opt/app-root/src/openclaw.mjs && \
    ln -sf /opt/app-root/src /app
USER 1001

ENV NODE_ENV=production
ENV OPENCLAW_STATE_DIR=/data/openclaw

EXPOSE 18789

HEALTHCHECK --interval=3m --timeout=10s --start-period=15s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:18789/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "openclaw.mjs", "gateway", "--allow-unconfigured"]
