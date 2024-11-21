#!/bin/bash

# Array of Laravel containers
containers=("laravel_app1" "laravel_app2") # Add more container names as needed

for container in "${containers[@]}"
do
  echo "Running migrations for $container..."

  # Migrate Core Database
  docker exec -i "$container" php artisan migrate --database=core_mysql

  # Migrate Dedicated Database
  docker exec -i "$container" php artisan migrate --database=dedicated_mysql

  echo "Migrations completed for $container."
done
