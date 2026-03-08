#!/bin/bash
set -uo pipefail

trap 'warn "Failed at line ${LINENO}: ${BASH_COMMAND}"; exit 1' ERR

COMPOSE_FILE="docker-compose.yml"
ENV_FILE=".env"
CACHE_FILE=".adsb_publisher_setup_save"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

AUTO=false
[[ "${1:-}" == "--auto" || "${1:-}" == "-y" ]] && AUTO=true

ULTRAFEEDER_IMAGE="ghcr.io/sdr-enthusiasts/docker-adsb-ultrafeeder:telegraf"

log() { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${RED}[!]${NC} $1"; }
ask() { echo -ne "${CYAN}[?]${NC} $1"; }

load_cache() {
    [[ -f "${CACHE_FILE}" ]] || return
    log "Found previous answers in ${CACHE_FILE}"
    # shellcheck source=/dev/null
    source "${CACHE_FILE}"
}

save_answer() {
    local key="$1" val="$2"
    if grep -q "^${key}=" "${CACHE_FILE}" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${val}|" "${CACHE_FILE}"
        return
    fi
    echo "${key}=${val}" >> "${CACHE_FILE}"
}

# prompt with cached default: prompt_cached VAR_NAME "prompt text" "fallback_default"
prompt_cached() {
    local var_name="$1" prompt_text="$2" fallback="${3:-}"
    local cached="${!var_name:-${fallback}}"
    if [[ "${AUTO}" == true && -n "${cached}" ]]; then
        eval "${var_name}=\"\${cached}\""
        log "${prompt_text}: ${cached}"
        return
    fi
    local full_prompt="${prompt_text}"
    [[ -n "${cached}" ]] && full_prompt="${full_prompt} [${cached}]"
    ask "${full_prompt}: "
    local input
    read -r input < /dev/tty
    eval "${var_name}=\"\${input:-\${cached}}\""
    save_answer "${var_name}" "${!var_name}"
}

# prompt for port with cached default: prompt_port VAR_NAME "prompt text" "fallback_default"
prompt_port() {
    local var_name="$1" prompt_text="$2" fallback="${3:-}"
    local cached="${!var_name:-${fallback}}"
    if [[ "${AUTO}" == true && -n "${cached}" ]]; then
        eval "${var_name}=\"\${cached}\""
        log "${prompt_text}: ${cached}"
        return
    fi
    local full_prompt="${prompt_text} (- = no expose)"
    [[ -n "${cached}" ]] && full_prompt="${full_prompt} [${cached}]"
    ask "${full_prompt}: "
    local input
    read -r input < /dev/tty
    if [[ "${input}" == "-" ]]; then
        eval "${var_name}=''"
    else
        eval "${var_name}=\"\${input:-\${cached}}\""
    fi
    save_answer "${var_name}" "${!var_name}"
}

check_sudo() {
    if ! sudo -v 2>/dev/null; then
        warn "sudo access required. Run with a user that has sudo privileges."
        exit 1
    fi
}

check_deps() {
    local missing=()
    for cmd in docker curl jq; do
        command -v "${cmd}" &>/dev/null && continue
        missing+=("${cmd}")
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        return
    fi

    warn "Missing required tools: ${missing[*]}"
    warn "Install them and re-run this script."
    exit 1
}

blacklist_kernel_drivers() {
    local modules=(dvb_usb_rtl28xxu rtl2832 rtl2830 dvb_usb_rtl2832u dvb_usb_v2 dvb_core)
    local missing=()

    for mod in "${modules[@]}"; do
        grep -rq "blacklist ${mod}" /etc/modprobe.d/ 2>/dev/null && continue
        missing+=("${mod}")
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        log "Kernel DVB drivers already blacklisted, skipping."
        return
    fi

    log "Blacklisting kernel DVB drivers: ${missing[*]}..."
    for mod in "${missing[@]}"; do
        echo "blacklist ${mod}" | sudo tee -a /etc/modprobe.d/blacklist-rtlsdr.conf > /dev/null
    done

    sudo rmmod dvb_usb_rtl28xxu 2>/dev/null || true
    sudo rmmod rtl2832 2>/dev/null || true
    sudo rmmod rtl2830 2>/dev/null || true
    log "Kernel drivers blacklisted."
}

pull_ultrafeeder_image() {
    log "Pulling ultrafeeder image (used for SDR tools + runtime)..."
    docker pull "${ULTRAFEEDER_IMAGE}" -q
    log "Image pulled."
}

detect_location() {
    log "Detecting location from IP..."
    local geo
    geo=$(curl -sf --max-time 5 "http://ip-api.com/json/?fields=lat,lon,timezone,city" 2>/dev/null) || return

    DEFAULT_LAT=$(echo "${geo}" | jq -r '.lat // empty')
    DEFAULT_LON=$(echo "${geo}" | jq -r '.lon // empty')
    DEFAULT_TZ=$(echo "${geo}" | jq -r '.timezone // empty')
    DEFAULT_CITY=$(echo "${geo}" | jq -r '.city // empty')

    if [[ -z "${DEFAULT_LAT}" || -z "${DEFAULT_LON}" ]]; then
        return
    fi

    log "Detected: ${DEFAULT_CITY} (${DEFAULT_LAT}, ${DEFAULT_LON}) ${DEFAULT_TZ}"

    local elev
    elev=$(curl -sf --max-time 5 "https://api.open-meteo.com/v1/elevation?latitude=${DEFAULT_LAT}&longitude=${DEFAULT_LON}" 2>/dev/null) || return
    DEFAULT_ALT=$(echo "${elev}" | jq -r '.elevation[0] // empty' | cut -d. -f1)

    if [[ -n "${DEFAULT_ALT}" ]]; then
        log "Detected ground elevation: ${DEFAULT_ALT}m"
    fi
}

collect_info() {
    echo ""
    log "=== Station Configuration ==="
    echo ""

    # geo-detect only fills in gaps not already cached
    if [[ -z "${STATION_NAME:-}" || -z "${LAT:-}" || -z "${LON:-}" ]]; then
        detect_location
        STATION_NAME="${STATION_NAME:-${DEFAULT_CITY:-}}"
        LAT="${LAT:-${DEFAULT_LAT:-}}"
        LON="${LON:-${DEFAULT_LON:-}}"
        ALT="${ALT:-${DEFAULT_ALT:-}}"
        TZ_VAL="${TZ_VAL:-${DEFAULT_TZ:-Europe/Bucharest}}"
    fi

    prompt_cached STATION_NAME "Station name (no spaces, letters/numbers/-/_ only)"
    prompt_cached LAT "Latitude"
    prompt_cached LON "Longitude"
    prompt_cached ALT "Altitude in meters above sea level"
    prompt_cached TZ_VAL "Timezone" "Europe/Bucharest"

    if [[ -z "${UUID:-}" ]]; then
        UUID=$(cat /proc/sys/kernel/random/uuid)
    fi
    save_answer UUID "${UUID}"
    log "UUID: ${UUID}"

    echo ""
    log "=== Port Configuration ==="
    echo ""

    prompt_port ULTRAFEEDER_PORT "Ultrafeeder web UI (tar1090/graphs1090) port" "10980"
    prompt_port GRAFANA_PORT "Grafana dashboard port" "10984"
}

detect_sdr() {
    echo ""
    log "=== SDR Detection ==="
    log "Detecting RTL-SDR devices via container..."

    local output
    output=$(docker run --rm --device /dev/bus/usb \
        --entrypoint rtl_test "${ULTRAFEEDER_IMAGE}" -t 2>&1 | head -30) || true

    local device_lines
    device_lines=$(echo "${output}" | grep -E "^\s+[0-9]+:" || true)

    if [[ -z "${device_lines}" ]]; then
        warn "No RTL-SDR devices found. Plug one in and re-run."
        exit 1
    fi

    local count
    count=$(echo "${device_lines}" | wc -l)

    echo ""
    log "Found ${count} device(s):"
    echo ""
    while IFS= read -r line; do
        local idx mfg product serial
        idx=$(echo "${line}" | sed -E 's/^\s+([0-9]+):.*/\1/')
        mfg=$(echo "${line}" | sed -E 's/^\s+[0-9]+:\s+//' | cut -d, -f1)
        product=$(echo "${line}" | cut -d, -f2 | xargs)
        serial=$(echo "${line}" | grep -oP 'SN:\s*\K.*' | xargs)
        echo "  [${idx}] ${mfg} ${product}"
        echo "       Serial: ${serial}"
        echo ""
    done <<< "${device_lines}"

    if [[ "${count}" -eq 1 ]]; then
        SDR_DEVICE_INDEX=0
        save_answer SDR_DEVICE_INDEX 0
        log "Single device found, using index 0."
    else
        prompt_cached SDR_DEVICE_INDEX "Which device index to use for ADS-B?" "0"
    fi

    prompt_cached SDR_PPM "SDR frequency correction in PPM (0 for TCXO dongles like RTL-SDR Blog V4)" "0"
}

signup_fr24() {
    echo ""
    prompt_cached DO_FR24 "Set up FlightRadar24? (y/n)" "${DO_FR24:-n}"

    if [[ "${DO_FR24}" != "y" ]]; then
        FR24_KEY=""
        return
    fi

    if [[ -n "${FR24_KEY:-}" ]]; then
        prompt_cached FR24_KEY "FR24 sharing key"
    else
        ask "Already have a FR24 sharing key? (y/n): "
        read -r HAS_KEY < /dev/tty

        if [[ "${HAS_KEY}" == "y" ]]; then
            prompt_cached FR24_KEY "Enter your FR24 sharing key"
        else
            log "Starting FR24 signup process..."
            docker run --rm -it --entrypoint /usr/bin/fr24feed \
                ghcr.io/sdr-enthusiasts/docker-flightradar24 --signup
            echo ""
            prompt_cached FR24_KEY "Enter the sharing key you just received"
        fi
    fi

    prompt_port FR24_PORT "FR24 status page port" "10981"
}

signup_piaware() {
    echo ""
    prompt_cached DO_PIAWARE "Set up FlightAware (piaware)? (y/n)" "${DO_PIAWARE:-n}"

    if [[ "${DO_PIAWARE}" != "y" ]]; then
        DO_PIAWARE="n"
        PIAWARE_ID=""
        return
    fi

    if [[ -n "${PIAWARE_ID:-}" ]]; then
        prompt_cached PIAWARE_ID "FlightAware feeder ID"
    else
        ask "Already have a FlightAware feeder ID? (y/n): "
        read -r HAS_PIAWARE < /dev/tty

        if [[ "${HAS_PIAWARE}" == "y" ]]; then
            prompt_cached PIAWARE_ID "Enter your FlightAware feeder ID"
        else
            PIAWARE_ID=""
            log "Piaware will auto-generate a feeder ID on first start."
            log "After launch, find it with: docker compose logs piaware | grep 'feeder ID'"
            log "Then claim it at: https://flightaware.com/adsb/piaware/claim"
        fi
    fi

    prompt_port PIAWARE_PORT "Piaware web UI port" "10982"
}


setup_planesnitch() {
    echo ""
    prompt_cached DO_PLANESNITCH "Set up planesnitch (aircraft alerts to Telegram/webhooks)? (y/n)" "${DO_PLANESNITCH:-n}"

    if [[ "${DO_PLANESNITCH}" != "y" ]]; then
        DO_PLANESNITCH="n"
        return
    fi
}

write_planesnitch_config() {
    log "Writing planesnitch config..."
    mkdir -p planesnitch/csv

    # download all plane-alert-db CSVs
    local csv_base="https://raw.githubusercontent.com/sdr-enthusiasts/plane-alert-db/main"
    local csvs=("plane-alert-db" "plane-alert-mil" "plane-alert-gov" "plane-alert-pol" "plane-alert-pia" "plane-alert-civ")
    for csv in "${csvs[@]}"; do
        log "Downloading ${csv}.csv..."
        curl -sf "${csv_base}/${csv}.csv" -o "planesnitch/csv/${csv}.csv" 2>/dev/null || warn "Failed to download ${csv}.csv"
    done

    cat > planesnitch/config.yaml <<EOF
poll_interval: 15s
display_units: aviation

locations:
  ${STATION_NAME}:
    name: "${STATION_NAME}"
    lat: ${LAT}
    lon: ${LON}
    radius: 150km

sources:
  - type: ultrafeeder
    url: http://ultrafeeder:80/tar1090/data/aircraft.json
  - type: adsb_lol
  - type: adsb_fi
  - type: airplanes_live
  - type: adsb_one

watchlists:
  emergencies:
    type: squawk
    values: ["7500", "7600", "7700", "7400", "7777"]
  military:
    type: icao_csv
    source: /csv/plane-alert-mil.csv
  government:
    type: icao_csv
    source: /csv/plane-alert-gov.csv
  police:
    type: icao_csv
    source: /csv/plane-alert-pol.csv
  interesting:
    type: icao_csv
    source: /csv/plane-alert-db.csv
  pia:
    type: icao_csv
    source: /csv/plane-alert-pia.csv
  civilian:
    type: icao_csv
    source: /csv/plane-alert-civ.csv
  low_flyers:
    type: proximity
    min_altitude: 0ft
    max_altitude: 3000ft

# No alerts enabled yet. Uncomment and edit the sections below.
# Full docs: https://github.com/psyb0t/docker-planesnitch

alerts: []

# alerts:
#   - name: "Emergency Alert"
#     watchlists: [emergencies]
#     cooldown: 1m
#     notify: [my_telegram]
#
#   - name: "Military Spotter"
#     watchlists: [military]
#     cooldown: 5m
#     notify: [my_telegram]
#
#   - name: "Government Watch"
#     watchlists: [government]
#     cooldown: 5m
#     notify: [my_telegram]
#
#   - name: "Police Activity"
#     watchlists: [police]
#     cooldown: 5m
#     notify: [my_telegram]
#
#   - name: "Interesting Aircraft"
#     watchlists: [interesting, pia, civilian]
#     cooldown: 5m
#     notify: [my_telegram]
#
#   - name: "Low Flyer"
#     watchlists: [low_flyers]
#     cooldown: 10m
#     notify: [my_telegram]

# notifications:
#   my_telegram:
#     type: telegram
#     bot_token: "YOUR_BOT_TOKEN"
#     chat_id: "YOUR_CHAT_ID"
#
#   my_webhook:
#     type: webhook
#     url: "https://example.com/hook"
#     headers:
#       Authorization: "Bearer YOUR_TOKEN"
EOF
    log "planesnitch config written."
    echo ""
    log "planesnitch is pre-configured but has no alerts enabled."
    log "Edit planesnitch/config.yaml to set up notifications."
    log "Docs: https://github.com/psyb0t/docker-planesnitch"
}

write_env() {
    log "Writing ${ENV_FILE}..."
    cat > "${ENV_FILE}" <<EOF
FEEDER_TZ=${TZ_VAL}
FEEDER_LAT=${LAT}
FEEDER_LONG=${LON}
FEEDER_ALT_M=${ALT}
FEEDER_NAME=${STATION_NAME}
ADSB_SDR_DEVICE=${SDR_DEVICE_INDEX}
ADSB_SDR_GAIN=autogain
ADSB_SDR_PPM=${SDR_PPM}
UUID=${UUID}
FR24_SHARING_KEY=${FR24_KEY}
PIAWARE_FEEDER_ID=${PIAWARE_ID}
EOF
    log "Environment file written."
}

write_compose() {
    log "Writing ${COMPOSE_FILE}..."

    cat > "${COMPOSE_FILE}" <<'YAML'
services:
  ultrafeeder:
    image: ghcr.io/sdr-enthusiasts/docker-adsb-ultrafeeder:telegraf
    restart: unless-stopped
    device_cgroup_rules:
      - 'c 189:* rwm'
    environment:
      - LOGLEVEL=error
      - TZ=${FEEDER_TZ}
      - READSB_DEVICE_TYPE=rtlsdr
      - READSB_RTLSDR_DEVICE=${ADSB_SDR_DEVICE}
      - READSB_RTLSDR_PPM=${ADSB_SDR_PPM}
      - READSB_LAT=${FEEDER_LAT}
      - READSB_LON=${FEEDER_LONG}
      - READSB_ALT=${FEEDER_ALT_M}m
      - READSB_GAIN=${ADSB_SDR_GAIN}
      - READSB_RX_LOCATION_ACCURACY=2
      - READSB_STATS_RANGE=true
      - UUID=${UUID}
      - MLAT_USER=${FEEDER_NAME}
      - ULTRAFEEDER_CONFIG=
          adsb,feed.adsb.fi,30004,beast_reduce_plus_out;
          adsb,feed.adsb.one,64004,beast_reduce_plus_out;
          adsb,feed.planespotters.net,30004,beast_reduce_plus_out;
          adsb,feed.theairtraffic.com,30004,beast_reduce_plus_out;
          adsb,data.avdelphi.com,24999,beast_reduce_plus_out;
          adsb,feed.adsbexchange.com,30004,beast_reduce_plus_out;
          adsb,feed.airplanes.live,30004,beast_reduce_plus_out;
          adsb,in.adsb.lol,30004,beast_reduce_plus_out;
          adsb,skyfeed.hpradar.com,30004,beast_reduce_plus_out;
          adsb,dati.flyitalyadsb.com,4905,beast_reduce_plus_out;
          mlat,feed.adsb.fi,31090,39000;
          mlat,feed.adsb.one,64006,39002;
          mlat,mlat.planespotters.net,31090,39003;
          mlat,feed.theairtraffic.com,31090,39004;
          mlat,feed.adsbexchange.com,31090,39005;
          mlat,feed.airplanes.live,31090,39006;
          mlat,in.adsb.lol,31090,39007;
          mlat,skyfeed.hpradar.com,31090,39008;
          mlat,dati.flyitalyadsb.com,30100,39009;
          mlathub,piaware,30105,beast_in;
          mlathub,fr24,30105,beast_in
      - TAR1090_DEFAULTCENTERLAT=${FEEDER_LAT}
      - TAR1090_DEFAULTCENTERLON=${FEEDER_LONG}
      - TAR1090_MESSAGERATEINTITLE=true
      - TAR1090_PAGETITLE=${FEEDER_NAME}
      - TAR1090_PLANECOUNTINTITLE=true
      - TAR1090_ENABLE_AC_DB=true
      - TAR1090_FLIGHTAWARELINKS=true
      - GRAPHS1090_DARKMODE=true
      - PROMETHEUS_ENABLE=true
    volumes:
      - ./ultrafeeder/globe_history:/var/globe_history
      - ./ultrafeeder/graphs1090:/var/lib/collectd
      - /proc/diskstats:/proc/diskstats:ro
      - /dev:/dev:ro
    tmpfs:
      - /run:exec,size=256M
      - /tmp:size=128M
      - /var/log:size=32M
    healthcheck:
      test: ["CMD-SHELL", "timeout 5 nc -z localhost 30003 && test -f /run/readsb/aircraft.json"]
      interval: 10s
      timeout: 10s
      retries: 5
      start_period: 120s
YAML

    # Remove mlathub lines for disabled services
    if [[ "${DO_PIAWARE}" != "y" ]]; then
        sed -i '/mlathub,piaware/d' "${COMPOSE_FILE}"
    fi
    if [[ -z "${FR24_KEY}" ]]; then
        sed -i '/mlathub,fr24/d' "${COMPOSE_FILE}"
    fi

    if [[ -n "${ULTRAFEEDER_PORT}" ]]; then
        sed -i '/^  ultrafeeder:/a\    ports:\n      - '"${ULTRAFEEDER_PORT}"':80' "${COMPOSE_FILE}"
    fi

    if [[ -n "${FR24_KEY}" ]]; then
        cat >> "${COMPOSE_FILE}" <<'YAML'

  fr24:
    image: ghcr.io/sdr-enthusiasts/docker-flightradar24:latest
    restart: unless-stopped
    depends_on:
      ultrafeeder:
        condition: service_healthy
    environment:
      - BEASTHOST=ultrafeeder
      - FR24KEY=${FR24_SHARING_KEY}
    tmpfs:
      - /var/log
YAML
        if [[ -n "${FR24_PORT}" ]]; then
            sed -i '/^  fr24:/a\    ports:\n      - '"${FR24_PORT}"':8754' "${COMPOSE_FILE}"
        fi
    fi

    if [[ "${DO_PIAWARE}" == "y" ]]; then
        cat >> "${COMPOSE_FILE}" <<'YAML'

  piaware:
    image: ghcr.io/sdr-enthusiasts/docker-piaware:latest
    restart: unless-stopped
    depends_on:
      ultrafeeder:
        condition: service_healthy
    environment:
      - BEASTHOST=ultrafeeder
      - TZ=${FEEDER_TZ}
      - FEEDER_ID=${PIAWARE_FEEDER_ID}
      - LAT=${FEEDER_LAT}
      - LONG=${FEEDER_LONG}
    tmpfs:
      - /run:exec,size=64M
      - /var/log
YAML
        if [[ -n "${PIAWARE_PORT}" ]]; then
            sed -i '/^  piaware:/a\    ports:\n      - '"${PIAWARE_PORT}"':8080' "${COMPOSE_FILE}"
        fi
    fi

    cat >> "${COMPOSE_FILE}" <<'YAML'

  prometheus:
    image: prom/prometheus:latest
    restart: unless-stopped
    volumes:
      - ./prometheus/config:/etc/prometheus:ro
      - ./prometheus/data:/prometheus
    tmpfs:
      - /tmp

  grafana:
    image: grafana/grafana-oss:latest
    restart: unless-stopped
    depends_on:
      - prometheus
    environment:
      - GF_INSTALL_PLUGINS=marcusolsson-json-datasource
      - GF_AUTH_ANONYMOUS_ENABLED=true
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=admin
      - GF_AUTH_DISABLE_SIGNOUT_MENU=false
      - GF_SECURITY_ALLOW_EMBEDDING=true
    volumes:
      - ./grafana/appdata:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
      - ./grafana/dashboards:/var/lib/grafana/dashboards:ro
YAML

    if [[ -n "${GRAFANA_PORT}" ]]; then
        sed -i '/^  grafana:/a\    ports:\n      - '"${GRAFANA_PORT}"':3000' "${COMPOSE_FILE}"
    fi

    if [[ "${DO_PLANESNITCH}" == "y" ]]; then
        cat >> "${COMPOSE_FILE}" <<'YAML'

  planesnitch:
    image: psyb0t/planesnitch:latest
    restart: unless-stopped
    depends_on:
      ultrafeeder:
        condition: service_healthy
    volumes:
      - ./planesnitch/config.yaml:/app/config.yaml:ro
      - ./planesnitch/csv:/csv:ro
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
YAML
    fi

    log "Docker compose file written."
}

create_dirs() {
    mkdir -p ultrafeeder/globe_history
    mkdir -p ultrafeeder/graphs1090
    mkdir -p prometheus/config
    mkdir -p prometheus/data
    sudo chown 65534:65534 prometheus/data
    mkdir -p grafana/appdata
    sudo chown 472:0 grafana/appdata
    mkdir -p grafana/provisioning/datasources
    mkdir -p grafana/provisioning/dashboards
    mkdir -p grafana/dashboards
    write_prometheus_config
    write_grafana_provisioning
}

write_prometheus_config() {
    log "Writing Prometheus config..."
    cat > prometheus/config/prometheus.yml <<'EOF'
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'ultrafeeder'
    static_configs:
      - targets: ['ultrafeeder:9273', 'ultrafeeder:9274']
EOF
}

write_grafana_provisioning() {
    log "Writing Grafana datasource provisioning..."
    cat > grafana/provisioning/datasources/prometheus.yml <<'EOF'
apiVersion: 1
datasources:
  - name: ultrafeeder
    uid: ultrafeeder-prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090/
    isDefault: true
EOF

    log "Writing Grafana dashboard provisioning..."
    cat > grafana/provisioning/dashboards/dashboards.yml <<'EOF'
apiVersion: 1
providers:
  - name: default
    orgId: 1
    folder: ''
    type: file
    disableDeletion: false
    updateIntervalSeconds: 10
    options:
      path: /var/lib/grafana/dashboards
      foldersFromFilesStructure: false
EOF

    log "Downloading ultrafeeder Grafana dashboard..."
    curl -sf "https://grafana.com/api/dashboards/18398/revisions/latest/download" \
        -o grafana/dashboards/ultrafeeder.json 2>/dev/null || warn "Failed to download dashboard, import manually: ID 18398"

    if [[ -f grafana/dashboards/ultrafeeder.json ]]; then
        log "Patching dashboard..."
        sed -i 's/\${DS_PROMETHEUS}/ultrafeeder-prometheus/g' grafana/dashboards/ultrafeeder.json
        # Replace feeder_url placeholder with actual server address
        local ip
        ip=$(hostname -I | awk '{print $1}')
        sed -i "s|http://feeder_url|http://${ip}:${ULTRAFEEDER_PORT}|g" grafana/dashboards/ultrafeeder.json
        # Remove library panels (UAT/dump978 stuff that needs library elements we don't have)
        jq 'del(.__inputs, .__requires, .__elements) | .id = null | .panels = [.panels[] | select(.libraryPanel == null) | if .panels then .panels = [.panels[] | select(.libraryPanel == null)] else . end]' \
            grafana/dashboards/ultrafeeder.json > grafana/dashboards/ultrafeeder.json.tmp \
            && mv grafana/dashboards/ultrafeeder.json.tmp grafana/dashboards/ultrafeeder.json
        # Add missing Mode-S metric and fix refId sequence
        python3 -c '
import json
with open("grafana/dashboards/ultrafeeder.json") as f:
    d = json.load(f)
for p in d["panels"]:
    if p.get("title") == "Aircraft Counts":
        if not any("mode_s" in t.get("expr","") for t in p.get("targets",[])):
            t = dict(p["targets"][-1])
            t["expr"] = "readsb_aircraft_mode_s{job=\"ultrafeeder\"}"
            t["legendFormat"] = "Mode-S"
            p["targets"].append(t)
        for i, t in enumerate(p["targets"]):
            t["refId"] = chr(65 + i)
        break
with open("grafana/dashboards/ultrafeeder.json","w") as f:
    json.dump(d, f, indent=2)
'
    fi
}

launch() {
    echo ""
    log "=== Launching ADS-B Publisher ==="
    docker compose down --remove-orphans 2>/dev/null || true
    docker compose pull
    docker compose up -d --force-recreate

    LOCAL_IP=$(hostname -I | awk '{print $1}')
    echo ""
    log "=== DONE ==="
    echo ""
    [[ -n "${ULTRAFEEDER_PORT}" ]] && log "tar1090 map:        http://${LOCAL_IP}:${ULTRAFEEDER_PORT}"
    [[ -n "${ULTRAFEEDER_PORT}" ]] && log "graphs1090 stats:   http://${LOCAL_IP}:${ULTRAFEEDER_PORT}/graphs1090"
    [[ -n "${FR24_KEY}" && -n "${FR24_PORT}" ]] && log "FR24 status:        http://${LOCAL_IP}:${FR24_PORT}"
    [[ "${DO_PIAWARE}" == "y" && -n "${PIAWARE_PORT}" ]] && log "Piaware:            http://${LOCAL_IP}:${PIAWARE_PORT}"
    [[ -n "${GRAFANA_PORT}" ]] && log "Grafana:            http://${LOCAL_IP}:${GRAFANA_PORT}"
    [[ "${DO_PLANESNITCH}" == "y" ]] && log "planesnitch:        running (no alerts until you edit planesnitch/config.yaml)"
    echo ""
    log "Publishing to: adsb.fi, adsb.one, adsb.lol, planespotters.net, theairtraffic.com, avdelphi.com, adsbexchange.com, airplanes.live, hpradar.com, flyitalyadsb.com"
    [[ -n "${FR24_KEY}" ]] && log "Publishing to: FlightRadar24"
    [[ "${DO_PIAWARE}" == "y" ]] && log "Publishing to: FlightAware"
    echo ""
    if [[ -z "${PIAWARE_ID}" && "${DO_PIAWARE}" == "y" ]]; then
        warn "Claim your piaware feeder at: https://flightaware.com/adsb/piaware/claim"
        warn "Find your feeder ID with: docker compose logs piaware | grep 'feeder ID'"
    fi
    log "Station UUID: ${UUID}"
    log "Manage:       docker compose [up -d|down|logs -f]"
}

main() {
    echo ""
    echo "  ╔══════════════════════════════════════╗"
    echo "  ║   ADS-B Publisher Setup              ║"
    echo "  ║   Publish ALL the things.            ║"
    echo "  ╚══════════════════════════════════════╝"
    echo ""
    load_cache
    check_sudo
    check_deps
    blacklist_kernel_drivers
    pull_ultrafeeder_image
    collect_info
    detect_sdr
    signup_fr24
    signup_piaware
    setup_planesnitch
    write_env
    write_compose
    create_dirs
    [[ "${DO_PLANESNITCH}" == "y" ]] && write_planesnitch_config
    launch
}

main "$@"
