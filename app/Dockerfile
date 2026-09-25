# Base image pinned by digest, not just tag. `1.30-alpine` is a mutable
# pointer — the digest is not
#
# nginx-unprivileged rather than stock nginx: the stock image starts its
# master process as root to bind port 80, then drops privileges only for
# workers. This variant runs as UID 101 throughout and listens on 8080, so
# the container needs no NET_BIND_SERVICE capability and the pod can run
# under runAsNonRoot with all capabilities dropped. The ingress terminates
# on 443 regardless, so binding a privileged port inside the container
# would buy nothing.
#
# Alpine over Debian for a smaller package surface 
# Version choice: the nginx *stable* branch (1.30.x), not mainline. Stable
# receives security fixes without mainline's feature churn, which is what you
# want under an image that is rebuilt on a schedule.
#
# -slim, not just -alpine: this is the second time the base image needed
# bumping after being clean when first pinned. 1.30-alpine picked up a fresh
# HIGH (CVE-2026-93990, libexpat, XML parsing) after Alpine's package index
# moved on — the same package is simply absent from -slim, which strips
# packages the base tag carries but this workload, a static file server,
# never uses. Fewer packages installed is fewer future CVEs to react to, not
# just fewer today. Confirmed unchanged: UID 101, port 8080, writes only to
# /tmp, multi-arch, and it actually serves a request.
FROM nginxinc/nginx-unprivileged:1.30.5-alpine3.24-slim@sha256:307ca0bded4dda86dade6f5bd2a2551601bec9bac3fd73a21613fabcd9eca66a

# Links the GHCR package back to this repository
LABEL org.opencontainers.image.source="https://github.com/YeHtet95/hello-world-devsecops" \
      org.opencontainers.image.description="Static hello-world page served by nginx" \
      org.opencontainers.image.licenses="MIT"

COPY nginx-hardening.conf /etc/nginx/conf.d/hardening.conf
COPY site/ /usr/share/nginx/html/

EXPOSE 8080

USER 101
