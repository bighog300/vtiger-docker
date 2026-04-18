# ============================================================
# Stage 1: builder
# Clone source from GitHub, run composer, run headless install,
# export schema dump — then discard MySQL and build tools.
# ============================================================
FROM php:8.2-apache AS builder

# System deps
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
        libc-client-dev \
        libkrb5-dev \
        libssl-dev \
        zlib1g-dev \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-configure imap --with-kerberos --with-imap-ssl \
    && docker-php-ext-install -j$(nproc) \
        mysqli \
        pdo_mysql \
        gd \
        imap \
        curl \
        zip \
        xml \
        mbstring \
        soap \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install composer
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# Pull vtiger source from GitHub
WORKDIR /app
RUN git clone --depth=1 https://github.com/bighog300/vtigercrm.git . \
    && composer install --no-dev --optimize-autoloader --no-interaction

# Copy build-time scripts
COPY init-scripts/install.sh        /build/install.sh
COPY init-scripts/export-schema.sh  /build/export-schema.sh
COPY config/config.inc.php.tpl      /build/config.inc.php.tpl
RUN chmod +x /build/install.sh /build/export-schema.sh

# ============================================================
# Stage 2: final runtime image
# Copies the installed app + baked-in schema.sql
# ============================================================
FROM php:8.2-apache AS runtime

LABEL org.opencontainers.image.source="https://github.com/bighog300/vtigercrm"
LABEL org.opencontainers.image.description="vtiger CRM 8.3.0"
LABEL org.opencontainers.image.licenses="VPL-1.1"

# Runtime system deps (no build tools)
RUN apt-get update && apt-get install -y --no-install-recommends \
        default-mysql-client \
        libpng16-16 \
        libjpeg62-turbo \
        libfreetype6 \
        libxml2 \
        libzip4 \
        libc-client2007e \
        libkrb5-3 \
        curl \
        rsync \
        gettext-base \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-configure imap --with-kerberos --with-imap-ssl \
    && docker-php-ext-install -j$(nproc) \
        mysqli \
        pdo_mysql \
        gd \
        imap \
        curl \
        zip \
        xml \
        mbstring \
        soap \
    && a2enmod rewrite \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Copy installed app from builder
COPY --from=builder /app /var/www/html

# Copy runtime scripts and config template
COPY init-scripts/entrypoint.sh        /opt/vtiger/entrypoint.sh
COPY config/config.inc.php.tpl         /opt/vtiger/config.inc.php.tpl
RUN chmod +x /opt/vtiger/entrypoint.sh

# schema.sql is copied in by build.sh after the install stage runs
# It is baked into the final image so runtime import takes ~5 seconds
COPY schema.sql /opt/vtiger/schema.sql

# Permissions
RUN chown -R www-data:www-data /var/www/html \
    && find /var/www/html -type d -exec chmod 755 {} \; \
    && find /var/www/html -type f -exec chmod 644 {} \;

EXPOSE 80

ENTRYPOINT ["/opt/vtiger/entrypoint.sh"]
