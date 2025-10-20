#!/usr/bin/env bash
set -euo pipefail

# ========= User-tweakable defaults =========
STACK_DIR="${STACK_DIR:-/opt/keezer-base}"
TZ="${TZ:-Pacific/Auckland}"

# MySQL bits
MYSQL_DB="${MYSQL_DB:-keezer}"
MYSQL_USER="${MYSQL_USER:-keezeruser}"
MYSQL_PASS="${MYSQL_PASS:-password1}"
MYSQL_ROOT_PASS="${MYSQL_ROOT_PASS:-password1}"

# MQTT bits (Mosquitto)
MQTT_USER="${MQTT_USER:-keezer}"
MQTT_PASS="${MQTT_PASS:-password}"

# ==========================================

echo "[1/7] Install Docker & Compose (if needed)"
if ! command -v docker >/dev/null 2>&1; then
  apt-get update
  apt-get install -y ca-certificates curl gnupg lsb-release
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
fi

echo "[2/7] Create project layout at ${STACK_DIR}"
mkdir -p "${STACK_DIR}"/{initdb,mosquitto,nodered}
cd "${STACK_DIR}"

echo "[3/7] Write .env"
cat > .env <<EOF
TZ=${TZ}

# MySQL
MYSQL_DATABASE=${MYSQL_DB}
MYSQL_USER=${MYSQL_USER}
MYSQL_PASSWORD=${MYSQL_PASS}
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASS}

# MQTT
MQTT_USER=${MQTT_USER}
MQTT_PASSWORD=${MQTT_PASS}
EOF

echo "[4/7] Write docker-compose.yml"
cat > docker-compose.yml <<'EOF'
version: "3.8"
services:
  mysql:
    image: mysql:8.0
    container_name: keezer-mysql
    environment:
      MYSQL_DATABASE: ${MYSQL_DATABASE}
      MYSQL_USER: ${MYSQL_USER}
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      TZ: ${TZ}
    volumes:
      - ./initdb:/docker-entrypoint-initdb.d
      - mysql-data:/var/lib/mysql
    ports:
      - "3306:3306"   # optional: expose if you want to reach it from host
    healthcheck:
      test: ["CMD-SHELL", "mysqladmin ping -h localhost -u root -p${MYSQL_ROOT_PASSWORD} --silent"]
      interval: 10s
      timeout: 3s
      retries: 30
    restart: unless-stopped

  mosquitto:
    image: eclipse-mosquitto:2
    container_name: keezer-mqtt
    ports:
      - "1883:1883"
    volumes:
      - ./mosquitto/mosquitto.conf:/mosquitto/config/mosquitto.conf:ro
      - ./mosquitto/passwd:/mosquitto/config/passwd:ro
      - mosq-data:/mosquitto/data
      - mosq-log:/mosquitto/log
    restart: unless-stopped

  nodered:
    image: nodered/node-red:latest
    container_name: keezer-nodered
    ports:
      - "1880:1880"
    environment:
      - TZ=${TZ}
    volumes:
      - ./nodered:/data
    depends_on:
      - mosquitto
      - mysql
    restart: unless-stopped

volumes:
  mysql-data:
  mosq-data:
  mosq-log:
EOF

echo "[5/7] Seed MySQL with only 'kegs' table"
cat > initdb/01_kegs.sql <<'EOF'
-- Minimal Keezer base: only the kegs table
CREATE TABLE IF NOT EXISTS kegs (
  id INT PRIMARY KEY,
  name VARCHAR(64) NULL,
  capacity_liters DECIMAL(6,2) NULL,
  tap_number INT NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
-- Optional: seed some keg rows you can edit later
INSERT IGNORE INTO kegs (id, name, capacity_liters, tap_number)
VALUES
(1,'Keg 1',50.00,1),
(2,'Keg 2',50.00,2),
(3,'Keg 3',50.00,3),
(4,'Keg 4',50.00,4),
(5,'Keg 5',50.00,5),
(6,'Keg 6',50.00,6);
EOF

echo "[6/7] Write Mosquitto config and create user"
cat > mosquitto/mosquitto.conf <<'EOF'
persistence true
persistence_location /mosquitto/data/

listener 1883
allow_anonymous false
password_file /mosquitto/config/passwd

# sane limits
max_inflight_messages 50
max_queued_messages 1000
autosave_interval 180
EOF

# create/update passwd file inside host dir using container's mosquitto_passwd binary
docker run --rm -i -v "${STACK_DIR}/mosquitto:/mosquitto" eclipse-mosquitto:2 \
  mosquitto_passwd -b /mosquitto/config/passwd "${MQTT_USER}" "${MQTT_PASS}"

echo "[7/7] Bring services up"
docker compose pull
docker compose up -d

HOST_IP="$(hostname -I | awk '{print $1}')"
echo
echo "======== Base stack is up ========"
echo "MySQL   : ${HOST_IP}:3306   (db=${MYSQL_DB} user=${MYSQL_USER})"
echo "MQTT    : ${HOST_IP}:1883   (user=${MQTT_USER})"
echo "Node-RED: http://${HOST_IP}:1880"
echo
echo "Project dir: ${STACK_DIR}"
echo "To stop/start: cd ${STACK_DIR} && docker compose down|up -d"
