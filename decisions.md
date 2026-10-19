# Architekturentscheide – Elastic Stack Homelab

- [Host](#host)
- [Projekt](#projekt)
- [Cluster](#cluster)
- [Ressourcen](#ressourcen)
- [Snapshots](#snapshots)
- [Sicherheit](#sicherheit)
- [Datensammlung](#datensammlung)

## Host

| Was | Entscheid | Warum |
|---|---|---|
| SSH | Nur Login per SSH-Key, Passwort-Login deaktiviert | Simples Hardening |
| Betriebssystem | Ubuntu 26.04 LTS | Aktuelle LTS-Version mit langem Support, offiziell von Docker unterstützt und mir aus dem Betrieb vertraut. |
| Disk-Layout | Eigene LVs für `/`, `/boot`, `/var`, `/var/log`, `/tmp`, `/home`, `/var/lib/docker` (150 GB), `/srv/snapshots` (80 GB) und `/srv/es-frozen` (30 GB), siehe Bild unten | Getrennte Volumes verhindern, dass ein volles Docker- oder Log-Verzeichnis das ganze System lahmlegt. Der freie Platz ist Reserve, um Volumes später mit `lvextend` zu vergrössern. |
| Docker / Compose | Docker 29.9.1, Compose v5.6.0 (aktuell am 15.10.2026) | Aktuelle stabile Version mit allen Sicherheitsupdates. Die Version ist festgehalten, damit das Setup genau so nachgebaut werden kann. |
| Docker-Zugriff | Nur über sudo, User nicht in der `docker`-Gruppe | Docker-Zugriff ausschliesslich über sudo, kein User in der `docker`-Gruppe, da diese root-äquivalent ist. Vorteil: explizite Rechteerhöhung und Audit-Trail. Rootless Docker wurde geprüft und für das Homelab verworfen (AppArmor/UID-Mapping-Aufwand, eingeschränkter Host-Zugriff des Agents). In Produktion: Rootless bzw. Deployment über Automation mit dediziertem Service-Account. |
| Zurücksetzen | Skript `host/reset-cluster.sh` | Löscht Container, Volumes und den Frozen-Cache nach Rückfrage. Die Snapshots bleiben erhalten, damit nach einem Neuaufbau ein Restore möglich ist. |

## Projekt

| Was | Entscheid | Warum |
|---|---|---|
| Elastic-Version | `STACK_VERSION=9.5.5` (fest) | «latest» kann sich jederzeit ändern. Mit einer festen Version startet das Setup immer gleich. Elastic empfiehlt das ausdrücklich. |
| Ausgangsbasis | Offizielle Compose-Vorlage von Elastic, Original unverändert unter `reference/` | Ich baue auf einer geprüften Vorlage auf, statt alles neu zu erfinden. Mit dem Original daneben ist jede meiner Änderungen nachvollziehbar. |

## Cluster

| Was | Entscheid | Warum |
|---|---|---|
| Node-Rollen | es01 und es02: hot (master, data_hot, data_content, ingest). es03: frozen (master, data_frozen). | Hot-Nodes nehmen neue Daten auf, der Frozen-Node hält alte Daten günstig aus Snapshots. Alle drei sind master-fähig, damit der Cluster einen Ausfall übersteht: 2 von 3 reichen für eine Mehrheit. |
| Kein Machine Learning | Rolle `ml` ist keinem Node zugewiesen. Die ML-Speichereinstellung der Vorlage entfernt, da ohne ML-Node wirkungslos. | Machine Learning braucht viel RAM und ist für die Aufgabe nicht nötig. Ohne explizite Rollen hätte jeder Node automatisch auch die ML-Rolle. |
| Cluster-Name | `homelab` | Sprechender Name statt Default. Muss vor dem ersten Start gesetzt werden, weil er danach nicht mehr änderbar ist. |
| `initial_master_nodes` | Nach dem ersten Start entfernt | Wird nur zum allerersten Bilden des Clusters gebraucht. Bleibt es stehen, könnte ein Node mit leerem Datenverzeichnis versehentlich einen zweiten Cluster gründen. Elastic empfiehlt das Entfernen. Für einen Neuaufbau muss es vorübergehend wieder gesetzt werden (siehe Startanleitung im README). |

## Ressourcen

| Was | Entscheid | Warum |
|---|---|---|
| Speicher-Limits | Feste `mem_limit`: es01 3 GB, es02 3 GB, es03 2 GB, Kibana 1.5 GB, Fleet Server 1 GB | Ohne Swap gibt es keinen Puffer. Feste Limits stellen sicher, dass die Container zusammen nicht mehr RAM wollen, als vorhanden ist. Sonst beendet der Kernel einen Prozess (OOM-Kill). |
| Heap | `config/jvm/heap-hot.options`: `-Xms1536m` / `-Xmx1536m`<br>`config/jvm/heap-frozen.options`: `-Xms1g` / `-Xmx1g` | Elasticsearch braucht neben dem Heap freien Speicher für den Datei-Cache, darum nur die Hälfte des Container-Limits. Eine Datei statt Umgebungsvariable, weil Elastic das für Produktion empfiehlt. |
| Threads (nproc) | Keine Änderung, Container erhalten «unlimited» vom Docker-Daemon | Elasticsearch braucht mindestens 4096 Threads. Der Docker-Default reicht bereits, also nichts anpassen. |
| TCP-Timeout | `net.ipv4.tcp_retries2=5` pro Container (`sysctls`) | Fällt ein Node aus, merken es die anderen nach etwa 13 Sekunden statt nach etwa 15 Minuten. Muss pro Container gesetzt werden, weil jeder Container eigene Netzwerk-Einstellungen hat. Wird von Elastic empfohlen, solange ein stabiles und schnelles Netzwerk gewährleistet werden kann. |

## Snapshots

| Was | Entscheid | Warum |
|---|---|---|
| Snapshot-Repository | Gemeinsames Verzeichnis `/srv/snapshots/es-repo`, in alle drei Nodes gemountet | Alle Nodes müssen auf dasselbe Repository zugreifen. Auf einem einzigen Host ist ein gemeinsames Verzeichnis das Einfachste und von Elastic offiziell unterstützt. MinIO verworfen: keine Docker-Images mehr, Community-Version nur noch im Wartungsmodus. |
| Rechte Repository | 770, Gruppe 0 | Snapshots sind eine vollständige Kopie aller Daten, inklusive der Passwort-Hashes im Security-Feature-State. Nur Elasticsearch (Gruppe 0) und root dürfen sie lesen. |
| Shared Cache Frozen-Node | es03 auf eigenem LV (30 GB) mit Default | Eigenes LV für es03, damit der Standard-Cache nicht die Hot-Nodes in Richtung Disk-Watermarks drückt. |
| SLM-Policy | `daily-snapshots`: täglich 01:30 UTC, alle Indizes, Global State und Feature States. Retention 30 Tage, min. 5, max. 50 | Werte aus dem Beispiel der offiziellen Doku. Mit Global State und Feature States ist auch ein vollständiger Neuaufbau möglich. |
| Restore | Nur Indizes, `include_global_state: false` | Ein Restore soll Daten zurückholen, ohne Benutzer, Rollen und Cluster-Settings zu überschreiben. |

## Sicherheit

| Was | Entscheid | Warum |
|---|---|---|
| Ports | Elasticsearch (9200), Kibana (5601) und Fleet Server (8220) nur an 127.0.0.1, Zugriff per SSH-Tunnel | Docker öffnet freigegebene Ports an der Firewall vorbei. Mit 127.0.0.1 sind die Dienste nur auf dem Server selbst erreichbar, von aussen nur über den verschlüsselten SSH-Tunnel. |
| TLS | Eigene CA, Zertifikate für alle Nodes, Kibana und Fleet Server | Die gesamte Kommunikation zwischen den Diensten ist verschlüsselt. Das Fleet-Server-Zertifikat ist gleich mit erzeugt, damit später nicht alle Zertifikate neu gemacht werden müssen. Der CA-Key liegt im `certs`-Volume, was im Homelab akzeptiert ist (siehe Produktion im README). |
| CA auf dem Host | Nur `ca.crt` nach `/etc/ssl/elastic-homelab/ca.crt` (644) | Der native Agent braucht die CA, um Fleet Server und Elasticsearch zu vertrauen. Kopiert wird nur das öffentliche Zertifikat, nicht der Key. Bewusst nicht in den System-Truststore, damit nur der Agent dieser CA vertraut. |
| Benutzer | `elastic` nur für Ersteinrichtung und Notfälle, tägliche Arbeit mit `gugu-adm` | Der Superuser darf alles, auch Benutzer und Rechte ändern. Für die tägliche Arbeit nimmt man einen persönlichen User mit nur den nötigen Rechten. SLM- und ILM-Policies laufen mit den Rechten des Erstellers, darum ein Benutzer und kein ablaufender API-Key. |
| Telemetrie | Aus, im UI nicht wieder einschaltbar | Keine Nutzungsdaten an Dritte. In der Konfiguration statt per Klick, damit es reproduzierbar ist. |

## Datensammlung

| Was | Entscheid | Warum |
|---|---|---|
| Demo-Daten für ILM | Data Stream `homelab-demo` mit Index-Template und einem Generator (ein Dokument alle 5 s) | ILM braucht für den Rollover einen Data Stream. Agent-Daten gab es zu diesem Zeitpunkt noch nicht. |
| Data Stream Lifecycle | Vom Kibana-Wizard eingefügter `lifecycle`-Block im Template belassen | ILM hat Vorrang (`prefer_ilm`), belegt mit `next_generation_managed_by: Index Lifecycle Management`. |
| ILM-Intervall | `indices.lifecycle.poll_interval: 1m` (persistent) für die Demo, Default 10m | Mit Rollover nach 10 und Frozen nach 15 Minuten wäre ein Prüfintervall von 10 Minuten zu träge. |
| Fleet Server | Als Container im Compose-Setup, Service-Token in `.env` | Gefordert in der Aufgabe. Der Fleet Server braucht keine Host-Daten, darum passt ein Container. |
| Fleet-Adressen | `fleet-internal` / `es-internal` für das Docker-Netz, `fleet-host` / `es-host` für den Host | Im Docker-Netz heissen die Dienste `es01` und `fleet-server`, der Host erreicht sie nur über `localhost`. Eine einzelne Adresse funktioniert nicht von beiden Seiten. |
| Elastic Agent | Nativ auf dem Host (systemd), nicht im Container | Die System-Integration soll Host-Logs und -Metriken liefern. Ein Container müsste dafür Host-Mounts, Host-Netzwerk und Host-PID-Namespace nutzen, was die Isolation aufhebt. |
| Agent-Rechte | Standardmodus (root) statt unprivileged mode | Die System-Integration liest geschützte Logs (`auth.log`) und systemweite Prozessdaten. Fleet-Rechte in Kibana sind deshalb eng zu vergeben. |
| Zweite Policy | `homelab-docker`: System + Docker-Metriken, Docker-Container-Logs aus | Der Host betreibt Docker. Container-Logs ausgeschaltet, um die Datenmenge klein zu halten. Der Zugriff auf `docker.sock` ist root-gleichwertig, der Agent läuft ohnehin als root. |
| Policy-Änderung (4.3) | Periode `docker.cpu` von 10 s auf 20 s | Kleine, gut sichtbare Änderung mit realem Nutzen (weniger Daten). |
