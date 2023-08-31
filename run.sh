#!/bin/bash

source /run.env.sh

set -euo pipefail

function createPostgresConfig() {
  cp /etc/postgresql/current/main/postgresql.custom.conf.tmpl /etc/postgresql/current/main/conf.d/postgresql.custom.conf
  sudo -u postgres echo -e "\nautovacuum = $AUTOVACUUM\n" >> /etc/postgresql/current/main/conf.d/postgresql.custom.conf
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
mkdir -p /var/log/apache2 && chown -R www-data:www-data /var/log/apache2
touch /var/log/renderd.log && chown renderer:renderer /var/log/renderd.log
mkdir -p /var/log/tiles && chown -R renderer:renderer /var/log/tiles

#Fix permissions
chown -R renderer:renderer /nodes /var/lib/mod_tile 

if [ "$#" -ne 1 ]; then
    echo "usage: <import|run|clean>"
    echo "commands:"
    echo "    clean: clean all persistent storage locations"
    echo "    cleandb: clean data base files and osmosis status info"
    echo "    import: Set up the database and import /data/region.osm.pbf"
    echo "    run: Runs Apache and renderd to serve tiles at /tile/{z}/{x}/{y}.png"
    echo "environment variables:"
    echo "    IMPORT_THREADS: defines number of threads used for importing"
    echo "    RENDER_THREADS: defines number of threads used for rendering"
    echo "    UPDATE_THREADS: defines number of threads used for updating"
    echo "    UPDATES: consecutive updates (enabled/disabled)"
    echo "    NAME_LUA: name of .lua script to run as part of the style"
    echo "    NAME_STYLE: name of the .style to use"
    echo "    NAME_MML: name of the .mml file to render to mapnik.xml"
    echo "    NAME_SQL: name of the .sql file to use"
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

set -x

# if there is no custom style mounted, then use osm-carto
if [ ! "$(ls -A /data/style/)" ]; then
    mv /home/renderer/src/openstreetmap-carto-backup/* /data/style/
fi

# carto build
if [ ! -f /data/style/mapnik.xml ]; then
    cd /data/style/
    carto ${NAME_MML:-project.mml} > mapnik.xml
fi

if [ "$1" == "import" ]; then
    # Ensure that database directory is in right state
    mkdir -p /data/database/postgres/
    chown renderer: /data/database/
    chown -R postgres: /var/lib/postgresql /data/database/postgres/
    if [ ! -f /data/database/postgres/PG_VERSION ]; then
        sudo -u postgres /usr/lib/postgresql/$PG_VERSION/bin/pg_ctl -D /data/database/postgres/ initdb -o "--locale C.UTF-8" 
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
    if [ ! -f /data/region.osm.pbf ] && [ -z "${DOWNLOAD_PBF:-}" ]; then
        echo "WARNING: No import file at /data/region.osm.pbf, so importing Luxembourg as example..."
        DOWNLOAD_PBF="https://download.geofabrik.de/europe/luxembourg-latest.osm.pbf"
        DOWNLOAD_POLY="https://download.geofabrik.de/europe/luxembourg.poly"
    fi

    if [ -n "${DOWNLOAD_PBF:-}" ]; then
        echo "INFO: Download PBF file: $DOWNLOAD_PBF"
        wget ${WGET_ARGS:-} "$DOWNLOAD_PBF" -O /data/region.osm.pbf
        if [ -n "${DOWNLOAD_POLY:-}" ]; then
            echo "INFO: Download PBF-POLY file: $DOWNLOAD_POLY"
            wget ${WGET_ARGS:-} "$DOWNLOAD_POLY" -O /data/region.poly
        fi
    fi

    if [ "${UPDATES:-}" == "enabled" ] || [ "${UPDATES:-}" == "1" ]; then
        # determine and set osmosis_replication_timestamp (for consecutive updates)
        REPLICATION_TIMESTAMP=`osmium fileinfo -g header.option.osmosis_replication_timestamp /data/region.osm.pbf`

        # initial setup of osmosis workspace (for consecutive updates)
        sudo -E -u renderer openstreetmap-tiles-update-expire.sh $REPLICATION_TIMESTAMP
    fi

    # copy polygon file if available
    if [ -f /data/region.poly ]; then
        cp /data/region.poly /data/database/region.poly
        chown renderer: /data/database/region.poly
    fi

    # flat-nodes
    if [ "${FLAT_NODES:-}" == "enabled" ] || [ "${FLAT_NODES:-}" == "1" ]; then
        OSM2PGSQL_EXTRA_ARGS="${OSM2PGSQL_EXTRA_ARGS:-} --flat-nodes /data/database/flat_nodes.bin"
    fi

    # Import data
    OSM2PGSQL_OPTIONS=( -d gis --create --slim -G --hstore
                        --tag-transform-script /data/style/${NAME_LUA:-openstreetmap-carto.lua}
                        --number-processes ${IMPORT_THREADS:-1}
                        -S /data/style/${NAME_STYLE:-openstreetmap-carto.style} /data/region.osm.pbf
                        "${OSM2PGSQL_EXTRA_ARGS[@]}" )
    if [ "$UPDATES" = "enabled" ]; then
        sudo -u renderer osm2pgsql "${OSM2PGSQL_OPTIONS[@]}"
    else
        sudo -u renderer osm2pgsql "${OSM2PGSQL_OPTIONS[@]}" --drop
    fi

    # old flat-nodes dir
    if [ -f /nodes/flat_nodes.bin ] && ! [ -f /data/database/flat_nodes.bin ]; then
        mv /nodes/flat_nodes.bin /data/database/flat_nodes.bin
        chown renderer: /data/database/flat_nodes.bin
    fi

    # Create indexes
    if [ -f /data/style/${NAME_SQL:-indexes.sql} ]; then
        sudo -u postgres psql -d gis -f /data/style/${NAME_SQL:-indexes.sql}
    fi

    #Import external data
    chown -R renderer: /home/renderer/src/ /data/style/
    if [ -f /data/style/scripts/get-external-data.py ] && [ -f /data/style/external-data.yml ]; then
        sudo -E -u renderer python3 /data/style/scripts/get-external-data.py -c /data/style/external-data.yml -D /data/style/data
    fi
    
    # import shape files
    pushd /home/renderer/src/openstreetmap-carto
    scripts/get-external-data.py -d gis -U renderer -w "${PGPASSWORD:-renderer}" -H localhost -p 5432
    popd

    # Register that data has changed for mod_tile caching purposes
    sudo -u renderer touch /data/database/planet-import-complete

    service postgresql stop

    exit 0
fi

if [ "$1" == "run" ]; then
    # Clean /tmp
    rm -rf /tmp/*

    # migrate old files
    if [ -f /data/database/PG_VERSION ] && ! [ -d /data/database/postgres/ ]; then
        mkdir /data/database/postgres/
        mv /data/database/* /data/database/postgres/
    fi
    if [ -f /nodes/flat_nodes.bin ] && ! [ -f /data/database/flat_nodes.bin ]; then
        mv /nodes/flat_nodes.bin /data/database/flat_nodes.bin
    fi
    if [ -f /data/tiles/data.poly ] && ! [ -f /data/database/region.poly ]; then
        mv /data/tiles/data.poly /data/database/region.poly
    fi

    # sync planet-import-complete file
    if [ -f /data/tiles/planet-import-complete ] && ! [ -f /data/database/planet-import-complete ]; then
        cp /data/tiles/planet-import-complete /data/database/planet-import-complete
    fi
    if ! [ -f /data/tiles/planet-import-complete ] && [ -f /data/database/planet-import-complete ]; then
        cp /data/database/planet-import-complete /data/tiles/planet-import-complete
    fi

    # Fix postgres data privileges
    chown -R postgres: /var/lib/postgresql/ /data/database/postgres/

    # Configure Apache CORS
    if [ "${ALLOW_CORS:-}" == "enabled" ] || [ "${ALLOW_CORS:-}" == "1" ]; then
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
    sed -i -E "s/num_threads=[0-9]+/num_threads=${RENDER_THREADS:-1}/g" /etc/renderd.conf

    # start cron job to trigger consecutive updates
    if [ "${UPDATES:-}" == "enabled" ] || [ "${UPDATES:-}" == "1" ]; then
        /etc/init.d/cron start
        sudo -u renderer touch /var/log/tiles/run.log; tail -f /var/log/tiles/run.log >> /proc/1/fd/1 &
        sudo -u renderer touch /var/log/tiles/osmosis.log; tail -f /var/log/tiles/osmosis.log >> /proc/1/fd/1 &
        sudo -u renderer touch /var/log/tiles/expiry.log; tail -f /var/log/tiles/expiry.log >> /proc/1/fd/1 &
        sudo -u renderer touch /var/log/tiles/osm2pgsql.log; tail -f /var/log/tiles/osm2pgsql.log >> /proc/1/fd/1 &

    fi

    # Run while handling docker stop's SIGTERM
    stop_handler() {
        kill -TERM "$child"
    }
    trap stop_handler SIGTERM

    sudo -u renderer renderd -f -c /etc/renderd.conf &
    child=$!
    wait "$child"

    service postgresql stop

    exit 0
fi

echo "invalid command"
exit 1
