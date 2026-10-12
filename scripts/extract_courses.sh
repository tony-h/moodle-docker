#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Ensure the script runs from the project root
cd "$(dirname "$0")/.." || exit 1

echo "Finding Moodle container..."
CONTAINER_ID=$(docker compose ps -q moodle)

if [ -z "$CONTAINER_ID" ]; then
    echo "Error: Could not find a running 'moodle' service for this compose stack."
    exit 1
fi

DEST_DIR="/var/www/cli-extracts"

echo "Ensuring the extraction folder exists with correct permissions..."
docker exec --user root "$CONTAINER_ID" mkdir -p "$DEST_DIR"
docker exec --user root "$CONTAINER_ID" chown www-data:www-data "$DEST_DIR"

echo "Fetching course IDs..."
COURSE_IDS=$(docker exec --user www-data "$CONTAINER_ID" php -r "
    define('CLI_SCRIPT', true);
    require('/var/www/html/config.php');
    foreach(\$DB->get_records('course') as \$c) { 
        if (\$c->id > 1) {
            echo \$c->id . ' ';
        }
    }
")

if [ -z "${COURSE_IDS// /}" ]; then
    echo "No courses found to extract (skipping site front page ID 1)."
    exit 0
fi

for id in $COURSE_IDS; do
    echo "----------------------------------------"
    echo "Extracting course ID: $id..."
    docker exec --user www-data "$CONTAINER_ID" php /var/www/html/admin/cli/backup.php \
        --courseid="$id" \
        --destination="$DEST_DIR"
done

echo "----------------------------------------"
echo "Extraction complete! Files are located in ./backups/cli-extracts/"
