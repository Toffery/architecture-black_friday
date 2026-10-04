#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname -- "$SCRIPT_DIR")"
COMPOSE=(docker compose --project-directory "$PROJECT_DIR")

wait_for_mongo() {
  local service="$1"
  local port="$2"

  echo "Waiting for ${service} to accept connections..."
  until "${COMPOSE[@]}" exec -T "$service" \
    mongosh --port "$port" --quiet \
    --eval 'quit(db.adminCommand({ ping: 1 }).ok ? 0 : 1)' \
    >/dev/null 2>&1
  do
    sleep 1
  done
}

wait_for_primary() {
  local service="$1"
  local port="$2"

  echo "Waiting for ${service} to become PRIMARY..."
  until "${COMPOSE[@]}" exec -T "$service" \
    mongosh --port "$port" --quiet \
    --eval 'quit(db.hello().isWritablePrimary ? 0 : 1)' \
    >/dev/null 2>&1
  do
    sleep 1
  done
}

wait_for_replica_set() {
  local service="$1"
  local port="$2"

  echo "Waiting for ${service} replica set: one PRIMARY and two SECONDARY..."
  until "${COMPOSE[@]}" exec -T "$service" \
    mongosh --port "$port" --quiet \
    --eval 'const members = rs.status().members;
      quit(members.length === 3 &&
        members.every(m => m.health === 1) &&
        members.filter(m => m.stateStr === "PRIMARY").length === 1 &&
        members.filter(m => m.stateStr === "SECONDARY").length === 2 ? 0 : 1)' \
    >/dev/null 2>&1
  do
    sleep 1
  done
}

wait_for_mongo configSrv 27017
wait_for_mongo shard1_1 27018
wait_for_mongo shard1_2 27018
wait_for_mongo shard1_3 27018
wait_for_mongo shard2_1 27019
wait_for_mongo shard2_2 27019
wait_for_mongo shard2_3 27019

echo "Initializing config server replica set..."
"${COMPOSE[@]}" exec -T configSrv mongosh --port 27017 --quiet <<'EOF'
try {
  const status = rs.status();
  print(`Replica set ${status.set} is already initialized`);
} catch (error) {
  if (error.codeName !== "NotYetInitialized") throw error;
  printjson(rs.initiate({
    _id: "config_server",
    configsvr: true,
    members: [
      { _id: 0, host: "configSrv:27017" }
    ]
  }));
}
EOF

wait_for_primary configSrv 27017

echo "Initializing shard1 replica set..."
"${COMPOSE[@]}" exec -T shard1_1 mongosh --port 27018 --quiet <<'EOF'
try {
  const status = rs.status();
  print(`Replica set ${status.set} is already initialized`);
} catch (error) {
  if (error.codeName !== "NotYetInitialized") throw error;
  printjson(rs.initiate({
    _id: "shard1",
    members: [
      { _id: 0, host: "shard1_1:27018" },
      { _id: 1, host: "shard1_2:27018" },
      { _id: 2, host: "shard1_3:27018" }
    ]
  }));
}
EOF

echo "Initializing shard2 replica set..."
"${COMPOSE[@]}" exec -T shard2_1 mongosh --port 27019 --quiet <<'EOF'
try {
  const status = rs.status();
  print(`Replica set ${status.set} is already initialized`);
} catch (error) {
  if (error.codeName !== "NotYetInitialized") throw error;
  printjson(rs.initiate({
    _id: "shard2",
    members: [
      { _id: 0, host: "shard2_1:27019" },
      { _id: 1, host: "shard2_2:27019" },
      { _id: 2, host: "shard2_3:27019" }
    ]
  }));
}
EOF

wait_for_replica_set shard1_1 27018
wait_for_replica_set shard2_1 27019
wait_for_mongo mongos_router 27020

echo "Adding shards and configuring somedb.helloDoc..."
"${COMPOSE[@]}" exec -T mongos_router mongosh --port 27020 --quiet <<'EOF'
const configDb = db.getSiblingDB("config");

if (!configDb.shards.findOne({ _id: "shard1" })) {
  printjson(sh.addShard("shard1/shard1_1:27018,shard1_2:27018,shard1_3:27018"));
} else {
  print("Shard shard1 is already registered");
}

if (!configDb.shards.findOne({ _id: "shard2" })) {
  printjson(sh.addShard("shard2/shard2_1:27019,shard2_2:27019,shard2_3:27019"));
} else {
  print("Shard shard2 is already registered");
}

const databaseInfo = configDb.databases.findOne({ _id: "somedb" });
if (!databaseInfo || databaseInfo.partitioned !== true) {
  printjson(sh.enableSharding("somedb"));
} else {
  print("Sharding is already enabled for somedb");
}

const collectionInfo = configDb.collections.findOne({
  _id: "somedb.helloDoc",
  dropped: { $ne: true }
});
if (!collectionInfo) {
  printjson(sh.shardCollection("somedb.helloDoc", { name: "hashed" }));
} else {
  print("Collection somedb.helloDoc is already sharded");
}

const helloDoc = db.getSiblingDB("somedb").helloDoc;
for (let i = 0; i < 1000; i++) {
  helloDoc.updateOne(
    { name: `ly${i}` },
    { $setOnInsert: { age: i, name: `ly${i}` } },
    { upsert: true }
  );
}

print(`Total documents: ${helloDoc.countDocuments()}`);
EOF

echo "Documents on shard1:"
"${COMPOSE[@]}" exec -T shard1_1 mongosh \
  "mongodb://shard1_1:27018,shard1_2:27018,shard1_3:27018/?replicaSet=shard1" --quiet \
  --eval 'db.getSiblingDB("somedb").helloDoc.countDocuments()'

echo "Documents on shard2:"
"${COMPOSE[@]}" exec -T shard2_1 mongosh \
  "mongodb://shard2_1:27019,shard2_2:27019,shard2_3:27019/?replicaSet=shard2" --quiet \
  --eval 'db.getSiblingDB("somedb").helloDoc.countDocuments()'

echo "MongoDB sharding initialization completed."
