# ProjectBW Multi-Database image with phpMyAdmin
# Keeps the original PotenFYR database runtime and adds PHP CLI + phpMyAdmin.

FROM ghcr.io/bwproject/database-eggs:sha-b64a0d2

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

EXPOSE 8080
