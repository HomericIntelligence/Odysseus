# HomericIntelligence IPC E2E — Single Container (T3)
# Runs NATS + Agamemnon + hello-myrmidon + test harness in one container.

# ── Stage 1: Build Agamemnon ─────────────────────────────────────────────────
FROM ubuntu:24.04 AS agamemnon-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    cmake ninja-build g++ git ca-certificates libssl-dev python3 python3-pip \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 install --break-system-packages conan

WORKDIR /src
COPY control/ProjectAgamemnon/conanfile.py ./
COPY control/ProjectAgamemnon/conan/ conan/
RUN conan install . --output-folder=build --profile=conan/profiles/default --build=missing

COPY control/ProjectAgamemnon/CMakeLists.txt ./
COPY control/ProjectAgamemnon/CMakePresets.json ./
COPY control/ProjectAgamemnon/cmake/ cmake/
COPY control/ProjectAgamemnon/include/ include/
COPY control/ProjectAgamemnon/src/ src/
COPY control/ProjectAgamemnon/test/ test/

RUN cmake -B build -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE=build/conan_toolchain.cmake \
    -DCMAKE_BUILD_TYPE=Release \
    -DProjectAgamemnon_BUILD_TESTING=OFF \
    -DProjectAgamemnon_ENABLE_CLANG_TIDY=OFF \
    -DProjectAgamemnon_ENABLE_CPPCHECK=OFF \
    -DProjectAgamemnon_WARNINGS_AS_ERRORS=OFF \
    && cmake --build build --target ProjectAgamemnon_server

# ── Stage 2: Runtime with all 3 processes ────────────────────────────────────
FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    libssl3 wget curl python3 python3-pip ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install NATS server
RUN wget -qO /tmp/nats.tar.gz \
    "https://github.com/nats-io/nats-server/releases/download/v2.10.24/nats-server-v2.10.24-linux-amd64.tar.gz" \
    && tar xzf /tmp/nats.tar.gz -C /tmp \
    && mv /tmp/nats-server-v2.10.24-linux-amd64/nats-server /usr/local/bin/ \
    && rm -rf /tmp/nats*

# Install Python NATS client
RUN pip3 install --break-system-packages --no-cache-dir nats-py

# Copy Agamemnon binary
COPY --from=agamemnon-builder /src/build/ProjectAgamemnon_server /usr/local/bin/

# Copy hello-myrmidon
COPY provisioning/Myrmidons/hello-world/main.py /app/myrmidon/main.py

# Copy test infrastructure
COPY e2e/lib/ /app/e2e/lib/
COPY e2e/tests/ /app/e2e/tests/
COPY e2e/single-container/entrypoint.sh /entrypoint.sh
COPY e2e/single-container/run-test.sh /run-test.sh

RUN chmod +x /entrypoint.sh /run-test.sh

RUN mkdir -p /var/lib/nats/jetstream

ENV NATS_URL=nats://localhost:4222
ENV NATS_MONITOR_PORT=8222
ENV AGAMEMNON_PORT=8080

ENTRYPOINT ["/entrypoint.sh"]
