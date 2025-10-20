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
MQTT_PASS="${MQTT_PASS:-password1}"
MOSQUITTO_IMAGE="${MOSQUITTO_IMAGE:-eclipse-mosquitto:2.0.18}"  # pinned; falls back to :2 if needed

# Node-RED image (pin to a known-good tag instead of :latest)
NODERED_IMAGE="${NODERED_IMAGE:-nodered/node-red:3.1.9}"

# ==========================================

log() { printf "%s\n" "$*" >&2; }

pull_with_retry() {
  local image="$1"
  local tries="${2:-4}"
  local delay=2
  for i in $(seq 1 "$tries"); do
    if docker pull "$image"; then
      return 0
    fi
    log "[pull $image] attempt $i/$tries failed; retrying in ${delay}s..."
    sleep "$delay"; delay=$((delay*2))
  done
  return 1
}

echo "[1/9] Install Docker & Compose (if needed)"
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

echo "[2/9] Create project layout at ${STACK_DIR}"
mkdir -p "${STACK_DIR}"/{initdb,mosquitto,nodered}
cd "${STACK_DIR}"

# Ensure Node-RED data dir is writable by the container's default user (UID/GID 1000)
# This prevents Node-RED from crash-looping with EACCES on /data.
install -d -o 1000 -g 1000 -m 775 "${STACK_DIR}/nodered"

echo "[3/9] Write .env"
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

# Images
MOSQUITTO_IMAGE=${MOSQUITTO_IMAGE}
NODERED_IMAGE=${NODERED_IMAGE}
EOF

echo "[4/9] Write docker-compose.yml"
# (Removed the obsolete 'version:' key to silence warnings)
cat > docker-compose.yml <<'EOF'
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
      - "3306:3306"
    healthcheck:
      test: ["CMD-SHELL", "mysqladmin ping -h localhost -u root -p${MYSQL_ROOT_PASSWORD} --silent"]
      interval: 10s
      timeout: 5s
      retries: 30
    restart: unless-stopped

  mosquitto:
    image: ${MOSQUITTO_IMAGE}
    container_name: keezer-mqtt
    ports:
      - "1883:1883"
    volumes:
      - ./mosquitto/mosquitto.conf:/mosquitto/config/mosquitto.conf:ro
      - ./mosquitto/passwd:/mosquitto/config/passwd
      - mosq-data:/mosquitto/data
      - mosq-log:/mosquitto/log
    healthcheck:
      test: ["CMD-SHELL", "nc -z 127.0.0.1 1883 || exit 1"]
      interval: 10s
      timeout: 3s
      retries: 30
    restart: unless-stopped

  nodered:
    image: ${NODERED_IMAGE}
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
    healthcheck:
      test: ["CMD", "bash", "-lc", "curl -fsS http://127.0.0.1:1880/healthz || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 20
    restart: unless-stopped

volumes:
  mysql-data:
  mosq-data:
  mosq-log:
EOF

echo "[5/9] Seed MySQL with only 'kegs' table"
cat > initdb/01_kegs.sql <<'EOF'
CREATE TABLE IF NOT EXISTS kegs (
  id INT PRIMARY KEY,
  name VARCHAR(64) NULL,
  capacity_liters DECIMAL(6,2) NULL,
  tap_number INT NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
INSERT IGNORE INTO kegs (id, name, capacity_liters, tap_number)
VALUES
(1,'Keg 1',50.00,1),
(2,'Keg 2',50.00,2),
(3,'Keg 3',50.00,3),
(4,'Keg 4',50.00,4),
(5,'Keg 5',50.00,5),
(6,'Keg 6',50.00,6);
EOF

echo "[6/9] Write Mosquitto config"
cat > mosquitto/mosquitto.conf <<'EOF'
persistence true
persistence_location /mosquitto/data/

listener 1883
allow_anonymous false
password_file /mosquitto/config/passwd

max_inflight_messages 50
max_queued_messages 1000
autosave_interval 180
EOF

# Ensure passwd file exists with strict perms so mosquitto can start even before we add a user.
# (We will reset ownership to root:root again after adding the user to avoid the warning.)
install -m 600 /dev/null mosquitto/passwd || true

echo "[7/9] Pre-pull images with retry"
docker compose pull || true

# Extra resilience specifically for Mosquitto (Hub hiccups)
if ! pull_with_retry "${MOSQUITTO_IMAGE}"; then
  log "[warn] Pull ${MOSQUITTO_IMAGE} failed; trying fallback tag ':2'..."
  if ! pull_with_retry "eclipse-mosquitto:2"; then
    log "[fatal] Unable to pull any Mosquitto image. Try again later."
    exit 1
  fi
  # Patch compose file to use fallback if we had to
  sed -i 's|image: ${MOSQUITTO_IMAGE}|image: eclipse-mosquitto:2|' docker-compose.yml
fi

# Also pre-pull Node-RED in case DNS/Hub is flaky
pull_with_retry "${NODERED_IMAGE}" || true

echo "[8/9] Bring services up"
docker compose up -d

# Wait a few seconds for containers to come up before we hit mosquitto_passwd
sleep 3

echo "[9/9] Create/Update MQTT user inside the running container"
OK=0
for i in 1 2 3 4 5; do
  if docker exec keezer-mqtt sh -c "mosquitto_passwd -b /mosquitto/config/passwd '${MQTT_USER}' '${MQTT_PASS}' && kill -HUP 1" ; then
    echo "  -> MQTT user '${MQTT_USER}' updated and broker reloaded"
    OK=1
    break
  fi
  echo "  mosquitto not ready yet, retrying in 2s..."
  sleep 2
done
if [ "$OK" -ne 1 ]; then
  echo "  -> Could not set MQTT user automatically. You can run later:"
  echo "     docker exec -it keezer-mqtt mosquitto_passwd -b /mosquitto/config/passwd '${MQTT_USER}' '${MQTT_PASS}' && docker restart keezer-mqtt"
else
  # Silence the future warning: enforce root:root 600 on passwd, then restart to be safe
  docker exec keezer-mqtt sh -c 'chown root:root /mosquitto/config/passwd && chmod 600 /mosquitto/config/passwd'
  docker restart keezer-mqtt >/dev/null
fi

HOST_IP="$(hostname -I | awk '{print $1}')"
echo
echo "======== Base stack is up ========"
echo "MySQL   : ${HOST_IP}:3306   (db=${MYSQL_DB} user=${MYSQL_USER})"
echo "MQTT    : ${HOST_IP}:1883   (user=${MQTT_USER})"
echo "Node-RED: http://${HOST_IP}:1880"
echo
echo "Project dir: ${STACK_DIR}"
echo "To stop/start: cd ${STACK_DIR} && docker compose down|up -d"
