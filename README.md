# moodle-docker
# Moodle Docker Optimized

This repository provides a production-ready Docker deployment for **Moodle 5.x** running on **PHP 8.4**. It is designed for high performance and reliability, featuring a dedicated Redis cache, an automated task scheduler, and an integrated Python-based upgrade manager.

## Architecture

The stack consists of four primary services:

* **Moodle:** The application core running Apache and PHP 8.4, optimized with OPcache.
* **MariaDB:** A relational database tuned for Moodle's `READ-COMMITTED` transaction isolation requirements.
* **Redis:** High-speed in-memory data structure store used for Moodle's Universal Cache (MUC) and session handling.
* **Tasks (Deck-chores):** A sidecar container that monitors Docker labels to execute the Moodle cron script without requiring a local system crontab.

## Prerequisites

* Docker and Docker Compose installed on the host.
* An external Nginx proxy (or similar) to handle SSL termination.
* A Docker network named `gateway-net` (configured as `external` in the compose file).

## Configuration

The deployment relies on environment variables. Create a `.env` file in the root directory with the following values:

```env
# Database Credentials
MYSQL_ROOT_PASSWORD=your_secure_root_password
MYSQL_DATABASE=moodle
MYSQL_USER=moodle_user
MYSQL_PASSWORD=your_moodle_db_password

# Ports
WWW_PORT=8080
WWW_SSH_PORT=4433

# Site Identification
SITE_LABEL=moodle-name
DOMAIN=moodle.example.com
```

## Volumes & Persistence

To ensure data persistence and ease of troubleshooting, the following host directories are utilized:

| Path | Purpose |
| :--- | :--- |
| `./moodle` | The Moodle root (mapped to `/var/www/html`) |
| `./moodledata` | Moodle's data directory (mapped to `/var/www/moodledata`) |
| `./db_data` | MariaDB data files |
| `./logs` | Unified Apache and PHP error logs |
| `./backups/courses` | Target directory for course-level backups |

## Deployment

1.  **Initialize the Environment:**
    ```bash
    mkdir -p moodle moodledata db_data logs supervisor backups/courses
    sudo chown -R 33:33 logs  # Ensure www-data can write logs
    ```

2.  **Build and Start the Stack:**
    ```bash
    docker compose up --build -d
    ```

## Automated Cron

This stack uses `deck-chores` to manage Moodle's cron tasks. The configuration is handled via labels on the `moodle` service:

* **Command:** `/usr/local/bin/php /var/www/html/admin/cli/cron.php`
* **Interval:** Every 1 minute

This ensures that maintenance tasks (like sending forum emails or processing course completions) are handled reliably within the Docker environment.

Optionally, use the host `crontab` instead:
```bash
* * * * * docker exec <contain_name> php admin/cli/cron.php
```

## The Upgrade Manager

This image includes a custom Python utility to manage major and minor Moodle upgrades safely. The tool performs a 3-way diff between your current site, a vanilla copy of your current version, and the target version to ensure custom plugins are migrated while deprecated core code is removed.

### Running an Upgrade

1.  **Trigger the file migration:**
    ```bash
    docker compose exec -it moodle moodle-upgrade 501
    ```

2.  **Run the database upgrade:**
    ```bash
    docker compose exec -u www-data moodle php admin/cli/upgrade.php --non-interactive
    ```

3.  **Purge Caches:**
    ```bash
    docker compose exec -u www-data moodle php admin/cli/purge_caches.php
    ```

## Performance Tuning

* **PHP Overrides:** Custom settings (Memory limits, OPcache, Max Input Vars) are baked into the image but can be reviewed in the `php-overrides.ini` file.
* **Composer:** Moodle 5.1+ dependencies are managed via an authoritative classmap built during the container's lifecycle to minimize I/O overhead.
