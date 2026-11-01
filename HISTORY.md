# History

## 2026-10-31 - Initial Static HTML Apache Traffic Report Generator

- Built the Perl static HTML and JavaScript report generator (`bin/build_reports.pl`, `lib/ApacheLog/Parser.pm`, `lib/ApacheLog/StateStore.pm`, `lib/ApacheLog/ReportBuilder.pm`) with Chart.js visualizations and interactive filtering (`assets/report.js`, `assets/report.css`).
- Added dual-format Apache log parsing (`%v` virtual host auto-detection and filename/config vhost mapping) with incremental `inode` and byte-offset state tracking in `state/traffic_state.json`.
- Generated static multi-vhost comparison (`output/index.html`), single-vhost chart overview (`output/vhosts/<vhost>.html`), and detailed traffic & log explorer (`output/vhosts/<vhost>-details.html`) pages.
- Configured virtual host log sources in `config/traffic.json`, fixed UTF-8 file output encoding in `lib/ApacheLog/ReportBuilder.pm`, and added unit tests in `t/01-parser.t` and `t/02-static-builder.t`.
