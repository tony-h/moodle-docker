#!/bin/bash

if [ "$(id -u)" -ne 0 ]
  then echo "Please run as sudo or root"
  exit
fi

# Ensure script is run with arguments
if [ $# -ne 1 ]; then
  echo "Usage: sudo bash $0 <moodle_branch> (e.g., 500)"
  exit 1
fi

TARGET_BRANCH=$1
SITE=$(basename "$PWD") # Dynamically grab directory name
CURR_DATE=$(date +"%y-%m-%d_%H%M")
MOODLE_DIR=$(pwd)
DB_BACKUP_DIR="${MOODLE_DIR}/backups/database"

# Ensure backup directory exists
mkdir -p "$DB_BACKUP_DIR"

echo "#############################################"
echo "Orchestrating Moodle Upgrade for $SITE"
echo "Target Branch: $TARGET_BRANCH"
echo "#############################################"
echo ""
read -p  "Press 'y' to start the upgrade process: " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Upgrade cancelled."
    exit 1
fi

echo "#"
echo "# 1. Enabling Moodle Maintenance Mode"
echo "#"
docker compose exec -u www-data moodle php admin/cli/maintenance.php --enable

echo "#"
echo "# 2. Backing up the Database (CRITICAL)"
echo "#"
# Adjust 'db' if your container name is different in docker-compose.yml
# This pulls the credentials directly from the environment variables in your compose file
docker compose exec db sh -c 'exec mariadb-dump "$MYSQL_DATABASE" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD"' > "${DB_BACKUP_DIR}/${SITE}_db_bak_${CURR_DATE}.sql"

echo "#"
echo "# 3. Stopping Stack to prevent file locks"
echo "#"
docker compose down

echo "#"
echo "# 4. Creating File Backups"
echo "#"
cd ..
sudo rsync -ar "$MOODLE_DIR" "/tmp/${SITE}_moodle_bak_${CURR_DATE}"
sudo tar -I pigz -cpf "/tmp/${SITE}_moodle_bak_${CURR_DATE}.tgz" "$MOODLE_DIR"
cd "$MOODLE_DIR" || exit

echo "#"
echo "# 5. Bringing Stack Back Up for Upgrade"
echo "#"
docker compose up -d
echo "Waiting 15 seconds for database to accept connections..."
sleep 15

echo "#"
echo "# 6. Running Python Upgrade Manager (Diff & Merge)"
echo "#"
# Capture the exit code of the python script
if ! docker compose exec moodle moodle-upgrade "$TARGET_BRANCH"; then
    echo ""
    echo "[!] CRITICAL ERROR: The Python Upgrade Manager failed."
    echo "[!] Disabling maintenance mode and aborting upgrade."
    docker compose exec -u www-data moodle php admin/cli/maintenance.php --disable
    exit 1
fi

echo "#"
echo "# 6.5 Running Composer Install (Moodle 5.1+ Requirement)"
echo "#"
# We run this as the www-data user to ensure the generated vendor files have the correct ownership
docker compose exec -u www-data moodle composer install --no-dev --classmap-authoritative --working-dir=/var/www/html

echo "#"
echo "# 7. Running Moodle DB Upgrade"
echo "#"
docker compose exec -u www-data moodle php admin/cli/upgrade.php --non-interactive

echo "#"
echo "# 8. Disabling Maintenance Mode"
echo "#"
docker compose exec -u www-data moodle php admin/cli/maintenance.php --disable

echo "#"
echo "# 9. Restarting the Moodle Stack for full refresh"
echo "#"
docker compose down && docker compose up -d

echo "#############################################"
echo "Upgrade Complete!"
echo "Check the site and logs for any warnings."
echo "#############################################"
