# moodle-docker
# Moodle Docker Optimized

This repository provides a production-ready Docker deployment for **Moodle 5.x** running on **PHP 8.4**. It is designed for high performance and reliability, featuring a dedicated Redis cache, an automated task scheduler, and an integrated Python-based upgrade manager.

## Architecture

The stack consists of four primary services:

* **Moodle:** The application core running Apache and PHP 8.4, optimized with OPcache.
* **MariaDB:** A relational database pinned to version 12.3 and tuned for Moodle's `READ-COMMITTED` transaction isolation requirements.
* **Redis:** High-speed in-memory data structure store used for Moodle's Universal Cache (MUC) and session handling.
* **Tasks (Ofelia):** A sidecar container that securely executes the Moodle cron script by filtering Docker labels for this specific stack, keeping the cron architecture decentralized.

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

    To rebuild, use:
    ```bash
     docker compose build --no-cache moodle
     docker compose down && docker compose up -d
     ```

## Automated Configuration & Cron

This stack uses Ofelia to manage Moodle's cron tasks securely without exposing cron management to the host operating system.

The configuration is handled through labels on the Moodle service:

* **Command:** `/usr/local/bin/php /var/www/html/admin/cli/cron.php`
* **Interval:** Every minute

The container entrypoint automatically performs several Moodle configuration tasks during startup:

* Detects Redis and injects the required session configuration into `config.php`.
* Enables Moodle 5.x router support.
* Configures reverse-proxy SSL handling.
* Applies deployment-managed Moodle settings using Moodle's official `admin/cli/cfg.php` API.

#### Cron Keepalive Optimization

Moodle 4.2+ introduced a `cron_keepalive` setting that causes each cron execution to remain active for up to 180 seconds while polling for additional adhoc tasks.

While useful for some deployments, it can generate excessive logging and multiple concurrent cron workers when combined with Ofelia's one-minute scheduling interval.

This Docker image supports managing the setting through an optional environment variable:

```yaml
environment:
  MOODLE_CRON_KEEPALIVE: 0
```

When defined, the container automatically applies the value using Moodle's supported CLI configuration API (`admin/cli/cfg.php`) during startup.

For Ofelia-based deployments, the recommended setting is:

```yaml
MOODLE_CRON_KEEPALIVE: 0
```

This restores the traditional cron behavior:

1. Cron starts.
2. Scheduled tasks execute.
3. Cron exits immediately.

**Benefits:**

- Dramatically reduced cron log volume.
- Eliminates overlapping cron workers.
- Lower resource consumption.
- Maintains Moodle's recommended one-minute cron schedule.

If `MOODLE_CRON_KEEPALIVE` is not defined, Moodle retains the value stored in `mdl_config`, allowing administrators to manage the setting through the Moodle web interface.

**To verify:**

```bash
docker compose exec -u www-data moodle \
  php admin/cli/cfg.php --name=cron_keepalive
```

Expected output:

```text
0
```

**Implementation Details**

The container uses Moodle's official configuration API rather than direct database updates:

```bash
docker compose exec -u www-data moodle \
    php admin/cli/cfg.php \
    --name=cron_keepalive \
    --set=0
```

This ensures compatibility with future Moodle upgrades while keeping deployment-specific settings reproducible across containers.

### Alternative Host Cron

If preferred, Ofelia can be removed entirely and cron can be scheduled directly from the host:

```bash
* * * * * docker exec -u www-data <container_name> php /var/www/html/admin/cli/cron.php
```

## The Upgrade Manager

This image includes a custom Python utility to manage major and minor Moodle upgrades safely. The tool performs a 3-way diff between your current site, a vanilla copy of your current version, and the target version to ensure custom plugins are migrated while deprecated core code is removed.

### Running an Upgrade

The one-step upgrade option is to run `scripts/moodle_upgrade.sh`, which calls the Python upgrade manager.
```bash
sudo bash scripts/moodle_upgrade.sh <moodle_branch>
```

### Running an Upgrade via the Upgrade Manger

Alternatively, run the upgrade step by step.

1.  **Trigger the file migration:**
    ```bash
    docker compose exec -it moodle moodle-upgrade 502
    ```

2.  **Run the database upgrade:**
    ```bash
    docker compose exec -u www-data moodle php admin/cli/upgrade.php --non-interactive
    ```

3.  **Purge Caches:**
    ```bash
    docker compose exec -u www-data moodle php admin/cli/purge_caches.php
    ```

## Customizing Apache and PHP Configurations

This Docker image bakes in optimized Apache and PHP settings by default. However, if you need to make specific adjustments (like adding custom Apache aliases, altering rewrite rules, or changing PHP upload limits), you can hot-swap these files without rebuilding the image.

1. **Locate the default files:** The default configurations are located in the `./build-context/apache/` directory of this repository.
2. **Modify your local copy:** Edit `./build-context/apache/site.conf` or `php-overrides.ini` to suit your needs.
3. **Uncomment the volume mounts:** Open your `docker-compose.yml` file and uncomment the Advanced Configuration Overrides under the `moodle` service:
   ```yaml
   # - ./build-context/apache/site.conf:/etc/apache2/sites-available/000-default.conf:ro
   # - ./build-context/apache/php-overrides.ini:/usr/local/etc/php/conf.d/php-overrides.ini:ro
   ```
