# ============================================================
# Stage 1: builder
# Clones vtiger source, compiles PHP extensions, runs installer.
# ============================================================
FROM php:8.2-apache-bookworm AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
        curl \
        unzip \
        git \
        default-mysql-client \
        libpng-dev \
        libjpeg-dev \
        libfreetype6-dev \
        libxml2-dev \
        libzip-dev \
        libkrb5-dev \
        libc-client2007e-dev \
        libssl-dev \
        zlib1g-dev \
        libonig-dev \
        gettext-base \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j$(nproc) \
        mysqli \
        pdo_mysql \
        gd \
        zip \
        xml \
        mbstring \
        soap \
    && docker-php-ext-configure imap --with-kerberos --with-imap-ssl \
    && docker-php-ext-install -j$(nproc) imap \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

WORKDIR /app
RUN git clone --depth=1 https://github.com/bighog300/vtigercrm.git .

COPY init-scripts/install.sh        /build/install.sh
COPY init-scripts/export-schema.sh  /build/export-schema.sh
COPY config/config.inc.php.tpl      /build/config.inc.php.tpl
RUN chmod +x /build/install.sh /build/export-schema.sh

# ============================================================
# Stage 2: runtime
# Copies compiled app + extensions from builder.
# schema.sql is added by build.sh after installer runs.
# ============================================================
FROM php:8.2-apache-bookworm AS runtime

LABEL org.opencontainers.image.source="https://github.com/bighog300/vtiger-docker"
LABEL org.opencontainers.image.description="vtiger CRM 8.3.0"
LABEL org.opencontainers.image.licenses="VPL-1.1"

RUN apt-get update && apt-get install -y --no-install-recommends \
        default-mysql-client \
        libpng16-16 \
        libjpeg62-turbo \
        libfreetype6 \
        libxml2 \
        libzip4 \
        libkrb5-3 \
        libc-client2007e \
        curl \
        rsync \
        gettext-base \
    && a2enmod rewrite \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local/lib/php/extensions/ /usr/local/lib/php/extensions/
COPY --from=builder /usr/local/etc/php/conf.d/     /usr/local/etc/php/conf.d/

COPY --from=builder /app /var/www/html

COPY init-scripts/entrypoint.sh  /opt/vtiger/entrypoint.sh
COPY config/config.inc.php.tpl   /opt/vtiger/config.inc.php.tpl
RUN chmod +x /opt/vtiger/entrypoint.sh

COPY schema.sql /opt/vtiger/schema.sql

RUN chown -R www-data:www-data /var/www/html \
    && find /var/www/html -type d -exec chmod 755 {} \; \
    && find /var/www/html -type f -exec chmod 644 {} \;

EXPOSE 80
ENTRYPOINT ["/opt/vtiger/entrypoint.sh"]
