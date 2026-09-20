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
# This specific tag was chosen because it scans clean: 1.29.x currently
# carries fixable HIGH/CRITICAL CVEs in pcre2, zlib, musl, libxml2 and
# nghttp2 inherited from its older Alpine layer, and the pipeline's blocking
# gate rejects exactly those. Verified with Trivy before committing rather
# than discovered by a red build.
FROM nginxinc/nginx-unprivileged:1.30-alpine@sha256:daa17b944bac2b578e962da4c61ad72a59233b3c63abea17113acaf4e6b9aea4

# Links the GHCR package back to this repository
LABEL org.opencontainers.image.source="https://github.com/YeHtet95/hello-world-devsecops" \
      org.opencontainers.image.description="Static hello-world page served by nginx" \
      org.opencontainers.image.licenses="MIT"

COPY nginx-hardening.conf /etc/nginx/conf.d/hardening.conf
COPY site/ /usr/share/nginx/html/

EXPOSE 8080

USER 101
