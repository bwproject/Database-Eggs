# ProjectBW Multi-Database image with phpMyAdmin
# Keeps the original PotenFYR database runtime and adds PHP CLI + phpMyAdmin.

# Build from the maintained upstream runtime, not a previously published fork image.
# This avoids stale/self-referential base layers when rebuilding this repository.
FROM ghcr.io/potenfyr-studios/database-eggs:latest

USER root

ARG PHPMYADMIN_VERSION=5.2.3

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        php-cli \
        php-mysql \
        php-mbstring \
        php-zip \
        php-gd \
        php-curl \
        php-xml \
        php-bz2 \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /opt/phpmyadmin \
    && curl -fsSL --retry 3 --max-time 300 \
        "https://files.phpmyadmin.net/phpMyAdmin/${PHPMYADMIN_VERSION}/phpMyAdmin-${PHPMYADMIN_VERSION}-all-languages.tar.gz" \
        | tar -xz --strip-components=1 -C /opt/phpmyadmin \
    && mkdir -p /opt/phpmyadmin/tmp \
    && chown -R 988:988 /opt/phpmyadmin \
    && chmod 700 /opt/phpmyadmin/tmp

# The base image is pinned to the upstream runtime release, so explicitly
# install this repository's current launcher and handlers into the image.
# Without these COPY steps, editing run.sh/scripts only changes GitHub and
# the published image keeps the old upstream runtime.
COPY entrypoint.sh /entrypoint.sh
COPY run.sh /usr/local/bin/run.sh
COPY scripts/ /usr/local/bin/

RUN sed -i 's/\r$//' /entrypoint.sh /usr/local/bin/run.sh /usr/local/bin/*.sh 2>/dev/null || true \
    && chmod +x /entrypoint.sh /usr/local/bin/run.sh /usr/local/bin/*.sh 2>/dev/null || true \
    && chown root:root /entrypoint.sh /usr/local/bin/run.sh /usr/local/bin/*.sh 2>/dev/null || true

# The phpMyAdmin installation layer temporarily needs root; restore the
# upstream runtime identity for normal database startup.
USER container
ENV USER=container HOME=/home/container

EXPOSE 8080
