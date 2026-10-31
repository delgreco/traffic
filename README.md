# Apache Multi-Vhost Static HTML Traffic Analyzer

A pure Perl static HTML + JavaScript report generator for analyzing Apache access logs across multiple virtual hosts—with **zero database engine** and **zero web application daemon**.

## Architecture Highlights
- **Pure Static HTML Output (`output/`)**:
  - `output/index.html` — **All Virtual Hosts Comparison View**: Interactive multi-vhost timeline chart, traffic share doughnuts, HTTP status breakdown bars, and comparison table.
  - `output/vhosts/<vhost>.html` — **Single Virtual Host Charts View**: High-level KPI cards, stacked status/bandwidth/bot timeline chart, HTTP methods doughnut, client category breakdown, and error code chart.
  - `output/vhosts/<vhost>-details.html` — **Separate Detailed Traffic Page**: Searchable/filterable Top Endpoints table, Client IPs & User-Agent/Referrer analytics, 4xx/5xx Error Inspector, and a client-side paginated Recent Request Log Explorer.
  - All data is embedded directly inside each `.html` file (`window.REPORT_DATA = ...`) and rendered client-side with **Chart.js** and `assets/report.js`.
- **Lightweight Incremental JSON State (`state/traffic_state.json`)**:
  - Tracks each log file's `inode` and `byte_offset` so repeated runs only parse newly appended lines and automatically handle log rotation (including `.gz` rotated logs).
- **Dual-Format Apache Log Parser (`ApacheLog::Parser`)**:
  - Automatically detects `%v` (`vhost_combined`) virtual host fields or derives the virtual host name from the log filename / `--vhost` CLI flag.
- **Apache Configuration**:
  - Ready-to-use Apache `<VirtualHost>` configuration in `config/apache-vhost.conf` to serve `output/` directly with Apache Basic Auth (`htpasswd`).

## Quick Start

### 1. Build Static HTML Reports from Apache Logs
Configure your log paths in `config/traffic.json` or pass log files directly on the CLI:
```bash
# Parse configured log_sources in config/traffic.json and generate output/
perl bin/build_reports.pl

# Parse specific log file(s) (supports %v shared logs, per-vhost logs, and .gz archives)
perl bin/build_reports.pl --file /var/log/apache2/other_vhosts_access.log
perl bin/build_reports.pl --file /var/log/apache2/example.com-access.log --vhost example.com

# Specify a custom static HTML output directory (e.g., an Apache DocumentRoot)
perl bin/build_reports.pl --file /var/log/apache2/*access*.log --output-dir /var/www/html/traffic
```

### 2. Run Automated Tests
```bash
prove -l -v t/
```
