FROM php:8.4-apache

# based on Dockerfile from Alexandre Esser <alexandre@esser.fr>
# https://github.com/42ae/moodle-docker

# Set the Timezone
ENV TZ=Europe/London
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

# Inject Composer Binary (Moodle 501+ requires Composer for plugin management)
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# --- Install Dependencies, Unoconv, PHP Exts, Locales, and Cleanup in one layer ---
RUN set -ex; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        # OS & PHP Build Dependencies
        locales libzip-dev libicu-dev libjpeg-dev libjpeg62-turbo-dev \
        libfreetype6-dev libpng-dev libxml2-dev zlib1g-dev libxslt-dev \
        libmcrypt-dev nano curl wget rsync unzip git libcurl4-openssl-dev \
        libonig-dev iputils-ping libbz2-dev libtidy-dev supervisor openssl \
        # Unoconv & LibreOffice Dependencies
        ghostscript python3 python3-pip libreoffice libreoffice-writer \
        libreoffice-calc libreoffice-draw libreoffice-impress; \
    \
    # 1. Setup Unoconv
    python3 -m pip install --break-system-packages setuptools; \
    git clone https://github.com/unoconv/unoconv.git /opt/unoconv; \
    sed -i '1s|/usr/bin/env python|/usr/bin/env python3|' /opt/unoconv/unoconv; \
    chmod ugo+x /opt/unoconv/unoconv; \
    ln -s /opt/unoconv/unoconv /usr/bin/unoconv; \
    \
    # 2. Setup Locales (Much cleaner than multiple sed commands)
    echo "C.UTF-8 UTF-8\nde_DE.UTF-8 UTF-8\nen_US.UTF-8 UTF-8\nen_GB.UTF-8 UTF-8\nes_ES.UTF-8 UTF-8\nfr_FR.UTF-8 UTF-8\nko_KR.UTF-8 UTF-8\nky_KG UTF-8\nnl_NL.UTF-8 UTF-8\nru_RU.UTF-8 UTF-8\nzh_CN.UTF-8 UTF-8" > /etc/locale.gen; \
    locale-gen; \
    \
    # 3. Setup PHP Extensions
    docker-php-ext-configure gd --with-freetype --with-jpeg; \
    docker-php-ext-install -j$(nproc) gd intl bcmath calendar exif pdo_mysql mysqli soap zip xsl curl bz2 tidy; \
    pecl install redis; \
    docker-php-ext-enable redis; \
    \
    # 4. Final Cleanup
    apt-get autoremove -y; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# --- Apache & SSL Setup ---
RUN a2enmod rewrite expires ssl && \
    mkdir -p /etc/apache2/certs && \
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout /etc/apache2/certs/ssl-cert.key \
    -out /etc/apache2/certs/ssl-cert.pem \
    -subj "/C=GB/ST=London/L=London/O=IT/CN=localhost"

# --- Moodle Core ---
ENV MOODLE_BRANCH=501
ENV MOODLE_RELEASE=501

RUN set -ex; \
    curl -o moodle.tgz -fSL "https://download.moodle.org/download.php/direct/stable${MOODLE_BRANCH}/moodle-latest-${MOODLE_RELEASE}.tgz"; \
    tar -xzf moodle.tgz -C /usr/src/; \
    rm moodle.tgz; \
    chown -R www-data:www-data /usr/src/moodle

RUN mkdir -p /var/www/moodledata && \
    mkdir -p /var/www/.cache && \
    chown -R www-data:www-data /var/www

# --- Inject Custom Configurations ---
# Copy Apache site configuration and ensure it's enabled
COPY ./apache/site.conf /etc/apache2/sites-available/000-default.conf
RUN a2ensite 000-default.conf

# Copy PHP overrides
COPY ./apache/php-overrides.ini /usr/local/etc/php/conf.d/php-overrides.ini

# Copy Entrypoint and Supervisor Config
COPY docker-entrypoint.sh /usr/local/bin/
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

VOLUME ["/var/www/html", "/var/www/moodledata"]

# Add the upgrade manager
COPY upgrade_manager.py /usr/local/bin/moodle-upgrade
RUN chmod +x /usr/local/bin/moodle-upgrade

ENTRYPOINT ["docker-entrypoint.sh"]

# Change CMD to start supervisor instead of directly starting Apache
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
