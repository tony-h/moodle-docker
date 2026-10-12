#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Ensure the script runs from the project root (where docker-compose.yml lives)
cd "$(dirname "$0")/.." || exit 1

echo "Finding Moodle container..."
CONTAINER_ID=$(docker compose ps -q moodle)

if [ -z "$CONTAINER_ID" ]; then
    echo "Error: Could not find a running 'moodle' service for this compose stack."
    exit 1
fi

echo "Ensuring correct permissions on the backups/courses folder..."
docker exec --user root "$CONTAINER_ID" chown www-data:www-data /var/www/course-backups

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

# Check if COURSE_IDS is empty (or just contains whitespace)
if [ -z "${COURSE_IDS// /}" ]; then
    echo "No courses found to backup (skipping site front page ID 1)."
    exit 0
fi

for id in $COURSE_IDS; do
    echo "----------------------------------------"
    echo "Dumping course ID: $id..."
    docker exec --user www-data "$CONTAINER_ID" php /var/www/html/admin/cli/backup.php \
        --courseid="$id" \
        --destination=/var/www/course-backups
done

echo "----------------------------------------"
echo "Backup complete! Files are located in ./backups/courses/"
