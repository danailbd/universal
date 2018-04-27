#!/bin/sh -ex
#
# This scripts deploys an environment for end-to-end tests based on Docker
# containers. It was initially developed to support CI.
#
# It builds a Docker image for GPII/universal and uses it to start two
# components: the Preferences Server and the Flow Manager.
#
# It also starts a CouchDB container and loads the CouchDB data into
# it, so tests running against the GPII components will have access to the
# latest test data.
#
# This script can be executed multiple times to create a new Docker image
# and deploy fresh containers every time.
#
# https://issues.gpii.net/browse/GPII-2470

# This script accepts an option "--no-rebuild" indicating to only start
# docker containers without rebuilding the universal docker image. If this
# option is not provided, the old docker containers will be removed and the
# universal docker image will be rebuilt.
# Example command to build from the scratch: ./vagrantCloudBasedContainers.sh
# Example command not to rebuild: ./vagrantCloudBasedContainers.sh --no-rebuild

if  [ "$1" == "--no-rebuild" ]; then
    NO_REBUILD=true
fi

UNIVERSAL_IMAGE=vagrant-universal

COUCHDB_IMAGE=couchdb
COUCHDB_PORT=5984
COUCHDB_HEALTHCHECK_DELAY=2
COUCHDB_HEALTHCHECK_TIMEOUT=30

DBDATA_DIR_STATIC="/home/vagrant/sync/universal/testData/dbData"
DBDATA_DIR_BUILD="/home/vagrant/sync/universal/build/dbData"

DATALOADER_IMAGE="cindyqili/gpii-dataloader"
DATALOADER_COUCHDB_URL="http://couchdb:${COUCHDB_PORT}/gpii"
DATASOURCE_HOSTNAME="http://couchdb"

PREFERENCES_CONFIG="gpii.config.preferencesServer.standalone.production"
PREFERENCES_PORT=9081

FLOWMANAGER_CONFIG="gpii.config.cloudBased.flowManager.production"
FLOWMANAGER_PORT=9082
FLOWMANAGER_MATCHMAKER_URL="http://localhost:9082"
FLOWMANAGER_TO_PREFERENCESSERVER_URL="http://preferences:${PREFERENCES_PORT}/preferences/%gpiiKey?merge=%merge"

# The URL to point to the flow manager docker container, only used by running the production config tests
FLOWMANAGER_URL="http://flowmanager:9082"

# The URLs to test the readiness of each docker container
COUCHDB_VIEW_URL="http://localhost:$COUCHDB_PORT/gpii/_design/views/_view/findPrefsSafeByGpiiKey?key=%22carla%22&include_docs=true"
CARLA_PREFERENCES_URL="http://localhost:$PREFERENCES_PORT/preferences/carla"
CARLA_SETTINGS_URL="http://localhost:$FLOWMANAGER_PORT/carla/settings/%7B%22OS%22:%7B%22id%22:%22linux%22%7D,%22solutions%22:[%7B%22id%22:%22org.gnome.desktop.a11y.magnifier%22%7D]%7D"

# Remove old containers (exit code is ignored)
docker rm -f couchdb 2>/dev/null || true
docker rm -f preferences 2>/dev/null || true
docker rm -f flowmanager 2>/dev/null || true
docker rm -f productionConfigTests 2>/dev/null || true

if [ "$NO_REBUILD" != "true" ] ; then
    # Remove old image (exit code is ignored)
    docker rmi -f $UNIVERSAL_IMAGE 2>/dev/null || true

    # Build image
    docker build -t $UNIVERSAL_IMAGE .
fi

# Start the CouchDB container
docker run -d -p $COUCHDB_PORT:$COUCHDB_PORT --name couchdb $COUCHDB_IMAGE

# Wait for CouchDB
wget -O /dev/null --retry-connrefused --waitretry=$COUCHDB_HEALTHCHECK_DELAY --read-timeout=20 --timeout=1 --tries=$COUCHDB_HEALTHCHECK_TIMEOUT http://localhost:$COUCHDB_PORT

# Load the CouchDB data
docker run --rm --link couchdb -v $DBDATA_DIR_STATIC:/data -e DBDATA_DIR=/data -e COUCHDB_URL=$DATALOADER_COUCHDB_URL -e CLEAR_INDEX=1 $DATALOADER_IMAGE
docker run --rm --link couchdb -v $DBDATA_DIR_BUILD:/data -e DBDATA_DIR=/data -e COUCHDB_URL=$DATALOADER_COUCHDB_URL $DATALOADER_IMAGE

# Wait for the CouchDB views become accessible. Accessing the view URL forced the view index to build which take time.
# The URL returns 500 when the index is not ready, so use "--retry-on-http-error" option to continue retries at 500 response code.
wget -O /dev/null --retry-connrefused --waitretry=10 --read-timeout=20 --timeout=1 --tries=30 --retry-on-http-error=500 $COUCHDB_VIEW_URL

# Start the preferences server container
docker run -d -p $PREFERENCES_PORT:$PREFERENCES_PORT --name preferences --link couchdb -e NODE_ENV=$PREFERENCES_CONFIG  -e PREFERENCESSERVER_LISTEN_PORT=$PREFERENCES_PORT -e DATASOURCE_HOSTNAME=$DATASOURCE_HOSTNAME -e DATASOURCE_PORT=$COUCHDB_PORT $UNIVERSAL_IMAGE

# Wait for the preferences server container to be ready
wget -O /dev/null --retry-connrefused --waitretry=10 --read-timeout=20 --timeout=1 --tries=30 $CARLA_PREFERENCES_URL

# Start the flow manager container
docker run -d -p $FLOWMANAGER_PORT:$FLOWMANAGER_PORT --name flowmanager --link couchdb --link preferences -e NODE_ENV=$FLOWMANAGER_CONFIG -e FLOWMANAGER_LISTEN_PORT=$FLOWMANAGER_PORT -e DATASOURCE_HOSTNAME=$DATASOURCE_HOSTNAME -e DATASOURCE_PORT=$COUCHDB_PORT -e FLOWMANAGER_MATCHMAKER_URL=$FLOWMANAGER_MATCHMAKER_URL -e FLOWMANAGER_TO_PREFERENCESSERVER_URL=$FLOWMANAGER_TO_PREFERENCESSERVER_URL $UNIVERSAL_IMAGE

# Wait for the flow manager container to be ready
wget -O /dev/null --retry-connrefused --waitretry=10 --read-timeout=20 --timeout=1 --tries=30 $CARLA_SETTINGS_URL

# Start the container to run production config tests
FLOWMANAGER_URL=$FLOWMANAGER_URL docker run --name productionConfigTests --link flowmanager $UNIVERSAL_IMAGE node tests/ProductionConfigTests.js
