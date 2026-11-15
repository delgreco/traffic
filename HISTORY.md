# History

## 2026-11-15 - Move Fail2ban Panel Below Visual Charts on Main Page

- Updated `lib/ApacheLog/ReportBuilder.pm` so the Fail2ban Apache Protection Status panel renders below the main comparison charts (`chart-compare-timeline`, `chart-compare-share`, `chart-compare-status`) on `output/index.html`.

## 2026-11-15 - Display Fail2ban Apache Jail Status on Main Overview Page

- Added `_run_fail2ban_cmd`, `_parse_fail2ban_jail_list`, `_parse_fail2ban_jail_status`, and `_collect_fail2ban_apache_status` in `lib/ApacheLog/ReportBuilder.pm` to capture active Apache fail2ban jail failure/ban counts and banned IP lists during report generation.
- Added a prominent **Fail2ban Apache Protection Status** panel directly beneath the KPI summary cards on `output/index.html` (`ReportBuilder.pm`, `assets/report.js`, `assets/report.css`).
- Added unit tests in `t/02-static-builder.t` covering fail2ban jail list/status parsing and `index.html` payload rendering.

## 2026-11-14 - Classify and Filter Page/API vs. Image, CSS/JS, and File Requests

- Added `classify_path_type` in `lib/ApacheLog/Parser.pm` to tag every parsed request as `page`, `image`, `asset` (CSS/JS/fonts/maps), or `file` (PDF/media/data/text).
- Extended `lib/ApacheLog/StateStore.pm` to track `path_type` on endpoints and `recent_logs` entries plus per-vhost `path_types` request/byte rollups while continuing to record all requests.
- Updated `lib/ApacheLog/ReportBuilder.pm`, `assets/report.js`, and `assets/report.css` to retain up to 100 endpoints per resource type, add a **Content Types (Pages vs. Files)** doughnut chart on vhost chart pages, default **Top Requested URLs / Endpoints** to **Pages & API** with chips for **Images**, **CSS / JS / Fonts**, **Other Files**, and **All**, and add a **Resource Type** filter in **Recent Request Log Explorer**.
- Expanded `t/01-parser.t` and `t/02-static-builder.t` (`90/90` tests passing) and completed a clean `--reset` rebuild of `output/`.

## 2026-11-13 - Move Top External Referrer Domains Panel First After KPI Cards

- Updated `lib/ApacheLog/ReportBuilder.pm` so the Top External Referrer Domains panel appears immediately after the KPI summary cards on each virtual host's Charts Overview page.

## 2026-11-13 - Maximize Apache Referral Capture, Deduplicate Common Logs, and Add External/Campaign UI

- Removed duplicate `TransferLog` from `/etc/apache2/sites-available/behave.conf` and added/enabled `/etc/apache2/conf-available/combined-origin.conf` to capture trailing `%{Origin}i` headers alongside `Referer` and `User-Agent`.
- Added `skip_common_format` option in `config/traffic.json` and `lib/ApacheLog/StateStore.pm` to skip duplicate `common`-format lines in `access.log*` during ingestion.
- Extended `lib/ApacheLog/Parser.pm` to parse trailing `%{Origin}i` headers, flag `has_referer_ua`, classify referrers into external vs. internal domains/URLs (`classify_referer`), and extract `utm_*` and click-ID campaign parameters (`extract_campaign_params`).
- Updated `lib/ApacheLog/StateStore.pm`, `lib/ApacheLog/ReportBuilder.pm`, `assets/report.js`, and `assets/report.css` to track `ext_ref_domains`, `ext_ref_urls`, `int_ref_urls`, and `campaigns` with human 2xx/3xx vs. bot/4xx/5xx separation, add the Top External Referrer Domains chart on vhost chart pages, and add External Domains / External URLs / Campaigns / Internal mode tabs + noise toggle on vhost details pages.
- Expanded `t/01-parser.t` and `t/02-static-builder.t` (73 tests passing) and performed a clean `--reset` rebuild of all static HTML reports.

## 2026-11-01 - Preserve View Mode on Virtual Host Selection

- Updated `lib/ApacheLog/ReportBuilder.pm` so the Virtual Host `<select>` navigation options preserve the active View Mode (Charts Overview vs. Detailed Traffic & Logs) when switching between virtual hosts.
- Updated `assets/report.js` client-side navigation handler to maintain the active view mode across virtual host changes.
- Added automated test assertions in `t/02-static-builder.t` verifying view mode retention.

## 2026-10-31 - Initial Static HTML Apache Traffic Report Generator

- Built the Perl static HTML and JavaScript report generator (`bin/build_reports.pl`, `lib/ApacheLog/Parser.pm`, `lib/ApacheLog/StateStore.pm`, `lib/ApacheLog/ReportBuilder.pm`) with Chart.js visualizations and interactive filtering (`assets/report.js`, `assets/report.css`).
- Added dual-format Apache log parsing (`%v` virtual host auto-detection and filename/config vhost mapping) with incremental `inode` and byte-offset state tracking in `state/traffic_state.json`.
- Generated static multi-vhost comparison (`output/index.html`), single-vhost chart overview (`output/vhosts/<vhost>.html`), and detailed traffic & log explorer (`output/vhosts/<vhost>-details.html`) pages.
- Configured virtual host log sources in `config/traffic.json`, fixed UTF-8 file output encoding in `lib/ApacheLog/ReportBuilder.pm`, and added unit tests in `t/01-parser.t` and `t/02-static-builder.t`.
