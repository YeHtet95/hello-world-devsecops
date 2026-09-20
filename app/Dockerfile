# Base image pinned by digest, not just tag. `1.29.1-alpine` is a mutable
# pointer — the digest is not, so the image CI builds today is the image a
# reviewer builds next week. Bumping this is a deliberate one-line PR that
# re-runs every scan in the pipeline.
#
# nginx-unprivileged rather than stock nginx: the stock image starts its
# master process as root to bind port 80, then drops privileges only for
# workers. This variant runs as UID 101 throughout and listens on 8080, so
# the container needs no NET_BIND_SERVICE capability and the pod can run
# under runAsNonRoot with all capabilities dropped. The ingress terminates
# on 443 regardless, so binding a privileged port inside the container
# would buy nothing.
#
# Alpine over Debian for a smaller package surface — fewer installed
# packages is fewer CVEs to triage for something serving one static file.
FROM nginxinc/nginx-unprivileged:1.29.1-alpine@sha256:27985295bdb22a1ef8f712863210bd5877c0f3006494a593e86b3fe0fa55467e

# Links the GHCR package back to this repository, and gives scanners and
# `docker inspect` provenance to work from.
LABEL org.opencontainers.image.source="https://github.com/YeHtet95/hello-world-devsecops" \
      org.opencontainers.image.description="Static hello-world page served by nginx" \
      org.opencontainers.image.licenses="MIT"

COPY nginx-hardening.conf /etc/nginx/conf.d/hardening.conf
COPY site/ /usr/share/nginx/html/

# Documentation only — the port the base image already listens on as UID 101.
EXPOSE 8080

# Inherited from the base image, restated so it is visible at review time
# rather than requiring someone to go and read the base image's Dockerfile.
USER 101
