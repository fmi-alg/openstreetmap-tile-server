# openstreetmap-tile-server

[![Build Status](https://travis-ci.org/Overv/openstreetmap-tile-server.svg?branch=master)](https://travis-ci.org/Overv/openstreetmap-tile-server) [![](https://images.microbadger.com/badges/image/overv/openstreetmap-tile-server.svg)](https://microbadger.com/images/overv/openstreetmap-tile-server "openstreetmap-tile-server")

This container allows you to easily set up an OpenStreetMap PNG tile server given a `.osm.pbf` file.
It is based on the [latest Ubuntu 20.04 LTS guide](https://github.com/switch2osm/switch2osm/blob/master/serving-tiles/manually-building-a-tile-server-20-04-lts.md) from [switch2osm.org](https://switch2osm.org/) and therefore uses the default OpenStreetMap style.

## Building the Image

```bash
docker-compose -f docker-compose.yml -f docker-compose.build.yml build
```

## Setting up the server

Configure the docker-compose file according to your needs.
At the minimum you only have to edit the uri in `docker-compose.import.yml`.
However you may want to define host paths to store data instead of using volumes.
You also may want to change the allocated resources like maximum memory usage or number of threads.
See `docker-compose.yml` for instructions.

## Importing data

In order to import data first edit the file `docker-compose.import.yml` to your liking.
Edit the postgres configuration `cfg/postgresql.import.conf.tmpl` to speed up the import on high performance machines.
Start the import as follows:

```bash
docker-compose -f docker-compose.yml -f docker-compose.import.yml up
```

This will download the file as specified by the `DOWNLOAD_PBF` variable and import the data into the database.
You may also provide the data if you have already downloaded it.
See `docker-compose.import.yml` for instructions.
Note that you have to set the `UPDATE` option to `enabled` during the initial import if you want to update the database at a later stage.

## Pre-render data

Pre-rendering data is an import step to improve the usability of a map service.
Edit `docker-compose.prerender.yml` and `cfg/postgresql.prerender.conf.tmpl` to your needs.
You likely want to increase the used resources during pre-rendering to speed up the process.
Start the server:

```bash
docker-compose -f docker-compose.yml -f docker-compose.prerender.yml up -d
```

You can use the render_list_geo script to select the tiles to be rendered:

```bash
docker-compose exec map /usr/bin/render_list_geo -h
```

To render all tiles of Andorra up to zoom level 18 with 4 threads:

```bash
docker-compose exec map /usr/bin/render_list_geo -m ajt -n 4 -x 1.4135781 -X 1.7863837 -y 42.4288238 -Y 42.6559357 -z 0 -Z 18
```

Note the option `-m ajt` which is needed to select the correct map.
The map name is defined in `/usr/local/etc/renderd.conf`.
You can find bounding boxes for countries at the following [gist](https://gist.github.com/graydon/11198540).
You can also use the [tile calculator](https://tools.geofabrik.de/calc/) to compute the needed storage space and retrieve bounding boxes.

### Advanced

Prerendering the planet dataset this way results in a lot of tiles that show the ocean.
You can restrict the prerendering to tiles that contain data in the form of nodes with the [tiles-with-data](https://github.com/dbahrdt/tiles-with-data) program.
The program gives you a list of tiles containing at least one node.
This list can then be passed to render_list.

```bash
docker-compose -f docker-compose.yml exec map /bin/bash
tiles-with-data -f /data.osm.pbf -z 11 -t 4 | render_list -f -m ajt -n 8
```

Note that you should map an appropriate osm.pbf file under /data.osm.pbf.
The program is very simple and may need a rather large amount of memory.
For each tile to be rendered it needs roughly 8 Bytes of memory.

## Serving tiles

In order to serve tiles you have to edit the files `docker-compose.yml` and `cfg/postgresql.serve.conf.tmpl` to your needs.
Then start the container:

```bash
docker-compose -f docker-compose.yml up -d
```

Your tiles will now be available at `http://localhost:3080/tile/{z}/{x}/{y}.png`.
The demo map in `leaflet-demo.html` will then be available on `http://localhost:3080`.

### Cross-origin resource sharing

To enable the `Access-Control-Allow-Origin` header to be able to retrieve tiles from other domains, simply set the `ALLOW_CORS` variable to `enabled`.

```yaml
ALLOW_CORS=enabled
```

## Advanced usage

### Cleaning all files

You can clean all files using the following command.
This may be helpful if an import fails or if you want to import a new data set.

```bash
docker-compose -f docker-compose.yml -f docker-compose.clean.yml up
```

### Remove Database, but keep Tiles

You can clean the database using the following command.
This may be helpful if you only want to import a new database but keep the tiles already rendered.

```bash
docker-compose -f docker-compose.yml -f docker-compose.cleandb.yml up
```

This has the advantage that your tile server will serve the old tiles while they are still new enough.
It will not work correctly if you have updates enabled and import a dataset that is newer than the former database.
In that case some tiles that have changed data will not get rerendered.
You can retrieve the last valid timestamp of your database from the osmosis state:

```bash
$ docker-compose -f docker-compose exec map cat /var/lib/mod_tile/.osmosis/last.state.txt
#Fri Feb 04 00:00:09 UTC 2022
sequenceNumber=4917054
timestamp=2022-02-03T23\:59\:13Z
```

Use this information to get a dataset that is older than the timestamp.
If the time differs by more than a month then it may be better to rerender all tiles.

### Connecting to Postgres

To connect to the PostgreSQL database inside the container, make sure to expose port 5432 in the docker-compose file.

Use the user `renderer` and the database `gis` to connect.

```bash
psql -h localhost -U renderer gis
```

The default password is `renderer`, but it can be changed using the `PGPASSWORD` environment variable:

## Performance tuning and tweaking

Details for update procedure and invoked scripts can be found here [link](https://ircama.github.io/osm-carto-tutorials/updating-data/).

### THREADS

The import/tile serving/update processes use 2/1/1 threads by default, but this number can be changed by setting the `IMPORT_THREADS`/`RENDER_THREADS`/`UPDATE_THREADS` environment variable.

### CACHE

The import and tile serving processes use 800 MB RAM cache by default, but this number can be changed by option -C.
For example:

```yaml
OSM2PGSQL_EXTRA_ARGS=-C 4096
```

### AUTOVACUUM

The database uses the autovacuum feature by default.
This behavior can be changed with `AUTOVACUUM` environment variable.
For example:

```yaml
AUTOVACUUM=off
```

### Flat nodes

If you are planning to import the entire planet or you are running into memory errors then you may want to enable the `--flat-nodes` option for osm2pgsql.
You can then use it during the import process as follows:

```yaml
OSM2PGSQL_EXTRA_ARGS=--flat-nodes /nodes/flat_nodes.bin
```

> Note that if you use a folder other than `/nodes` then you must make sure that you manually set the owner to `renderer`!

## Troubleshooting

### ERROR: could not resize shared memory segment / No space left on device

If you encounter such entries in the log, it will mean that the default shared memory limit (64 MB) is too low for the container and it should be raised:

```bash
renderd[121]: ERROR: failed to render TILE ajt 2 0-3 0-3
renderd[121]: reason: Postgis Plugin: ERROR: could not resize shared memory segment "/PostgreSQL.790133961" to 12615680 bytes: ### No space left on device
```

To raise it use `shm-size` parameter. For example:

```yaml
    shm_size: 1G
```

For too high values you may notice excessive CPU load and memory usage.
It might be that you will have to experimentally find the best values for yourself.

### The import process unexpectedly exits

You may be running into problems with memory usage during the import.
Have a look at the "Flat nodes" section in this README.

## Internals

### run.sh

The entrypoint of the docker container is the `run.sh` script.
It takes care of executing the commands given on the command line.
We will describe the `import` and `run`commands in the following.

#### run.sh run

The run command starts the following daemons:

* Apache
* renderd
* cron
* Postgres

The Apache webserver is used to serve the tiles.
The renderd daemon renders the tiles.
Cron is used to do updates and is only active if updates are enabled.
The crontab is defined in the Dockerfile.
The postgres database is needed by renderd to render files and the update process to update the database.

#### run.sh import

The import command starts the following daemons:

* Postgres

It is used to import an osm.pbf file into a postgres database.
The data is either downloaded or an existing file is used.

### Configuration

The database can be configured by mounting an appropriate file to `/etc/postgresql/current/main/postgresql.custom.conf.tmpl`.
This file is used by the `import` and `run` commands to create the final postgres configuration file.
The postgres configuration file is created on each container start from scratch.
Hence it is possible to change the postgres configuration file by mapping another file template.
This mechanism is used by the `docker-compose.{import,prerender}.yml` files.
They simple set another configuration file located in the `cfg` folder.
This makes it ease to have multiple configurations in parallel, each with a task specific set of settings.

### openstreetmap-tiles-update-expire

This script is used to update the database and is run by cron.
It is run every 30 minutes as defined by the crontab of the Dockerfile.
It roughly does the following in order:

1. Download changes
2. Prune changes using data.poly if available
3. Import changes into database
4. Rerender all tiles with changed data

## License

```
Copyright 2019 Alexander Overvoorde

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```
