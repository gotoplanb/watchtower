# rust-build sandbox — local-only toolchain runner for the Conduct code-gen
# eval flywheel (gotoplanb/watchtower#1, gotoplanb/conduct#24). Not deployed to
# the cloud; runs in docker-compose alongside SonarQube.
FROM rust:1-slim-bookworm

# python3 runs the tiny stdlib HTTP service (no pip). clippy for the structural
# checks (conduct#29) reuses this same image later.
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 \
    && rm -rf /var/lib/apt/lists/* \
    && rustup component add clippy

# Non-root: a crate's build.rs and tests execute arbitrary code here, so keep
# the blast radius small. The shared rustc toolchain in /usr/local is readable;
# CARGO_HOME points at the builder's home for a writable registry cache.
# Pre-create $CARGO_HOME owned by builder so the named cache volume inherits
# builder ownership on first mount (else it'd be root-owned -> cargo can't
# write the registry cache when fetching a dev-dependency like proptest).
ENV CARGO_HOME=/home/builder/.cargo
RUN useradd --create-home --uid 10001 builder \
    && mkdir -p "$CARGO_HOME" \
    && chown -R builder:builder /home/builder
USER builder
WORKDIR /home/builder

COPY --chown=builder:builder app.py /home/builder/app.py
EXPOSE 8080
CMD ["python3", "/home/builder/app.py"]
