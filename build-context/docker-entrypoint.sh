#!/bin/bash
set -euo pipefail

# usage: file_env VAR [DEFAULT]
#    ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
file_env() {
  local var="$1"
  local fileVar="${var}_FILE"
  local def="${2:-}"

  if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
    echo >&2 "error: both $var and $fileVar are set (but are exclusive)"
    exit 1
  fi

  local val="$def"

  if [ "${!var:-}" ]; then
    val="${!var}"
  elif [ "${!fileVar:-}" ]; then
    val="$(< "${!fileVar}")"
  fi

  export "$var"="$val"
  unset "$fileVar"
}


if [[ "$1" == apache2* ]] || [[ "$1" == /usr/bin/supervisord* ]]; then

  if [[ ! -e "version.php" && ! -e "public/version.php" ]]; then
    echo >&2 "Moodle not found in $PWD - copying now..."

    if [ "$(ls -A)" ]; then
      echo >&2 "WARNING: $PWD is not empty - press Ctrl+C now if this is an error!"
      ( set -x; ls -A; sleep 10 )
    fi

    tar cf - --one-file-system -C /usr/src/moodle . | tar xf -

    echo >&2 "Complete! Moodle has been successfully copied to $PWD"
  fi

  envs=(
    MOODLE_DB_TYPE
    MOODLE_DB_HOST
    MOODLE_DB_PORT
    MOODLE_DB_NAME
    MOODLE_DB_USER
    MOODLE_DB_PASSWORD
    MOODLE_DB_PREFIX
    MOODLE_WWW_ROOT
    MOODLE_DATA_ROOT
  )

  haveConfig=

  for e in "${envs[@]}"; do
    file_env "$e"

    if [ -z "$haveConfig" ] && [ -n "${!e}" ]; then
      haveConfig=1
    fi
  done

  # linking backwards-compatibility
  if [ -n "${!MYSQL_ENV_MYSQL_*}" ]; then
    haveConfig=1

    # host defaults to "mysql" below if unspecified
    : "${MOODLE_DB_USER:=${MYSQL_ENV_MYSQL_USER:-root}}"

    if [ "$MOODLE_DB_USER" = 'root' ]; then
      : "${MOODLE_DB_PASSWORD:=${MYSQL_ENV_MYSQL_ROOT_PASSWORD:-}}"
    else
      : "${MOODLE_DB_PASSWORD:=${MYSQL_ENV_MYSQL_PASSWORD:-}}"
    fi

    : "${MOODLE_DB_NAME:=${MYSQL_ENV_MYSQL_DATABASE:-}}"
  fi

  # only touch "config-dist.php" if we have environment-supplied
  # configuration values
  if [ "$haveConfig" ]; then

    : "${MOODLE_DB_TYPE:=mysqli}"
    : "${MOODLE_DB_HOST:=database}"
    : "${MOODLE_DB_PORT:=3306}"
    : "${MOODLE_DB_NAME:=moodle}"
    : "${MOODLE_DB_USER:=root}"
    : "${MOODLE_DB_PASSWORD:=}"
    : "${MOODLE_DB_PREFIX:=mdl_}"
    : "${MOODLE_WWW_ROOT:=}"
    : "${MOODLE_DATA_ROOT:=/var/www/moodledata}"

    if [ ! -e "config.php" ]; then
      mv config-dist.php config.php
      chown www-data:www-data config.php
    fi

    # see http://stackoverflow.com/a/2705678/433558
    sed_escape_lhs() {
      echo "$@" | sed -e 's/[]\/$*.^|[]/\\&/g'
    }

    sed_escape_rhs() {
      echo "$@" | sed -e 's/[\/&]/\\&/g'
    }

    php_escape() {
      php -r 'var_export(('$2') $argv[1]);' -- "$1"
    }

    set_config() {
      key="$1"
      value="$2"
      var_type="${3:-string}"
      start="(\\\$CFG->)$(sed_escape_lhs "$key")\s*="
      end=";.*"

      # port is defined as a multidimensional array in config.php
      if [ "$key" == "dbport" ]; then
        start="(['\"])$(sed_escape_lhs "$key")\2\s*=>"
        end=",.*"
      fi

      sed -ri -e \
        "s/($start\s*).*($end)$/\1$(sed_escape_rhs "$(php_escape "$value" "$var_type")")\3/" \
        config.php
    }

    set_config 'dbtype'   "$MOODLE_DB_TYPE"
    set_config 'dbhost'   "$MOODLE_DB_HOST"
    set_config 'dbport'   "$MOODLE_DB_PORT"
    set_config 'dbname'   "$MOODLE_DB_NAME"
    set_config 'dbuser'   "$MOODLE_DB_USER"
    set_config 'dbpass'   "$MOODLE_DB_PASSWORD"
    set_config 'prefix'   "$MOODLE_DB_PREFIX"
    set_config 'wwwroot'  "$MOODLE_WWW_ROOT"
    set_config 'dataroot' "$MOODLE_DATA_ROOT"

    TERM=dumb php -- <<'EOPHP'
<?php

// Database might not exist, so let's try creating it (just to be safe).

$stderr = fopen('php://stderr', 'w');

mysqli_report(MYSQLI_REPORT_OFF); // Prevent fatal exceptions in PHP 8.1+.

$host = getenv('MOODLE_DB_HOST');
$port = getenv('MOODLE_DB_PORT');
$user = getenv('MOODLE_DB_USER');
$pass = getenv('MOODLE_DB_PASSWORD');
$dbName = getenv('MOODLE_DB_NAME');
$socket = null;

$maxTries = 20;

do {
    $mysql = new mysqli(
        $host,
        $user,
        $pass,
        '',
        $port,
        $socket
    );

    if ($mysql->connect_error) {
        fwrite(
            $stderr,
            "\n" .
            'MySQL Connection Error: (' .
            $mysql->connect_errno .
            ') ' .
            $mysql->connect_error .
            "\n"
        );

        --$maxTries;

        if ($maxTries <= 0) {
            exit(1);
        }

        sleep(3);
    }
} while ($mysql->connect_error);

if (
    !$mysql->query(
        'CREATE DATABASE IF NOT EXISTS `' .
        $mysql->real_escape_string($dbName) .
        '`'
    )
) {
    fwrite(
        $stderr,
        "\n" .
        'MySQL "CREATE DATABASE" Error: ' .
        $mysql->error .
        "\n"
    );

    $mysql->close();
    exit(1);
}

$mysql->close();
EOPHP

  fi

  # Now that we're definitely done writing configuration, clear out the
  # relevant environment variables so stray phpinfo() calls do not leak
  # secrets from our code.
  for e in "${envs[@]}"; do
    unset "$e"
  done

fi


# ------------------------------------------------------------------
# Moodle Data Directory
# ------------------------------------------------------------------

mkdir -p /var/www/moodledata
chown www-data:www-data /var/www/moodledata


# ------------------------------------------------------------------
# Apache Configuration
# ------------------------------------------------------------------
#
# Moodle 5.x+ security standards require the web root to be /public,
# so check for that and adjust Apache configuration accordingly.
# ------------------------------------------------------------------

APACHE_CONF="/etc/apache2/sites-available/000-default.conf"

# Enable required Apache modules.
a2enmod ssl > /dev/null
a2enmod headers > /dev/null

echo "[+] Checking Moodle directory structure..."

if [ -w "$APACHE_CONF" ]; then

    if [ -d "/var/www/html/public" ]; then
        echo "[+] Found /public directory. Configuring Apache for Moodle 5.x+ security."

        sed \
            's|DocumentRoot /var/www/html$|DocumentRoot /var/www/html/public|g' \
            "$APACHE_CONF" > /tmp/apache.tmp

        cat /tmp/apache.tmp > "$APACHE_CONF"

    else
        echo "[!] No /public directory found. Falling back to legacy root."

        sed \
            's|/var/www/html/public|/var/www/html|g' \
            "$APACHE_CONF" > /tmp/apache.tmp

        cat /tmp/apache.tmp > "$APACHE_CONF"
    fi

    rm -f /tmp/apache.tmp

else
    echo "[+] Apache conf is read-only. Skipping dynamic path injection."
fi


# ------------------------------------------------------------------
# Moodle config.php Configuration
# ------------------------------------------------------------------
#
# Ensure Moodle handles reverse-proxy SSL, Moodle 5.x routing, and
# Redis-backed sessions correctly.
# ------------------------------------------------------------------

CONFIG_PHP="/var/www/html/config.php"

if [ -f "$CONFIG_PHP" ]; then

    # Stricter grep to avoid the commented // $_SERVER['HTTPS'] line.
    if ! grep -q "\$_SERVER\['HTTPS'\]" "$CONFIG_PHP"; then

        echo "[+] Injecting HTTPS bypass settings into config.php..."

        sed -i \
            "/require_once.*setup\.php/i \$_SERVER['HTTPS'] = 'on';" \
            "$CONFIG_PHP"

        sed -i \
            "/require_once.*setup\.php/i \$_SERVER['SERVER_PORT'] = 443;" \
            "$CONFIG_PHP"

        sed -i \
            "/require_once.*setup\.php/i \$CFG->sslproxy = true;" \
            "$CONFIG_PHP"
    fi


    # Enable Moodle 5.x Router.
    if grep -q "routerconfigured = false" "$CONFIG_PHP"; then

        echo "[+] Enabling Moodle 5.x Router in config.php (replacing false)..."

        sed -i \
            "s/\$CFG->routerconfigured = false;/\$CFG->routerconfigured = true;/g" \
            "$CONFIG_PHP"

    elif ! grep -q "routerconfigured = true" "$CONFIG_PHP"; then

        echo "[+] Injecting Router configuration into config.php..."

        sed -i \
            "/require_once.*setup\.php/i \$CFG->routerconfigured = true;" \
            "$CONFIG_PHP"
    fi

    # Prevent executable paths from being changed through the Moodle Admin GUI.
    #
    # Match only an active PHP assignment at the beginning of a line.
    # This avoids matching Moodle's commented example:
    #
    #   // $CFG->preventexecpath = true;
    #
    if ! grep -Eq \
        '^[[:space:]]*\$CFG->preventexecpath[[:space:]]*=[[:space:]]*true[[:space:]]*;' \
        "$CONFIG_PHP"; then

        echo "[+] Enabling executable path protection in config.php..."

        sed -i \
            "/require_once.*setup\.php/i \$CFG->preventexecpath = true;" \
            "$CONFIG_PHP"
    fi

    # Stricter grep to avoid the commented // $CFG->session_redis_host line.
    # Configure Redis-backed Moodle sessions.
    if ! grep -Eq \
        '^[[:space:]]*\$CFG->session_handler_class[[:space:]]*=' \
        "$CONFIG_PHP"; then

        echo "[+] Injecting Redis session configuration into config.php..."

        sed -i \
            "/require_once.*setup\.php/i \$CFG->session_handler_class = '\\\\core\\\\session\\\\redis';" \
            "$CONFIG_PHP"

        sed -i \
            "/require_once.*setup\.php/i \$CFG->session_redis_host = 'redis';" \
            "$CONFIG_PHP"

        sed -i \
            "/require_once.*setup\.php/i \$CFG->session_redis_port = 6379;" \
            "$CONFIG_PHP"

        sed -i \
            "/require_once.*setup\.php/i \$CFG->session_redis_database = 1;" \
            "$CONFIG_PHP"

        sed -i \
            "/require_once.*setup\.php/i \$CFG->session_redis_prefix = 'moodle_session_';" \
            "$CONFIG_PHP"

        sed -i \
            "/require_once.*setup\.php/i \$CFG->session_redis_acquire_lock_timeout = 10;" \
            "$CONFIG_PHP"

        sed -i \
            "/require_once.*setup\.php/i \$CFG->session_redis_lock_expire = 120;" \
            "$CONFIG_PHP"
    fi

fi

a2ensite 000-default.conf > /dev/null


# ------------------------------------------------------------------
# Moodle Installation and Deployment Defaults
# ------------------------------------------------------------------
#
# Automatic installation mode:
#
#   1. Detect an empty Moodle database.
#   2. Install Moodle through install_database.php.
#   3. Apply deployment-managed defaults synchronously.
#   4. Start Supervisord only after configuration succeeds.
#
# Manual installation mode:
#
#   1. Start the web server.
#   2. Wait in the background for the web installation to complete.
#   3. Apply deployment-managed defaults after Moodle settles.
#
# Existing installations:
#
#   Apply deployment-managed defaults synchronously at startup.
#
# To add additional deployment defaults later, add them to the PHP block
# in apply_moodle_defaults().
# ------------------------------------------------------------------

MOODLE_ROOT="${MOODLE_ROOT:-/var/www/html}"


# ------------------------------------------------------------------
# Determine Whether Moodle's Database Is Installed
# ------------------------------------------------------------------
#
# This is used by automatic installation mode. It verifies that Moodle
# can bootstrap and that the core database version exists.
#
# This check deliberately does not require administrator lastaccess.
# A CLI-installed administrator has not necessarily logged in yet.
# ------------------------------------------------------------------

moodle_database_is_installed() {

    [ -f "${MOODLE_ROOT}/config.php" ] || return 1

    su -s /bin/bash www-data -c "/usr/local/bin/php" \
        >/dev/null 2>&1 <<EOPHP
<?php

define('CLI_SCRIPT', true);

try {
    require('${MOODLE_ROOT}/config.php');

    \$version = get_config('core', 'version');

    exit(empty(\$version) ? 1 : 0);

} catch (Throwable \$exception) {
    exit(1);
}
EOPHP
}


# ------------------------------------------------------------------
# Determine Whether Web Installation Is Complete
# ------------------------------------------------------------------
#
# This is used only by manual web-installation mode. It waits until an
# administrator has accessed the site.
# ------------------------------------------------------------------

moodle_web_installation_is_complete() {

    [ -f "${MOODLE_ROOT}/config.php" ] || return 1

    su -s /bin/bash www-data -c "/usr/local/bin/php" \
        >/dev/null 2>&1 <<EOPHP
<?php

define('CLI_SCRIPT', true);

try {
    require('${MOODLE_ROOT}/config.php');

    \$admins = get_admins();

    if (empty(\$admins)) {
        exit(1);
    }

    foreach (\$admins as \$admin) {
        if (!empty(\$admin->lastaccess)) {
            exit(0);
        }
    }

} catch (Throwable \$exception) {
    exit(1);
}

exit(1);
EOPHP
}

moodle_upgrade_is_complete() {
    su -s /bin/bash www-data -c \
        "/usr/local/bin/php \
            '${MOODLE_ROOT}/admin/cli/upgrade.php' \
            --is-pending" \
        >/dev/null 2>&1
}

# ------------------------------------------------------------------
# Validate Automatic Installation Environment
# ------------------------------------------------------------------

validate_auto_install_environment() {

    local required_variables=(
        MOODLE_SITE_FULLNAME
        MOODLE_SITE_SHORTNAME
        MOODLE_ADMIN_USER
        MOODLE_ADMIN_PASSWORD
        MOODLE_ADMIN_EMAIL
        MOODLE_SUPPORT_EMAIL
        MOODLE_NOREPLY_EMAIL
    )

    local variable
    local missing=0

    for variable in "${required_variables[@]}"; do
        if [ -z "${!variable:-}" ]; then
            echo >&2 \
                "[!] Automatic installation requires ${variable}."
            missing=1
        fi
    done

    if [ "$missing" -ne 0 ]; then
        return 1
    fi
}


# ------------------------------------------------------------------
# Install Moodle from Environment Variables
# ------------------------------------------------------------------
#
# config.php is already generated earlier in this entrypoint, so use
# Moodle's install_database.php command to initialize the empty database.
#
# The command is executed as www-data so files generated in moodledata
# receive the same ownership used by Apache and Moodle CLI operations.
# ------------------------------------------------------------------

install_moodle_from_environment() {

    validate_auto_install_environment || {
        echo >&2 \
            "[!] Automatic Moodle installation configuration is incomplete."

        return 1
    }

    local language="${MOODLE_LANG:-en}"
    local summary="${MOODLE_SITE_SUMMARY:-}"

    local install_command=(
        /usr/local/bin/php
        "${MOODLE_ROOT}/admin/cli/install_database.php"
        "--lang=${language}"
        "--adminuser=${MOODLE_ADMIN_USER}"
        "--adminpass=${MOODLE_ADMIN_PASSWORD}"
        "--adminemail=${MOODLE_ADMIN_EMAIL}"
        "--fullname=${MOODLE_SITE_FULLNAME}"
        "--shortname=${MOODLE_SITE_SHORTNAME}"
        "--summary=${summary}"
        "--supportemail=${MOODLE_SUPPORT_EMAIL}"
        "--noreplyemail=${MOODLE_NOREPLY_EMAIL}"
        --agree-license
    )

    local quoted_command

    printf -v quoted_command '%q ' "${install_command[@]}"

    echo "[+] Empty Moodle database detected."
    echo "[+] Starting automatic Moodle CLI installation..."

    if ! su -s /bin/bash www-data -c "$quoted_command"; then
        echo >&2 "[!] Automatic Moodle CLI installation failed."

        return 1
    fi

    if ! moodle_database_is_installed; then
        echo >&2 \
            "[!] Moodle installer exited, but installation could not be verified."

        return 1
    fi

    echo "[+] Automatic Moodle CLI installation completed successfully."
}

# ------------------------------------------------------------------
# Apply Deployment-Managed Moodle Defaults
# ------------------------------------------------------------------
#
# Keep everything in this block idempotent. It runs after initial
# installation and again on subsequent container starts.
#
# This is the primary customization section for adding additional
# deployment-managed Moodle defaults later.
# ------------------------------------------------------------------

apply_moodle_defaults() {

    echo "[+] Applying deployment-managed Moodle defaults..."

    MOODLE_ROOT="$MOODLE_ROOT" \
    su -s /bin/bash www-data -c "/usr/local/bin/php" <<'EOPHP'
<?php

define('CLI_SCRIPT', true);

$moodleroot = getenv('MOODLE_ROOT');

if (!$moodleroot) {
    fwrite(
        STDERR,
        "[!] MOODLE_ROOT is not defined.\n"
    );

    exit(1);
}

$configfile = $moodleroot . '/config.php';

if (!is_file($configfile)) {
    fwrite(
        STDERR,
        "[!] Moodle config.php was not found.\n"
    );

    exit(1);
}

require($configfile);


// ==================================================================
// Deployment-Managed Moodle Settings
// ==================================================================
//
// Add future site defaults in this section.
//
// These operations should remain idempotent so that they can safely
// execute every time the Moodle container starts.
// ==================================================================


// ------------------------------------------------------------------
// Cron Keepalive
// ------------------------------------------------------------------
//
// If MOODLE_CRON_KEEPALIVE is not defined, Moodle retains its existing
// setting and the value remains manageable through the web interface.
// ------------------------------------------------------------------

$cronkeepalive = getenv('MOODLE_CRON_KEEPALIVE');

if (
    $cronkeepalive !== false &&
    $cronkeepalive !== ''
) {
    $current = get_config(
        'core',
        'cron_keepalive'
    );

    if (
        $current === false ||
        (string)$current !== (string)$cronkeepalive
    ) {
        set_config(
            'cron_keepalive',
            $cronkeepalive
        );

        echo "[+] Set cron_keepalive={$cronkeepalive}.\n";

    } else {
        echo "[+] cron_keepalive already set to {$cronkeepalive}.\n";
    }
}

// ------------------------------------------------------------------
// Redis MUC Cache & Test Server
// ------------------------------------------------------------------
//
// Moodle sessions are configured separately through config.php above.
//
// This section creates a Moodle Universal Cache Redis store and maps:
//
//   Application caches -> Redis
//   Session caches     -> Redis
//   Request caches     -> Moodle's default request cache
// ------------------------------------------------------------------
// Redis Test Server:
// ------------------------------------------------------------------
// The Redis test server is used by Moodle's cache performance testing
// tools. It should point to the same Redis server used by the MUC store.
// ------------------------------------------------------------------

$redisserver = 'redis';

set_config(
    'test_server',
    $redisserver,
    'cachestore_redis'
);

echo "[+] Set Redis cache test server to {$redisserver}.\n";

$writer = cache_config_writer::instance();
$stores = $writer->get_all_stores();

if (!array_key_exists('redis', $stores)) {

    $writer->add_store_instance(
        'redis',
        'redis',
        [
            'server' => $redisserver,
            'prefix' => 'moodle_',
        ]
    );

    echo "[+] Created Redis MUC cache store.\n";

} else {

    echo "[+] Redis MUC cache store already exists.\n";
}

$writer->set_mode_mappings([
    cache_store::MODE_APPLICATION => ['redis'],
    cache_store::MODE_SESSION     => ['redis'],
    cache_store::MODE_REQUEST     => ['default_request'],
]);

echo "[+] Configured Redis MUC cache mappings.\n";

// ------------------------------------------------------------------
// Unoconv File Converter
// ------------------------------------------------------------------

$unoconvpath = '/usr/bin/unoconv';

if (
    !is_file($unoconvpath) ||
    !is_executable($unoconvpath)
) {
    throw new RuntimeException(
        "Unoconv is not available at {$unoconvpath}."
    );
}

set_config(
    'pathtounoconv',
    $unoconvpath,
    'fileconverter_unoconv'
);

$pluginmanager = core_plugin_manager::instance();

$plugininfo = $pluginmanager->get_plugin_info(
    'fileconverter_unoconv'
);

if ($plugininfo) {

    $plugininfo->set_enabled(true);

    echo "[+] Enabled Unoconv using {$unoconvpath}.\n";

} else {

    # Fallback if Moodle's plugin manager does not return the
    # fileconverter_unoconv component.

    set_config(
        'disabled',
        '0',
        'fileconverter_unoconv'
    );

    echo "[+] Enabled Unoconv using configuration fallback.\n";
}


// ==================================================================
// End Deployment-Managed Moodle Settings
// ==================================================================


// Make changed settings immediately visible to Moodle.
purge_all_caches();

echo "[+] Deployment-managed Moodle defaults applied.\n";

EOPHP
}


# ------------------------------------------------------------------
# Apply Deployment Defaults and Report Failure
# ------------------------------------------------------------------

apply_moodle_defaults_or_fail() {

    if apply_moodle_defaults; then
        echo "[+] Moodle deployment defaults configured."
        return 0
    fi

    echo >&2         "[!] Moodle deployment defaults could not be fully configured."

    return 1
}


# ------------------------------------------------------------------
# Manual Web-Installation Completion
# ------------------------------------------------------------------
#
# This process runs in the background because Apache/Supervisord must
# start immediately so that a new Moodle site can be installed through
# the web interface.
#
# For a new site:
#
#   1. Supervisord and Apache start normally.
#   2. The web installer runs normally.
#   3. This process checks Moodle every five seconds.
#   4. Once an administrator has accessed Moodle, the deployment defaults
#      are applied once.
#   5. This background process exits.
#
# For an existing site, the readiness check should normally succeed on
# the first attempt and the defaults are reapplied at startup.
# ------------------------------------------------------------------

configure_moodle_when_ready() {

    echo "[+] Waiting for manual Moodle web installation to complete..."

    until \
        moodle_web_installation_is_complete &&
        moodle_upgrade_is_complete; do

        sleep 5
    done

    echo "[+] Moodle web installation and upgrade processing complete."

    # Allow the final web-installer request to finish cache processing.
    sleep 30

    if ! apply_moodle_defaults_or_fail; then
        echo >&2 \
            "[!] Manual web installation completed, but deployment defaults failed."
    fi
}


# ------------------------------------------------------------------
# Install or Configure Moodle
# ------------------------------------------------------------------

MOODLE_AUTO_INSTALL_NORMALIZED="$(
    printf '%s' "${MOODLE_AUTO_INSTALL:-false}" |
    tr '[:upper:]' '[:lower:]'
)"

case "$MOODLE_AUTO_INSTALL_NORMALIZED" in

    true|yes|1)

        if moodle_database_is_installed; then
            echo "[+] Existing Moodle database installation detected."
        else
            install_moodle_from_environment
        fi

        # In automatic mode the CLI installer has now returned, so it is
        # safe to apply Redis MUC, Unoconv, and other managed defaults
        # synchronously before Apache and Ofelia begin normal operation.
        apply_moodle_defaults_or_fail
        ;;

    false|no|0|"")

        if moodle_database_is_installed; then
            echo "[+] Existing Moodle database installation detected."
            apply_moodle_defaults_or_fail
        else
            # Apache must start so the manual web installer is available.
            configure_moodle_when_ready &
        fi
        ;;

    *)

        echo >&2 \
            "[!] Invalid MOODLE_AUTO_INSTALL value: ${MOODLE_AUTO_INSTALL:-}"

        echo >&2 \
            "[!] Use true, false, yes, no, 1, or 0."

        exit 1
        ;;

esac


# ------------------------------------------------------------------
# Remove Installation-Only Environment Variables
# ------------------------------------------------------------------
#
# These values are no longer needed after automatic installation.
# Remove them before launching long-running processes.
# ------------------------------------------------------------------

unset MOODLE_ADMIN_PASSWORD
unset MOODLE_ADMIN_USER
unset MOODLE_ADMIN_EMAIL
unset MOODLE_SUPPORT_EMAIL
unset MOODLE_NOREPLY_EMAIL
unset MOODLE_SITE_FULLNAME
unset MOODLE_SITE_SHORTNAME
unset MOODLE_SITE_SUMMARY
unset MOODLE_LANG

# ------------------------------------------------------------------
# Secure Moodle config.php Permissions
# ------------------------------------------------------------------
#
# config.php contains database credentials and other sensitive
# configuration. Allow root and the www-data group to read it while
# denying write access and access by other users.
# ------------------------------------------------------------------

CONFIG_PHP="${MOODLE_ROOT}/config.php"

if [ -f "$CONFIG_PHP" ]; then
    chown root:www-data "$CONFIG_PHP"
    chmod 0440 "$CONFIG_PHP"

    echo "[+] Secured config.php permissions (root:www-data 0440)."
fi

# ------------------------------------------------------------------
# Launch Supervisord / Container Command
# ------------------------------------------------------------------

exec "$@"