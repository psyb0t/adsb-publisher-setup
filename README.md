# adsb-publisher-setup

One-script setup for receiving ADS-B aircraft data with an RTL-SDR dongle and publishing it to multiple flight tracking aggregators simultaneously.

Deploys a Docker Compose stack with automatic configuration, SDR detection, and optional Grafana dashboards.

## What it publishes to

Out of the box:

- [adsb.fi](https://adsb.fi)
- [adsb.one](https://adsb.one)
- [adsb.lol](https://adsb.lol)
- [Planespotters.net](https://www.planespotters.net)
- [The Air Traffic](https://theairtraffic.com)
- [AV Delphi](https://www.avdelphi.com)
- [ADSBexchange](https://adsbexchange.com)
- [airplanes.live](https://airplanes.live)
- [HPRadar / SkyFeed](https://skyfeed.hpradar.com)
- [Fly Italy ADS-B](https://flyitalyadsb.com)

Optional (interactive signup during setup):

- [FlightRadar24](https://www.flightradar24.com)
- [FlightAware](https://flightaware.com)

## Requirements

- Linux host (tested on Ubuntu/Debian)
- RTL-SDR dongle (e.g. RTL-SDR Blog V3/V4, FlightAware Pro Stick)
- 1090 MHz ADS-B antenna
- Docker and Docker Compose
- `curl`, `jq`
- sudo access

## Quick start

```bash
curl -sL https://raw.githubusercontent.com/psyb0t/adsb-publisher-setup/main/setup.sh | bash
```

Or clone and run:

```bash
git clone https://github.com/psyb0t/adsb-publisher-setup.git
cd adsb-publisher-setup
bash setup.sh
```

The script walks you through everything interactively:

1. Detects your location from IP (lat/lon/elevation/timezone)
2. Picks up RTL-SDR devices automatically
3. Asks for port assignments (or `-` to skip exposing)
4. Optionally signs you up for FlightRadar24 and FlightAware
5. Optionally sets up [planesnitch](https://github.com/psyb0t/docker-planesnitch) for aircraft alerts (Telegram/webhooks)
6. Generates `docker-compose.yml`, `.env`, Prometheus config, and Grafana provisioning
7. Pulls images and launches the stack

Previous answers are cached in `.adsb_publisher_setup_save` — re-running the script reuses them as defaults.

## Services

| Service     | Description                                            | Default Port |
| ----------- | ------------------------------------------------------ | ------------ |
| [ultrafeeder](https://github.com/sdr-enthusiasts/docker-adsb-ultrafeeder) | SDR receiver, decoder, feeder, tar1090 map, graphs1090 | 10980 |
| [fr24](https://github.com/sdr-enthusiasts/docker-flightradar24) | FlightRadar24 feeder (optional) | 10981 |
| [piaware](https://github.com/sdr-enthusiasts/docker-piaware) | FlightAware feeder (optional) | 10982 |
| [planesnitch](https://github.com/psyb0t/docker-planesnitch) | Aircraft alerts to Telegram/webhooks (optional) | — |
| [prometheus](https://github.com/prometheus/prometheus) | Metrics collection from ultrafeeder | — |
| [grafana](https://github.com/grafana/grafana) | Dashboards for aircraft stats, signal, range | 10984 |

## Web UIs

After setup, the script prints all URLs. Typically:

- **tar1090 map** — `http://<ip>:10980` — live aircraft map
- **graphs1090** — `http://<ip>:10980/graphs1090` — built-in signal/range/aircraft graphs
- **FR24 status** — `http://<ip>:10981` — FlightRadar24 feeder status (if enabled)
- **Piaware** — `http://<ip>:10982` — FlightAware feeder status (if enabled)
- **Grafana** — `http://<ip>:10984` — Prometheus-based dashboards (anonymous viewer access, `admin`/`admin` for editing)

## Project structure after setup

```
.
├── docker-compose.yml                # Generated compose file
├── .env                              # Generated environment variables
├── .adsb_publisher_setup_save        # Cached answers for re-runs
├── ultrafeeder/
│   ├── globe_history/                # Aircraft track history
│   └── graphs1090/                   # graphs1090 collected stats
├── planesnitch/                      # (if enabled)
│   ├── config.yaml                   # Your planesnitch config (not overwritten on re-run)
│   ├── config.yaml.example           # Generated example config (always updated)
│   └── csv/                          # plane-alert-db CSV watchlists (github.com/sdr-enthusiasts/plane-alert-db)
├── prometheus/
│   ├── config/prometheus.yml         # Scrape config
│   └── data/                         # Prometheus TSDB
└── grafana/
    ├── appdata/                      # Grafana database
    ├── provisioning/
    │   ├── datasources/              # Auto-configured Prometheus datasource
    │   └── dashboards/               # Dashboard provisioning config
    └── dashboards/                   # Auto-downloaded ultrafeeder dashboard
```

## Re-running setup

Just run `bash setup.sh` again. It picks up your previous answers and lets you change anything. The stack gets recreated with the new config.

## Updating

To pull the latest images and rebuild the stack without being asked a million questions:

```bash
curl -sL https://raw.githubusercontent.com/psyb0t/adsb-publisher-setup/main/setup.sh | bash -s -- --auto
```

Or if you cloned the repo: `bash setup.sh --auto` (also accepts `-y`).

This reuses all your saved answers from `.adsb_publisher_setup_save`, pulls fresh images, and relaunches. No prompts unless new functionality was added to the script that you haven't configured yet — in that case it only asks about the new stuff.

The `-s` tells bash to read the script from stdin (the curl pipe) and `--` separates bash's flags from the script's arguments so `--auto` gets passed to the script instead of being eaten by bash.

## Notes

- The script blacklists kernel DVB drivers that conflict with RTL-SDR usage for ADS-B
- Autogain calibration runs for ~2 hours on first start — aircraft counts may be low initially
- MLAT requires your station to be seen by nearby peers — it may take time to sync
- Grafana anonymous access is Viewer-only; log in with `admin`/`admin` at `/login` for full access

## License

[WTFPL](LICENSE) — Do What The Fuck You Want To.
