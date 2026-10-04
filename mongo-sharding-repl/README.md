## Запуск сервисов:

```bash
docker compose up -d
```

## Инициализация и заполнение данными

### Скриптом (нейронка сделала)

```bash
./scripts/mongo-init.sh
```

### Руками:

Инициализируем сервер конфигурации

```bash
docker compose exec -T configSrv mongosh --port 27017 --quiet <<EOF
rs.initiate(
  {
    _id : "config_server",
       configsvr: true,
    members: [
      { _id : 0, host : "configSrv:27017" }
    ]
  }
);
EOF  
```

Проверим инициализацию:

```bash
docker compose exec -T configSrv mongosh --port 27017 --quiet --eval 'rs.status().myState'
```

Инициализируем шарды

```bash
docker compose exec -T shard1_1 mongosh --port 27018 --quiet <<EOF
rs.initiate(
  {
    _id : "shard1",
    members: [
      { _id : 0, host : "shard1_1:27018" },
      { _id : 1, host : "shard1_2:27018" },
      { _id : 2, host : "shard1_3:27018" },
    ]
}
);
EOF  
```

```bash
docker compose exec -T shard2_1 mongosh --port 27019 --quiet <<EOF
rs.initiate(
  {
    _id : "shard2",
    members: [
      { _id : 0, host : "shard2_1:27019" },
      { _id : 1, host : "shard2_2:27019" },
      { _id : 2, host : "shard2_3:27019" }
    ]
  }
);
EOF  
```

Инициализируем роутер и наполним данными

```bash
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<EOF
sh.addShard( "shard1/shard1_1:27018,shard1_2:27018,shard1_3:27018");
sh.addShard( "shard2/shard2_1:27019,shard2_2:27019,shard2_3:27019");
sh.enableSharding("somedb");
sh.shardCollection("somedb.helloDoc", { "name" : "hashed" } );
use somedb
for (var i = 0; i < 1000; i++) {
  db.helloDoc.insertOne({age: i, name: "ly" + i});
}
db.helloDoc.countDocuments();
EOF  
```

## Проверка общего кол-ва документов:

```bash
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<EOF
use somedb
db.helloDoc.countDocuments()
EOF
```

## Проверка кол-ва документов на шардах:

### Через API (нейронка ручку сделала):

Откройте в браузере http://localhost:8080/helloDoc/stats

### Через mongo

```bash
docker compose exec -T shard1_1 mongosh "mongodb://shard1_1:27018,shard1_2:27018,shard1_3:27018/?replicaSet=shard1" --quiet <<EOF
use somedb
db.helloDoc.countDocuments()
EOF 
``` 

```bash
docker compose exec -T shard2_1 mongosh "mongodb://shard2_1:27019,shard2_2:27019,shard2_3:27019/?replicaSet=shard2" --quiet <<EOF
use somedb
db.helloDoc.countDocuments()
EOF 
```
