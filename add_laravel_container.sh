#!/bin/bash

# Usage: ./add_laravel_container.sh <app_number> <port>

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <app_number> <port>"
  exit 1
fi

APP_NUMBER=$1
PORT=$2
APP_NAME="app$APP_NUMBER"
DB_NAME="db$APP_NUMBER"
DEDICATED_DB_DATABASE="app${APP_NUMBER}_db"
DEDICATED_DB_USERNAME="user${APP_NUMBER}"
DEDICATED_DB_PASSWORD="pass${APP_NUMBER}"
APP_KEY=$(docker run --rm laravel_app_image php artisan key:generate --show)
ENV_FILE_PATH="./docker/laravel/envs/.env.$APP_NAME"

# Create .env file for the new container
cat > "$ENV_FILE_PATH" <<EOL
APP_NAME=LaravelApp$APP_NUMBER
APP_ENV=local
APP_KEY=$APP_KEY
APP_DEBUG=true
APP_URL=http://localhost:$PORT

LOG_CHANNEL=stack

# Core Database Configuration
CORE_DB_HOST=core_db
CORE_DB_PORT=3306
CORE_DB_DATABASE=core_db
CORE_DB_USERNAME=core_user
CORE_DB_PASSWORD=core_password

# Dedicated Database Configuration
DEDICATED_DB_HOST=$DB_NAME
DEDICATED_DB_PORT=3306
DEDICATED_DB_DATABASE=$DEDICATED_DB_DATABASE
DEDICATED_DB_USERNAME=$DEDICATED_DB_USERNAME
DEDICATED_DB_PASSWORD=$DEDICATED_DB_PASSWORD

# Other environment variables...
EOL

echo "Created environment file at $ENV_FILE_PATH"

# Define the service definitions
SERVICE_DEFINITION=$(cat <<EOL

  # Laravel Container $APP_NUMBER
  $APP_NAME:
    image: laravel_app_image
    container_name: laravel_$APP_NAME
    depends_on:
      - core_db
      - $DB_NAME
    environment:
      # Dedicated Database Configuration
      DEDICATED_DB_HOST: $DB_NAME
      DEDICATED_DB_PORT: 3306
      DEDICATED_DB_DATABASE: $DEDICATED_DB_DATABASE
      DEDICATED_DB_USERNAME: $DEDICATED_DB_USERNAME
      DEDICATED_DB_PASSWORD: $DEDICATED_DB_PASSWORD
      # Laravel-specific Configuration
      APP_ENV: local
      APP_DEBUG: true
      APP_KEY: $APP_KEY
      APP_URL: http://localhost:$PORT
    ports:
      - "$PORT:80"
    volumes:
      - ./laravel:/var/www/html
      - ./docker/laravel/envs/.env.$APP_NAME:/var/www/html/.env
    networks:
      - app-network

  $DB_NAME:
    image: mysql:8.0
    container_name: $DB_NAME
    restart: unless-stopped
    environment:
      MYSQL_DATABASE: $DEDICATED_DB_DATABASE
      MYSQL_ROOT_PASSWORD: rootpassword
      MYSQL_USER: $DEDICATED_DB_USERNAME
      MYSQL_PASSWORD: $DEDICATED_DB_PASSWORD
    volumes:
      - ${DB_NAME}_data:/var/lib/mysql
    networks:
      - app-network
EOL
)

VOLUME_DEFINITION="  ${DB_NAME}_data:"

# Backup the existing docker-compose.yml
cp docker-compose.yml docker-compose.yml.bak
echo "Backup of docker-compose.yml created at docker-compose.yml.bak"

# Function to append services under the 'services:' section
append_services() {
  local service_def="$1"
  local compose_file="$2"

  # Check if 'services:' exists
  if grep -q "^services:" "$compose_file"; then
    # Insert service definitions after 'services:' line
    # Using awk to insert after the 'services:' line
    awk -v service="$service_def" '
      /^services:/ {print; print service; next}
      {print}
    ' "$compose_file" > "${compose_file}.tmp" && mv "${compose_file}.tmp" "$compose_file"
    echo "Added services for $APP_NAME and $DB_NAME under 'services:' section."
  else
    # If 'services:' does not exist, append it at the end with the service definitions
    echo -e "\nservices:\n$service_def" >> "$compose_file"
    echo "Added 'services:' section with $APP_NAME and $DB_NAME services."
  fi
}

# Function to append volumes under the 'volumes:' section
append_volumes() {
  local volume_def="$1"
  local compose_file="$2"

  # Check if 'volumes:' exists
  if grep -q "^volumes:" "$compose_file"; then
    # Check if the volume already exists
    if grep -q "^  ${DB_NAME}_data:" "$compose_file"; then
      echo "Volume ${DB_NAME}_data already exists in 'volumes:' section."
    else
      # Insert the new volume after the last existing volume in 'volumes:' section
      # Find the line number where 'volumes:' starts
      volumes_line=$(grep -n "^volumes:" "$compose_file" | cut -d: -f1)
      
      # Find the next top-level section after 'volumes:'
      next_section_line=$(awk "/^volumes:/ {found=1; next} /^  [^ ]+/ && found {print NR; exit}" "$compose_file")
      
      if [ -z "$next_section_line" ]; then
        # No other top-level sections, append at the end
        echo "  ${DB_NAME}_data:" >> "$compose_file"
        echo "Added volume ${DB_NAME}_data under 'volumes:' section."
      else
        # Insert before the next top-level section
        sed -i "$((next_section_line - 1))a \\  ${DB_NAME}_data:" "$compose_file"
        echo "Added volume ${DB_NAME}_data under 'volumes:' section."
      fi
    fi
  else
    # If 'volumes:' does not exist, append it at the end with the new volume
    echo -e "\nvolumes:\n$volume_def" >> "$compose_file"
    echo "Added 'volumes:' section with ${DB_NAME}_data volume."
  fi
}

# Append the new services to docker-compose.yml
append_services "$SERVICE_DEFINITION" "docker-compose.yml"

# Append the new volume to docker-compose.yml
append_volumes "$VOLUME_DEFINITION" "docker-compose.yml"

# Build and start the new services
docker-compose up -d --build "$APP_NAME" "$DB_NAME"

if [ $? -eq 0 ]; then
  echo "Started $APP_NAME and $DB_NAME containers successfully."
else
  echo "Failed to start $APP_NAME and/or $DB_NAME containers."
  exit 1
fi

# Run migrations
docker exec -it "laravel_$APP_NAME" php artisan migrate --database=core_mysql
docker exec -it "laravel_$APP_NAME" php artisan migrate --database=dedicated_mysql

if [ $? -eq 0 ]; then
  echo "Ran migrations for $APP_NAME successfully."
else
  echo "Failed to run migrations for $APP_NAME."
  exit 1
fi
