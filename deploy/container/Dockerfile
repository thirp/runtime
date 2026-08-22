# Example image for thirp-broker. Build the binary on the host first:
#   odin build broker_cli -out:thirp-broker
#   docker build -f deploy/container/Dockerfile -t thirp-broker .
#
# This is not the only supported deployment. systemd on the host is the
# primary path. See docs/OPERATIONS.md.
#
# Runtime needs OpenSSL 3 (libssl). Mount config, tokens, and TLS material
# at /etc/thirp. Do not publish the metrics port on the public internet.

FROM debian:bookworm-slim

RUN apt-get update \
	&& apt-get install -y --no-install-recommends libssl3 ca-certificates \
	&& rm -rf /var/lib/apt/lists/* \
	&& useradd --system --uid 10001 --gid nogroup --home-dir /nonexistent --shell /usr/sbin/nologin thirp

COPY thirp-broker /usr/local/bin/thirp-broker

USER 10001
VOLUME /etc/thirp
EXPOSE 8443

ENTRYPOINT ["/usr/local/bin/thirp-broker", "--config", "/etc/thirp/broker.conf"]
