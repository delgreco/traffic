# History

## 2026-11-22 - Refresh README With Quick Start, vhost_colors Docs, and Demo Screenshots

- Reorganized `README.md` with **Quick Start** at the top, a configuration reference table documenting `vhost_colors`, and clearer feature/page summaries.
- Added two sanitized dark-theme UI screenshots (`docs/screenshots/comparison-overview.jpg` and `docs/screenshots/vhost-charts.jpg`) using synthetic example domains.
- Added an example `vhost_colors` block to `config/traffic.json.example`.

## 2026-11-22 - Make Per-Vhost Color Overrides Configurable via config/traffic.json

- Added `vhost_colors` in `config/traffic.json` (`"villobotanicals.com": "#a855f7"`) and embedded `vhost_colors` into `index.html` in `lib/ApacheLog/ReportBuilder.pm` (`_write_index_page`).
- Updated `getVhostColor` in `assets/report.js` to read `DATA.vhost_colors` instead of hardcoding any domain name, excluding pinned colors from the auto-assigned palette for other vhosts.
- Added a test in `t/02-static-builder.t` verifying configured `vhost_colors` embedding in `index.html`.

## 2026-11-22 - Assign Stable Per-Host Colors on Comparison Page With Purple for villobotanicals.com

- Added `getVhostColor` in `assets/report.js` so each virtual host always keeps a consistent color across time windows in **Virtual Host Traffic Over Time**, **Traffic Share by Virtual Host**, and the comparison table, with `villobotanicals.com` permanently assigned purple (`#a855f7`).

## 2026-11-22 - Filter All Virtual Host Overview Charts by Selected Time Window

- Updated `lib/ApacheLog/StateStore.pm` to record per-hour `methods`, `ua_categories`, `path_types`, `error_codes`, and human 2xx/3xx `ext_ref_domains` breakdowns inside each vhost `hourly` bucket.
- Updated `lib/ApacheLog/ReportBuilder.pm` (`_write_index_page`) to keep `index.html` hourly rollups compact while embedding full hourly breakdowns in vhost chart pages.
- Updated `assets/report.js` (`renderVhostChartsPage`) to aggregate those hourly breakdowns across the active Time Window (`startTs`–`endTs`) with fallback to all-time totals for legacy state files, and added assertions in `t/02-static-builder.t`.

## 2026-11-22 - Add Collapse/Expand Toggle Controls to All Report Panels

- Added `.panel-toggle-btn` and `.panel-card.collapsed` rules in `assets/report.css` so every `.panel-card` across overview, vhost chart, and vhost detail pages collapses cleanly to its header bar without inline CSS.
- Added `setupPanelCollapse` in `assets/report.js` to inject an accessible chevron toggle button (`aria-expanded`, `aria-label`, `title`) into every `.panel-header`, persist collapsed state per page/panel in `localStorage`, and resize Chart.js canvases when expanding a panel.

## 2026-11-22 - Label All Data Points and Expand Top External Referrer Domains Chart to Top 25

- Updated `lib/ApacheLog/ReportBuilder.pm` (`_write_vhost_chart_page`) and `assets/report.js` (`renderVhostChartsPage`) to display up to the top 25 human 2xx/3xx external referrer domains (previously 15) and set `autoSkip: false` on the y-axis ticks so every data point is labeled.
- Added `.chart-xl` (`440px`) and `.chart-xxl` (`640px`) height classes in `assets/report.css` and dynamically matched the container height class to the number of referrer domains so all labels remain legible without overlapping.
- Added unit tests in `t/02-static-builder.t` verifying the top-25 limit, exclusion of zero-human-ok domains, and `chart-xxl` container class.

## 2026-11-15 - Default Traffic Share by Virtual Host Chart to 2xx Requests With All Requests Toggle

- Updated `lib/ApacheLog/ReportBuilder.pm` (`_write_index_page`) and `assets/report.js` (`state.shareMetric`) so the **Traffic Share by Virtual Host** doughnut chart defaults to **Requests (2xx)** (`status_2xx`) and offers **All Requests** (`requests`) and **Bandwidth** (`bytes`) toggles.
- Added assertions in `t/02-static-builder.t` verifying both Traffic Share toggle buttons in `index.html`.

## 2026-11-15 - Split Virtual Host Traffic Over Time Requests Into 2xx Default and 3xx Redirects Filter

- Updated `lib/ApacheLog/ReportBuilder.pm` (`_write_index_page`) and `assets/report.js` (`computeCompareDataset`) so the default **Requests (2xx)** timeline view on `Virtual Host Traffic Over Time` (`chart-compare-timeline`) plots only `status_2xx` requests while adding a dedicated **3xx Redirects** (`redirects`) filter toggle for `status_3xx`.
- Added `flex-wrap: wrap` to `.btn-group` in `assets/report.css` so the timeline toggle chips wrap cleanly on mobile screens, and added assertions in `t/02-static-builder.t`.

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
