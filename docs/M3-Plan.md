<div class="page">

# Milestone 3 — High Availability Hardening & Observability

<div class="meta">

**Project:** Linode High Availability NAT Gateway  \|  **Owner:** Sandip
Gangdhar  \|  **Date:** November 2025

</div>

<div class="lead">

**Objective:** Harden the existing HA NAT Gateway for production-grade
reliability, visibility, and maintainability — achieving sub‑3s
failover, full conntrack state continuity, and comprehensive
metrics/alerts for VRRP, NAT and conntrack performance.

</div>

## Scope Overview

- Sub‑3 second failover with consistent connection retention
- Full conntrack state synchronization and recovery
- Security & system hardening across kernel, ARP, ACLs
- Observability stack: Prometheus, Grafana, Loki/Promtail, alerting

## Phase 1 — Failover Optimization (HA Resiliency)

| Task | Description | Deliverable |
|----|----|----|
| **VRRP Tuning** | Tune `advert_int`, `preempt_delay`, and health-check cadence to reach sub‑3 s failover while avoiding flaps. | Tuned `keepalived.conf` |
| **Health Scripts** | Extend `/usr/local/sbin/ha-check.sh` for multipath checks (default GW ping, external ICMP, HTTP 204 reachability). | Updated script + syslog entries |
| **GARP Broadcasts** | Issue multiple Gratuitous ARPs on master promotion to flush neighbor caches and prevent black-holing. | GARP logic in `notify_master` |
| **Failover Tests** | Soft & hard failover drills; capture packet-loss and session retention metrics. | Test report & graphs |

## Phase 2 — conntrackd Enhancements (State Synchronization)

| Task | Description | Deliverable |
|----|----|----|
| **FTFW Mode** | Enable Fault‑Tolerant Firewall (FTFW) mode for live state mirroring including expectations. | Updated `conntrackd.conf` |
| **Sync Channel Hardening** | Isolate sync VLAN; add PSK; validate MTU; consider disabling GSO/TSO offloads if needed. | Secure sync path |
| **State Reconciliation** | Periodic hash comparisons via `conntrackd -c stats diff` to validate parity and drift. | Reconciliation logs |
| **Stress Testing** | Drive \>=10k NAT connections with `iperf3`/tcpreplay; measure sync latency & loss. | Benchmarks & charts |

## Phase 3 — System & Network Hardening

| Category | Action |
|----|----|
| **Kernel Tuning** | Ensure `rp_filter=2`, increase `nf_conntrack_max`/`_buckets`, disable redirects; persist via `/etc/sysctl.d/`. |
| **ARP Flux Mitigation** | Apply `arp_ignore=1`, `arp_announce=2` to stabilize VIP mobility. |
| **Firewall Policy** | Default drop with rate‑limited logs; SSH/metrics allow‑lists; explicit VRRP acceptance on LAN. |
| **Access Control** | Root‑only for keepalived/conntrackd configs; tighten file permissions and service units. |
| **Security Audits** | Run `lynis` or `oscap` baselines; track findings and remediation. |

## Phase 4 — Observability Stack Integration

### 1) Prometheus & Node Exporters

- Deploy `node_exporter` on each gateway.
- Enable textfile collector for:
  - `/proc/sys/net/netfilter/nf_conntrack_count` & `_max`
  - nftables counters snapshots
  - Keepalived VRRP state (VIP presence, role)

### 2) Grafana Dashboards

- VRRP state timeline (MASTER/BACKUP)
- Conntrack utilization % and new flows/sec
- NAT throughput (WAN rx/tx bytes per second)
- Drop rate and nftables log counters

### 3) Alerting Rules (Alertmanager)

| Alert                  | Condition                             | Severity |
|------------------------|---------------------------------------|----------|
| VRRP State Deviation   | Preferred node not MASTER \> 60s      | critical |
| Conntrack Usage \> 80% | `count/max > 0.8` for 5m              | warning  |
| Drop Rate High         | nftables drop counters over threshold | warning  |
| Healthcheck Failures   | ≥ 3 failures within 2m                | critical |

### 4) Loki + Promtail

- Ship `/var/log/syslog` (keepalived, conntrackd), kernel, and nftables
  logs with labels `{job="nat-ha"}`.
- Correlate VRRP events with NAT counters via Grafana Explore.

## Phase 5 — Chaos & Acceptance Testing

| Scenario                        | Success Criteria                   |
|---------------------------------|------------------------------------|
| Soft failover (stop keepalived) | VIP shift \< 3 s; ≤ 3 ICMP drops   |
| Hard failover (unplug WAN)      | Backup assumes VIP autonomously    |
| Stateful TCP flow               | Ongoing SSH/iperf sessions survive |
| UDP stream                      | Packet loss \< 2% during switch    |
| Reboot sequence                 | VIP + conntrack roles auto‑recover |

## Deliverables

| Output | Description |
|----|----|
| `nftables.conf` | Hardened ruleset with counters and rate‑limited logging |
| `keepalived.conf` | Optimized timers and notify hooks (GARP + role scripts) |
| `conntrackd.conf` | FTFW mode, PSK, sync tuning, stats hooks |
| `ha-check.sh` | Multipath health with HTTP 204 test |
| `prometheus.yml` | Targets, textfile collector paths, alert rules |
| `grafana-dashboard.json` | VRRP & NAT observability panels |
| `runbook-failover.md` | Ops guide for maintenance & chaos tests |

## Expected Outcome

<div class="card ok">

By the end of Milestone 3, failover will be **sub‑3 seconds** with
stateful continuity, observability will provide **real‑time HA
visibility**, and the system will be **hardened and production‑ready**.

</div>

<div class="footer">

Prepared by: **Sandip Gangdhar** — Senior Cloud Architect, Akamai
Connected Cloud (Linode)

</div>

</div>
