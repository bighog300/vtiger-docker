FROM php:8.2-apache AS builder

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
        libc-client-dev \
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
