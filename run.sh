#!/bin/bash

source /run.env.sh

set -x

function createPostgresConfig() {
  cp /etc/postgresql/current/main/postgresql.custom.conf.tmpl /etc/postgresql/current/main/conf.d/postgresql.custom.conf || exit 1
  sudo -u postgres echo "autovacuum = $AUTOVACUUM" >> /etc/postgresql/current/main/conf.d/postgresql.custom.conf || exit 1
  cat /etc/postgresql/current/main/conf.d/postgresql.custom.conf
}

function setPostgresPassword() {
    sudo -u postgres psql -c "ALTER USER renderer PASSWORD '${PGPASSWORD:-renderer}'"
}

#Make env vars permanent
echo "#!/bin/bash" > /etc/osmtileserver-options.sh
echo "#Global osmtileserver options" >> /etc/osmtileserver-options.sh
echo "OSM2PGSQL_EXTRA_ARGS=($OSM2PGSQL_EXTRA_ARGS)" >> /etc/osmtileserver-options.sh
echo "RENDER_THREADS=${RENDER_THREADS}" >> /etc/osmtileserver-options.sh
echo "UPDATE_THREADS=${UPDATE_THREADS}" >> /etc/osmtileserver-options.sh
echo "IMPORT_THREADS=${IMPORT_THREADS}" >> /etc/osmtileserver-options.sh


#Setup log files
chown root:root /var/log
chmod +rwX /var/log
mkdir -p /var/log/apache2 && chown -R www-data:www-data /var/log/apache2 || exit 1
touch /var/log/renderd.log && chown renderer:renderer /var/log/renderd.log || exit 1
mkdir -p /var/log/tiles && chown -R renderer:renderer /var/log/tiles || exit 1

if [ "$#" -ne 1 ]; then
    echo "usage: <import|run|clean>"
    echo "commands:"
    echo "    clean: clean all persistent storage locations"
    echo "    cleandb: clean data base files and osmosis status info"
    echo "    import: Set up the database and import /data.osm.pbf"
    echo "    run: Runs Apache and renderd to serve tiles at /tile/{z}/{x}/{y}.png"
    echo "environment variables:"
    echo "    IMPORT_THREADS: defines number of threads used for importing"
    echo "    RENDER_THREADS: defines number of threads used for rendering"
    echo "    UPDATE_THREADS: defines number of threads used for updating"
    echo "    UPDATES: consecutive updates (enabled/disabled)"
    exit 1
fi

if [ "$1" = "clean" ]; then
    echo "Cleaning all persistent storage locations"
    rm -rf /var/lib/mod_tile/* > /dev/null 2>&1
    rm -rf /var/lib/mod_tile/.osmosis > /dev/null 2>&1
    rm -rf /var/lib/postgresql/* > /dev/null 2>&1
    rm -rf /nodes/* > /dev/null 2>&1
    rm -rf /debug/*  > /dev/null 2>&1
    exit 0
fi

if [ "$1" = "cleandb" ]; then
    echo "Cleaning data base related files"
    rm -rf /var/lib/mod_tile/.osmosis > /dev/null 2>&1
    rm -rf /var/lib/postgresql/* > /dev/null 2>&1
    exit 0
fi

if [ "$1" = "import" ]; then
    # Ensure that database directory is in right state
    chown postgres:postgres -R /var/lib/postgresql
    if [ ! -f /var/lib/postgresql/${POSTGRES_VERSION}/main/PG_VERSION ]; then
        sudo -u postgres /usr/lib/postgresql/${POSTGRES_VERSION}/bin/pg_ctl -D /var/lib/postgresql/${POSTGRES_VERSION}/main/ initdb -o "--locale C.UTF-8"
    fi

    # Initialize PostgreSQL
    createPostgresConfig
    service postgresql start
    sudo -u postgres createuser renderer
    sudo -u postgres createdb -E UTF8 -O renderer gis
    sudo -u postgres psql -d gis -c "CREATE EXTENSION postgis;"
    sudo -u postgres psql -d gis -c "CREATE EXTENSION hstore;"
    sudo -u postgres psql -d gis -c "ALTER TABLE geometry_columns OWNER TO renderer;"
    sudo -u postgres psql -d gis -c "ALTER TABLE spatial_ref_sys OWNER TO renderer;"
    setPostgresPassword

    # Download Luxembourg as sample if no data is provided
    if [ ! -f /data.osm.pbf ] && [ -z "$DOWNLOAD_PBF" ]; then
        echo "WARNING: No import file at /data.osm.pbf, so importing Luxembourg as example..."
        DOWNLOAD_PBF="https://download.geofabrik.de/europe/luxembourg-latest.osm.pbf"
        DOWNLOAD_POLY="https://download.geofabrik.de/europe/luxembourg.poly"
    fi

    if [ -n "$DOWNLOAD_PBF" ]; then
        echo "INFO: Download PBF file: $DOWNLOAD_PBF"
        wget -nv "$DOWNLOAD_PBF" -O /data.osm.pbf
        if [ -n "$DOWNLOAD_POLY" ]; then
            echo "INFO: Download PBF-POLY file: $DOWNLOAD_POLY"
            wget -nv "$DOWNLOAD_POLY" -O /data.poly
        fi
    fi

    if [ "$UPDATES" = "enabled" ]; then
        # determine and set osmosis_replication_timestamp (for consecutive updates)
        osmium fileinfo /data.osm.pbf > /var/lib/mod_tile/data.osm.pbf.info
        osmium fileinfo /data.osm.pbf | grep 'osmosis_replication_timestamp=' | cut -b35-44 > /var/lib/mod_tile/replication_timestamp.txt
        REPLICATION_TIMESTAMP=$(cat /var/lib/mod_tile/replication_timestamp.txt)

        # initial setup of osmosis workspace (for consecutive updates)
        sudo -u renderer openstreetmap-tiles-update-expire $REPLICATION_TIMESTAMP
    fi

    # copy polygon file if available
    if [ -f /data.poly ]; then
        sudo -u renderer cp /data.poly /var/lib/mod_tile/data.poly
    fi

    # Import data
    sudo -u renderer osm2pgsql -d gis --create --slim -G --hstore --tag-transform-script /home/renderer/src/openstreetmap-carto/openstreetmap-carto.lua --number-processes ${IMPORT_THREADS:-1} ${OSM2PGSQL_EXTRA_ARGS} -S /home/renderer/src/openstreetmap-carto/openstreetmap-carto.style /data.osm.pbf || exit 1

    # Create indexes
    sudo -u postgres psql -d gis -f indexes.sql || exit 1

    # Register that data has changed for mod_tile caching purposes
    touch /var/lib/mod_tile/planet-import-complete

    service postgresql stop

    exit 0
fi

if [ "$1" = "run" ]; then
    # Clean /tmp
    rm -rf /tmp/*

    # Fix postgres data privileges
    chown postgres:postgres /var/lib/postgresql -R || exit 1

    # Configure Apache CORS
    if [ "$ALLOW_CORS" == "enabled" ] || [ "$ALLOW_CORS" == "1" ]; then
        echo "export APACHE_ARGUMENTS='-D ALLOW_CORS'" >> /etc/apache2/envvars
    fi

    #Fix mod_tile data privileges
    chown -R renderer:renderer /var/lib/mod_tile && chmod -R u=rwX,g=rX,o=rX /var/lib/mod_tile || exit 1

    # Initialize PostgreSQL and Apache
    createPostgresConfig
    service postgresql start
    service apache2 restart
    setPostgresPassword

    # Configure renderd threads
    sed -i -E "s/num_threads=[0-9]+/num_threads=${RENDER_THREADS:-1}/g" /usr/local/etc/renderd.conf

    # start cron job to trigger consecutive updates
    if [ "$UPDATES" = "enabled" ] || [ "$UPDATES" = "1" ]; then
      /etc/init.d/cron start
    fi

    # Run while handling docker stop's SIGTERM
    stop_handler() {
        kill -TERM "$child"
    }
    trap stop_handler SIGTERM

    sudo -u renderer /usr/local/bin/renderd-daemon &
    child=$!
    wait "$child"

    service postgresql stop

    exit 0
fi

echo "invalid command"
exit 1
