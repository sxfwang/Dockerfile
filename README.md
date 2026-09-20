# oracle26ai-apex-ords
Base on Oracle database dockefile at https://github.com/oracle/docker-images/tree/main/OracleDatabase/SingleInstance/dockerfiles/23.26.0

Integrated with APEX and ORDS.

Download LINUX.X64_2326100_db_home.zip, apex-latest.zip, ords-latest.zip

docker buildx build --load -f ./Containerfile --build-arg DB_EDITION=ee -t imagename:version .
