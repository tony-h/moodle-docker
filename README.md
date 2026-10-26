# Moodle Docker Optimized

A production-ready, highly optimized Docker deployment for **Moodle 5.x** running on **PHP 8.4**.

This stack includes everything you need to run a fast and reliable Moodle instance out-of-the-box:

* **Moodle Core** (Apache/PHP 8.4 optimized with OPcache, `config.php` set to read-only)
* **MariaDB** (Tuned for Moodle-specific database indexes)
* **Redis** (Pre-configured for Moodle Universal Cache [MUC] and high-performance session handling)
* **Automated Cron** (Self-contained background task scheduling executing at recommended 1-minute intervals)
* **Unoconv Integration** (Pre-configured document conversion. *Security Note:* Processing untrusted documents natively carries inherent risks; ensure appropriate file upload restrictions and antivirus scanning are enforced in your Moodle settings.)
* **Hardened Security Settings** (Pre-configured directly within `config.php`)
  - `$_SERVER['HTTPS'] = 'on';` - Enforces HTTPS URLS
  - `$CFG->sslproxy = true;` - Instructs Moodle to trust SSL termination handled by the upstream reverse proxy
  - `$CFG->reverseproxy = true;` - Enables correct client IP routing and port detection via standard proxy headers (`X-Forwarded-For`)
  - `$CFG->preventexecpath = true;` - Disables web-GUI management of server executable paths to prevent administrative privilege escalation

## 📋 Prerequisites

1. **Docker** and **Docker Compose** installed on your host.

2. An external reverse proxy (like Nginx, Traefik, or Cloudflare Tunnels) to handle SSL termination.

3. A Docker network named `gateway-net`. Create it using:

   ```bash
   docker network create gateway-net
   ```

## 🚀 Quick Start (New Installation)

Follow these steps to spin up a brand-new Moodle environment:

1. **Prepare Configuration Files:**
   Copy the sample environment files and update them with your own secure passwords and site details.

   ```bash
   cp sample.env .env
   cp sample.env.install .env.install
   ```

   *Edit `.env` for database and domain settings. Edit `.env.install` for your Moodle site name and admin credentials.*

2. **Run the Installer:**
   Use the included installation script to set up directories, permissions, and bootstrap the Moodle database.

   ```bash
   bash scripts/moodle_install.sh
   ```

3. **Check the Logs:**
   Ensure everything installed smoothly by watching the setup logs:

   ```bash
   docker compose logs moodle -f
   ```

Your site should now be accessible via the domain configured in your `.env` file (assuming your proxy is set up).

## 🛠️ Common Operations

### Starting and Stopping
To start the environment normally (after the initial install):
```bash
docker compose up -d
```
To stop the environment:
```bash
docker compose down
```

### Upgrading Moodle
This stack includes an automated, interactive script to handle major and minor Moodle upgrades safely. It automatically creates a database backup, handles custom plugins, and runs the necessary upgrade steps.

To upgrade to a specific Moodle branch (e.g., `503` for Moodle 5.3):
```bash
sudo bash scripts/moodle_upgrade.sh 503
```

### Updating the Docker Compose Stack
To update the Docker Compose stack to apply updates to the running services, you can rebuild the Moodle image and pull the other images.

To rebuild the Docker image to apply new updates, run:
```bash
docker compose build moodle --no-cache
```

To pull updated images, run:
```bash
docker compose pull
```

To apply the updated images, stop and then restart the entire stack:
```bash
docker compose down
docker compose up -d
```

### Extracting Course Backups
If you need to perform bulk CLI backups of your Moodle courses, you can run the included extraction script.
```bash
bash scripts/extract_courses.sh
```
Extracted `.mbz` files will be saved in `./backups/cli-extracts`.

## 📁 Directory Structure & Persistence

Data is persisted on your host machine to ensure safety and allow for easy backups.

| Host Directory | Purpose | 
| ----- | ----- | 
| `./moodle` | The Moodle application files. | 
| `./moodledata` | Uploaded files, cache, and session data. | 
| `./db_data` | MariaDB database files. | 
| `./logs` | Apache and PHP error logs. | 
| `./backups` | Database dumps and extracted course backups. | 

*Note: If you run into permission issues with logs, ensure your host allows the `www-data` user to write to the logs folder: `sudo chown -R 33:33 logs`*

## ⚙️ Advanced Configuration

### Customizing Apache and PHP

You can adjust PHP limits (like upload size) or Apache configurations without rebuilding the Docker image.

1. Edit the files located in `./build-context/apache/` (`site.conf` or `php-overrides.ini`).

2. Open `docker-compose.yml` and uncomment the "Advanced Configuration Overrides" section under the `moodle` service.

3. Restart the stack: `docker compose up -d`

### Cron Optimization

Background tasks run automatically every minute. If you are experiencing excessive log generation from cron tasks, you can manage Moodle's `cron_keepalive` setting via your `.env` file.

Adding `MOODLE_CRON_KEEPALIVE=0` to your `.env` file and restarting the container will force cron to exit immediately after finishing its queue, drastically reducing background noise.
