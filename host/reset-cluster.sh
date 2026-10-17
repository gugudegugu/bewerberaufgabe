#!/usr/bin/env bash
# Setzt den Cluster komplett zurück: Container, Docker-Volumes und die Daten von es03.
# ACHTUNG: Alle Daten gehen verloren (Snapshots in /srv/snapshots bleiben erhalten).
set -euo pipefail
cd "$(dirname "$0")/.."

read -rp "Cluster wirklich komplett zurücksetzen? (ja/nein) " a
[ "$a" = "ja" ] || { echo "Abgebrochen."; exit 1; }

docker compose down -v
find /srv/es-frozen -mindepth 1 -maxdepth 1 ! -name lost+found -exec rm -rf {} +
echo "Zurückgesetzt. Neu starten mit: sudo docker compose up -d"
