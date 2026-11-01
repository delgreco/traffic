package ApacheLog::ReportBuilder;
use strict;
use warnings;
use File::Basename qw(dirname);
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Spec;
use JSON::PP;
use POSIX qw(strftime);
use Carp qw(croak);

sub new {
    my ($class, %args) = @_;
    my $store      = $args{store} or croak "ApacheLog::ReportBuilder requires a 'store' instance";
    my $config     = $args{config} || $store->{config} || {};
    my $output_dir = $args{output_dir} || $ENV{TRAFFIC_OUTPUT} || $config->{output_dir} || 'output';
    my $assets_src = $args{assets_src} || 'assets';

    return bless {
        store      => $store,
        config     => $config,
        output_dir => $output_dir,
        assets_src => $assets_src,
    }, $class;
}

sub build_all {
    my ($self) = @_;
    my $out = $self->{output_dir};
    make_path("$out/assets", "$out/vhosts");

    $self->_copy_static_assets();

    my $state  = $self->{store}->state();
    my $vhosts_map = $state->{vhosts} || {};

    # Build sorted list of vhosts with summary totals
    my @vhost_list;
    my $global_min_ts;
    my $global_max_ts;

    for my $name (sort keys %$vhosts_map) {
        my $vh = $vhosts_map->{$name};
        my $slug = $vh->{slug} || ApacheLog::StateStore::vhost_slug($name);
        $vh->{slug} = $slug;

        my $total_reqs = 0;
        my $total_bytes = 0;
        for my $h (values %{ $vh->{hourly} || {} }) {
            $total_reqs  += $h->{requests} || 0;
            $total_bytes += $h->{bytes}    || 0;
        }

        if (defined $vh->{first_seen}) {
            $global_min_ts = $vh->{first_seen} if !defined $global_min_ts || $vh->{first_seen} < $global_min_ts;
        }
        if (defined $vh->{last_seen}) {
            $global_max_ts = $vh->{last_seen} if !defined $global_max_ts || $vh->{last_seen} > $global_max_ts;
        }

        push @vhost_list, {
            name           => $name,
            slug           => $slug,
            first_seen     => $vh->{first_seen},
            last_seen      => $vh->{last_seen},
            total_requests => $total_reqs,
            total_bytes    => $total_bytes,
            unique_ips     => scalar(keys %{ $vh->{ips} || {} }),
            chart_href     => "vhosts/$slug.html",
            details_href   => "vhosts/$slug-details.html",
        };
    }

    @vhost_list = sort {
        ($b->{total_requests} <=> $a->{total_requests}) || ($a->{name} cmp $b->{name})
    } @vhost_list;

    my $generated_at = strftime("%Y-%m-%d %H:%M:%S UTC", gmtime());

    # 1. Write output/index.html (All Virtual Hosts Comparison Page)
    $self->_write_index_page(\@vhost_list, $vhosts_map, $global_min_ts, $global_max_ts, $generated_at);

    # 2. Write output/vhosts/<slug>.html and output/vhosts/<slug>-details.html for each vhost
    my @files_written = ("$out/index.html");
    for my $v_meta (@vhost_list) {
        my $vh_data = $vhosts_map->{ $v_meta->{name} };
        my $f_chart   = $self->_write_vhost_chart_page($v_meta, $vh_data, \@vhost_list, $generated_at);
        my $f_details = $self->_write_vhost_details_page($v_meta, $vh_data, \@vhost_list, $generated_at);
        push @files_written, $f_chart, $f_details;
    }

    return {
        output_dir    => $out,
        vhosts_count  => scalar(@vhost_list),
        files_written => \@files_written,
    };
}

sub _copy_static_assets {
    my ($self) = @_;
    my $src = $self->{assets_src};
    my $dst = "$self->{output_dir}/assets";

    for my $file (qw(chart.umd.min.js report.css report.js)) {
        if (-f "$src/$file") {
            copy("$src/$file", "$dst/$file")
                or croak "Failed to copy '$src/$file' to '$dst/$file': $!";
        }
    }
}

sub _encode_embedded_json {
    my ($data) = @_;
    my $coder = JSON::PP->new->utf8->canonical;
    my $json  = $coder->encode($data);
    # Escape </script> inside embedded JSON strings so HTML cannot break
    $json =~ s{</script}{<\\/script}gi;
    return $json;
}

sub _escape_html {
    my ($str) = @_;
    return '' unless defined $str;
    $str =~ s/&/&amp;/g;
    $str =~ s/</&lt;/g;
    $str =~ s/>/&gt;/g;
    $str =~ s/"/&quot;/g;
    return $str;
}

=head2 _render_nav_options

Renders <option> elements for the virtual host navigation dropdown.
Maintains the current view mode (charts vs details) when switching vhosts.

=cut

sub _render_nav_options {
    my ( $vhost_list, $current_slug, $root_prefix, $view_mode ) = @_;
    $view_mode //= 'charts';
    my $all_selected = ( $current_slug eq 'all' ) ? ' selected' : '';
    my @opts = (
        qq{<option value="${root_prefix}index.html"$all_selected>🌐 All Virtual Hosts (Comparison)</option>}
    );
    for my $v ( @$vhost_list ) {
        my $sel  = ( $v->{slug} eq $current_slug ) ? ' selected' : '';
        my $page = ( $view_mode eq 'details' ) ? "$v->{slug}-details.html" : "$v->{slug}.html";
        my $href = "${root_prefix}vhosts/$page";
        my $name = _escape_html( $v->{name} );
        push @opts, qq{<option value="$href"$sel>$name ($v->{total_requests} reqs)</option>};
    }
    return join( "\n          ", @opts );
}

sub _write_index_page {
    my ($self, $vhost_list, $vhosts_map, $min_ts, $max_ts, $generated_at) = @_;

    my @compare_vhosts;
    for my $v (@$vhost_list) {
        my $vh = $vhosts_map->{ $v->{name} };
        push @compare_vhosts, {
            name         => $v->{name},
            slug         => $v->{slug},
            first_seen   => $v->{first_seen},
            last_seen    => $v->{last_seen},
            unique_ips   => $v->{unique_ips},
            chart_href   => "vhosts/$v->{slug}.html",
            details_href => "vhosts/$v->{slug}-details.html",
            hourly       => $vh->{hourly} || {},
        };
    }

    my $payload = {
        page_type    => 'compare',
        generated_at => $generated_at,
        min_ts       => $min_ts,
        max_ts       => $max_ts,
        vhosts       => \@compare_vhosts,
    };

    my $json_str = _encode_embedded_json($payload);
    my $nav_opts = _render_nav_options( $vhost_list, 'all', '', 'charts' );

    my $html = <<"HTML";
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>All Virtual Hosts Comparison — Apache Traffic Analytics</title>
  <link rel="stylesheet" href="assets/report.css">
  <script>window.REPORT_DATA = $json_str;</script>
  <script src="assets/chart.umd.min.js" defer></script>
  <script src="assets/report.js" defer></script>
</head>
<body>
  <header class="top-header">
    <div class="brand-group">
      <a href="index.html" class="brand-icon" aria-label="Home">📊</a>
      <div>
        <h1 class="brand-title">Apache Traffic Analytics</h1>
        <p class="brand-subtitle">Static HTML Report • Generated $generated_at</p>
      </div>
    </div>

    <div class="controls-bar">
      <div class="control-item">
        <label for="vhost-nav-select" class="control-label">Virtual Host</label>
        <select id="vhost-nav-select" class="select-input vhost-dropdown">
          $nav_opts
        </select>
      </div>

      <div class="control-item">
        <span class="control-label">Time Window</span>
        <div class="btn-group" role="group" aria-label="Time range presets">
          <button type="button" class="btn-chip" data-range="24h">24h</button>
          <button type="button" class="btn-chip" data-range="7d">7d</button>
          <button type="button" class="btn-chip" data-range="30d">30d</button>
          <button type="button" class="btn-chip active" data-range="all">All Data</button>
        </div>
      </div>

      <div class="control-item date-inputs">
        <div>
          <label for="start-date" class="control-label">From (UTC)</label>
          <input type="datetime-local" id="start-date" class="date-input">
        </div>
        <div>
          <label for="end-date" class="control-label">To (UTC)</label>
          <input type="datetime-local" id="end-date" class="date-input">
        </div>
      </div>

      <div class="control-item">
        <label for="granularity-select" class="control-label">Bucket</label>
        <select id="granularity-select" class="select-input">
          <option value="auto">Auto</option>
          <option value="hour">Hourly</option>
          <option value="day">Daily</option>
        </select>
      </div>
    </div>
  </header>

  <main class="main-container">
    <div class="section-header">
      <div>
        <h2 class="section-title">All Virtual Hosts — Comparison Overview</h2>
        <p class="section-desc">High-level comparison of traffic, bandwidth share, and HTTP status codes across all virtual hosts.</p>
      </div>
    </div>

    <div class="kpi-grid">
      <div class="kpi-card">
        <span class="kpi-label">Total Requests</span>
        <strong class="kpi-value" id="cmp-kpi-requests">0</strong>
        <span class="kpi-sub" id="cmp-kpi-vhosts">0 active vhosts</span>
      </div>
      <div class="kpi-card">
        <span class="kpi-label">Total Bandwidth</span>
        <strong class="kpi-value" id="cmp-kpi-bytes">0 B</strong>
        <span class="kpi-sub" id="cmp-kpi-avg-bytes">Avg 0 B / req</span>
      </div>
      <div class="kpi-card">
        <span class="kpi-label">Unique Client IPs</span>
        <strong class="kpi-value" id="cmp-kpi-ips">0</strong>
        <span class="kpi-sub">Across all virtual hosts</span>
      </div>
      <div class="kpi-card">
        <span class="kpi-label">4xx / 5xx Error Rate</span>
        <strong class="kpi-value" id="cmp-kpi-err-rate">0.00%</strong>
        <span class="kpi-sub" id="cmp-kpi-5xx-count">0 server (5xx) errors</span>
      </div>
      <div class="kpi-card">
        <span class="kpi-label">Bot Traffic Ratio</span>
        <strong class="kpi-value" id="cmp-kpi-bot-pct">0.0%</strong>
        <span class="kpi-sub">Automated crawlers &amp; spiders</span>
      </div>
    </div>

    <div class="panel-card">
      <div class="panel-header">
        <div>
          <h3 class="panel-title">Virtual Host Traffic Over Time</h3>
          <p class="panel-subtitle">Compare requests, bandwidth, and error volume across virtual hosts</p>
        </div>
        <div class="btn-group" role="group" aria-label="Timeline metric toggle">
          <button type="button" class="btn-chip active" data-cmp-metric="requests">Requests</button>
          <button type="button" class="btn-chip" data-cmp-metric="bytes">Bandwidth</button>
          <button type="button" class="btn-chip" data-cmp-metric="errors">4xx/5xx Errors</button>
        </div>
      </div>
      <div class="chart-container chart-lg">
        <canvas id="chart-compare-timeline"></canvas>
      </div>
    </div>

    <div class="grid-2col">
      <div class="panel-card">
        <div class="panel-header">
          <div>
            <h3 class="panel-title">Traffic Share by Virtual Host</h3>
            <p class="panel-subtitle">Proportional split across active virtual hosts</p>
          </div>
          <div class="btn-group" role="group" aria-label="Share metric toggle">
            <button type="button" class="btn-chip active" data-share-metric="requests">Requests</button>
            <button type="button" class="btn-chip" data-share-metric="bytes">Bandwidth</button>
          </div>
        </div>
        <div class="chart-container chart-md">
          <canvas id="chart-compare-share"></canvas>
        </div>
      </div>

      <div class="panel-card">
        <div class="panel-header">
          <div>
            <h3 class="panel-title">HTTP Status Breakdown per Virtual Host</h3>
            <p class="panel-subtitle">2xx OK, 3xx Redirect, 4xx Client Error, 5xx Server Error</p>
          </div>
        </div>
        <div class="chart-container chart-md">
          <canvas id="chart-compare-status"></canvas>
        </div>
      </div>
    </div>

    <div class="panel-card">
      <div class="panel-header">
        <div>
          <h3 class="panel-title">Virtual Host Comparison Table</h3>
          <p class="panel-subtitle">Select Charts or Detailed Traffic for any virtual host</p>
        </div>
      </div>
      <div class="table-responsive">
        <table class="data-table">
          <thead>
            <tr>
              <th>Virtual Host</th>
              <th class="num">Requests</th>
              <th class="num">Share</th>
              <th class="num">Unique IPs</th>
              <th class="num">Bandwidth</th>
              <th class="num">2xx</th>
              <th class="num">3xx</th>
              <th class="num">4xx</th>
              <th class="num">5xx</th>
              <th class="num">Error %</th>
              <th class="num">Bot %</th>
              <th>Views</th>
            </tr>
          </thead>
          <tbody id="tbody-compare-vhosts"></tbody>
        </table>
      </div>
    </div>
  </main>
</body>
</html>
HTML

    my $file = "$self->{output_dir}/index.html";
    utf8::encode($html) if utf8::is_utf8($html);
    open my $fh, '>:raw', $file or croak "Cannot write '$file': $!";
    print {$fh} $html;
    close $fh;
    return $file;
}

sub _prepare_vhost_rankings {
    my ($vh) = @_;

    # Top Endpoints
    my @endpoints = values %{ $vh->{endpoints} || {} };
    @endpoints = sort { ($b->{requests} <=> $a->{requests}) || ($a->{path} cmp $b->{path}) } @endpoints;
    splice(@endpoints, 100) if @endpoints > 100;
    for my $ep (@endpoints) {
        $ep->{avg_bytes} = $ep->{requests} > 0 ? int($ep->{bytes} / $ep->{requests}) : 0;
    }

    # HTTP Methods
    my @methods;
    for my $m (keys %{ $vh->{methods} || {} }) {
        push @methods, {
            method   => $m,
            requests => $vh->{methods}{$m}{requests},
            bytes    => $vh->{methods}{$m}{bytes},
        };
    }
    @methods = sort { $b->{requests} <=> $a->{requests} } @methods;

    # Top IPs
    my @ips;
    for my $ip (keys %{ $vh->{ips} || {} }) {
        my $row = $vh->{ips}{$ip};
        push @ips, {
            client_ip   => $ip,
            requests    => $row->{requests},
            bytes       => $row->{bytes},
            error_count => $row->{error_count},
            last_seen   => $row->{last_seen},
        };
    }
    @ips = sort { ($b->{requests} <=> $a->{requests}) || ($a->{client_ip} cmp $b->{client_ip}) } @ips;
    splice(@ips, 100) if @ips > 100;

    # Top Referrers
    my @referrers;
    for my $ref (keys %{ $vh->{referrers} || {} }) {
        push @referrers, {
            referer  => $ref,
            requests => $vh->{referrers}{$ref},
        };
    }
    @referrers = sort { $b->{requests} <=> $a->{requests} } @referrers;
    splice(@referrers, 50) if @referrers > 50;

    # UA Categories
    my @ua_cats;
    for my $cat (keys %{ $vh->{ua_categories} || {} }) {
        push @ua_cats, {
            ua_category => $cat,
            requests    => $vh->{ua_categories}{$cat}{requests},
            bytes       => $vh->{ua_categories}{$cat}{bytes},
        };
    }
    @ua_cats = sort { $b->{requests} <=> $a->{requests} } @ua_cats;

    # UA Families
    my @ua_fams = values %{ $vh->{ua_families} || {} };
    @ua_fams = sort { $b->{requests} <=> $a->{requests} } @ua_fams;
    splice(@ua_fams, 40) if @ua_fams > 40;

    # Error Status Codes
    my @err_codes;
    for my $st (keys %{ $vh->{error_codes} || {} }) {
        push @err_codes, {
            status   => int($st),
            requests => $vh->{error_codes}{$st},
        };
    }
    @err_codes = sort { $b->{requests} <=> $a->{requests} } @err_codes;

    # Error URLs
    my @err_urls;
    for my $eu (values %{ $vh->{error_urls} || {} }) {
        push @err_urls, {
            status     => int($eu->{status}),
            method     => $eu->{method},
            path       => $eu->{path},
            requests   => $eu->{requests},
            unique_ips => scalar(keys %{ $eu->{ips} || {} }),
        };
    }
    @err_urls = sort { $b->{requests} <=> $a->{requests} } @err_urls;
    splice(@err_urls, 100) if @err_urls > 100;

    # Error IPs
    my @err_ips;
    for my $ip (keys %{ $vh->{error_ips} || {} }) {
        my $e = $vh->{error_ips}{$ip};
        my $total_err = ($e->{count_4xx} || 0) + ($e->{count_5xx} || 0);
        push @err_ips, {
            client_ip      => $ip,
            error_requests => $total_err,
            count_4xx      => $e->{count_4xx} || 0,
            count_5xx      => $e->{count_5xx} || 0,
            distinct_paths => scalar(keys %{ $e->{paths} || {} }),
        };
    }
    @err_ips = sort { $b->{error_requests} <=> $a->{error_requests} } @err_ips;
    splice(@err_ips, 50) if @err_ips > 50;

    return {
        endpoints     => \@endpoints,
        methods       => \@methods,
        ips           => \@ips,
        referrers     => \@referrers,
        ua_categories => \@ua_cats,
        ua_families   => \@ua_fams,
        error_codes   => \@err_codes,
        error_urls    => \@err_urls,
        error_ips     => \@err_ips,
    };
}

sub _write_vhost_chart_page {
    my ($self, $v_meta, $vh, $vhost_list, $generated_at) = @_;
    my $slug      = $v_meta->{slug};
    my $name_html = _escape_html($v_meta->{name});
    my $rankings  = _prepare_vhost_rankings($vh);

    my $payload = {
        page_type     => 'vhost_charts',
        generated_at  => $generated_at,
        name          => $v_meta->{name},
        slug          => $slug,
        first_seen    => $v_meta->{first_seen},
        last_seen     => $v_meta->{last_seen},
        unique_ips    => $v_meta->{unique_ips},
        hourly        => $vh->{hourly} || {},
        methods       => $rankings->{methods},
        ua_categories => $rankings->{ua_categories},
        error_codes   => $rankings->{error_codes},
    };

    my $json_str = _encode_embedded_json($payload);
    my $nav_opts = _render_nav_options( $vhost_list, $slug, '../', 'charts' );

    my $html = <<"HTML";
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>$name_html — Charts Overview — Apache Traffic Analytics</title>
  <link rel="stylesheet" href="../assets/report.css">
  <script>window.REPORT_DATA = $json_str;</script>
  <script src="../assets/chart.umd.min.js" defer></script>
  <script src="../assets/report.js" defer></script>
</head>
<body>
  <header class="top-header">
    <div class="brand-group">
      <a href="../index.html" class="brand-icon" aria-label="All Virtual Hosts">📊</a>
      <div>
        <h1 class="brand-title">$name_html</h1>
        <p class="brand-subtitle">Virtual Host Charts View • Generated $generated_at</p>
      </div>
    </div>

    <div class="controls-bar">
      <div class="control-item">
        <label for="vhost-nav-select" class="control-label">Virtual Host</label>
        <select id="vhost-nav-select" class="select-input vhost-dropdown">
          $nav_opts
        </select>
      </div>

      <div class="control-item">
        <span class="control-label">View Mode</span>
        <div class="btn-group">
          <a href="$slug.html" class="btn-chip active">📈 Charts Overview</a>
          <a href="$slug-details.html" class="btn-chip">🔎 Detailed Traffic &amp; Logs</a>
        </div>
      </div>

      <div class="control-item">
        <span class="control-label">Time Window</span>
        <div class="btn-group" role="group" aria-label="Time range presets">
          <button type="button" class="btn-chip" data-range="24h">24h</button>
          <button type="button" class="btn-chip" data-range="7d">7d</button>
          <button type="button" class="btn-chip" data-range="30d">30d</button>
          <button type="button" class="btn-chip active" data-range="all">All Data</button>
        </div>
      </div>

      <div class="control-item date-inputs">
        <div>
          <label for="start-date" class="control-label">From (UTC)</label>
          <input type="datetime-local" id="start-date" class="date-input">
        </div>
        <div>
          <label for="end-date" class="control-label">To (UTC)</label>
          <input type="datetime-local" id="end-date" class="date-input">
        </div>
      </div>

      <div class="control-item">
        <label for="granularity-select" class="control-label">Bucket</label>
        <select id="granularity-select" class="select-input">
          <option value="auto">Auto</option>
          <option value="hour">Hourly</option>
          <option value="day">Daily</option>
        </select>
      </div>
    </div>
  </header>

  <main class="main-container">
    <div class="section-header">
      <div class="vhost-title-row">
        <a href="../index.html" class="btn btn-secondary btn-sm">← All Vhosts Comparison</a>
        <div>
          <h2 class="section-title">$name_html — Chart Analytics</h2>
          <p class="section-desc" id="vh-subtitle">High-level charts and KPI summary</p>
        </div>
      </div>
      <a href="$slug-details.html" class="btn btn-primary">Open Detailed Traffic &amp; Logs →</a>
    </div>

    <div class="kpi-grid">
      <div class="kpi-card">
        <span class="kpi-label">Total Requests</span>
        <strong class="kpi-value" id="vh-kpi-requests">0</strong>
        <span class="kpi-sub" id="vh-kpi-2xx">0 successful (2xx)</span>
      </div>
      <div class="kpi-card">
        <span class="kpi-label">Unique Visitors (IPs)</span>
        <strong class="kpi-value" id="vh-kpi-ips">0</strong>
        <span class="kpi-sub" id="vh-kpi-req-per-ip">0.0 req / IP</span>
      </div>
      <div class="kpi-card">
        <span class="kpi-label">Bandwidth Transferred</span>
        <strong class="kpi-value" id="vh-kpi-bytes">0 B</strong>
        <span class="kpi-sub" id="vh-kpi-avg-bytes">Avg 0 B / response</span>
      </div>
      <div class="kpi-card">
        <span class="kpi-label">Client &amp; Server Errors</span>
        <strong class="kpi-value" id="vh-kpi-err-rate">0.00%</strong>
        <span class="kpi-sub" id="vh-kpi-err-breakdown">4xx: 0 | 5xx: 0</span>
      </div>
      <div class="kpi-card">
        <span class="kpi-label">Human vs. Bot Traffic</span>
        <strong class="kpi-value" id="vh-kpi-bot-pct">0.0% Bots</strong>
        <span class="kpi-sub" id="vh-kpi-bot-counts">0 human / 0 bot</span>
      </div>
    </div>

    <div class="panel-card">
      <div class="panel-header">
        <div>
          <h3 class="panel-title">Traffic &amp; HTTP Status Timeline</h3>
          <p class="panel-subtitle">Hourly or daily status code progression, bandwidth, and bot activity</p>
        </div>
        <div class="btn-group" role="group" aria-label="Single vhost timeline mode">
          <button type="button" class="btn-chip active" data-vh-chart-mode="status">Status Codes (Stacked)</button>
          <button type="button" class="btn-chip" data-vh-chart-mode="bytes">Bandwidth</button>
          <button type="button" class="btn-chip" data-vh-chart-mode="bots">Human vs. Bot</button>
        </div>
      </div>
      <div class="chart-container chart-lg">
        <canvas id="chart-vhost-timeline"></canvas>
      </div>
    </div>

    <div class="grid-3col">
      <div class="panel-card">
        <div class="panel-header">
          <div>
            <h3 class="panel-title">HTTP Methods</h3>
            <p class="panel-subtitle">Requests by HTTP verb</p>
          </div>
        </div>
        <div class="chart-container chart-md">
          <canvas id="chart-vh-methods"></canvas>
        </div>
      </div>

      <div class="panel-card">
        <div class="panel-header">
          <div>
            <h3 class="panel-title">Client Categories</h3>
            <p class="panel-subtitle">Browser, Mobile, Bot/Crawler, CLI/API</p>
          </div>
        </div>
        <div class="chart-container chart-md">
          <canvas id="chart-vh-ua-cat"></canvas>
        </div>
      </div>

      <div class="panel-card">
        <div class="panel-header">
          <div>
            <h3 class="panel-title">4xx / 5xx Error Codes</h3>
            <p class="panel-subtitle">Distribution of error status codes</p>
          </div>
        </div>
        <div class="chart-container chart-md">
          <canvas id="chart-vh-error-codes"></canvas>
        </div>
      </div>
    </div>
  </main>
</body>
</html>
HTML

    my $file = "$self->{output_dir}/vhosts/$slug.html";
    utf8::encode($html) if utf8::is_utf8($html);
    open my $fh, '>:raw', $file or croak "Cannot write '$file': $!";
    print {$fh} $html;
    close $fh;
    return $file;
}

sub _write_vhost_details_page {
    my ($self, $v_meta, $vh, $vhost_list, $generated_at) = @_;
    my $slug      = $v_meta->{slug};
    my $name_html = _escape_html($v_meta->{name});
    my $rankings  = _prepare_vhost_rankings($vh);

    my $payload = {
        page_type     => 'vhost_details',
        generated_at  => $generated_at,
        name          => $v_meta->{name},
        slug          => $slug,
        first_seen    => $v_meta->{first_seen},
        last_seen     => $v_meta->{last_seen},
        unique_ips    => $v_meta->{unique_ips},
        endpoints     => $rankings->{endpoints},
        methods       => $rankings->{methods},
        ips           => $rankings->{ips},
        referrers     => $rankings->{referrers},
        ua_families   => $rankings->{ua_families},
        error_urls    => $rankings->{error_urls},
        error_ips     => $rankings->{error_ips},
        recent_logs   => $vh->{recent_logs} || [],
    };

    my $json_str = _encode_embedded_json($payload);
    my $nav_opts = _render_nav_options( $vhost_list, $slug, '../', 'details' );

    my $html = <<"HTML";
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>$name_html — Detailed Traffic &amp; Logs — Apache Traffic Analytics</title>
  <link rel="stylesheet" href="../assets/report.css">
  <script>window.REPORT_DATA = $json_str;</script>
  <script src="../assets/report.js" defer></script>
</head>
<body>
  <header class="top-header">
    <div class="brand-group">
      <a href="../index.html" class="brand-icon" aria-label="All Virtual Hosts">📊</a>
      <div>
        <h1 class="brand-title">$name_html</h1>
        <p class="brand-subtitle">Detailed Traffic Report • Generated $generated_at</p>
      </div>
    </div>

    <div class="controls-bar">
      <div class="control-item">
        <label for="vhost-nav-select" class="control-label">Virtual Host</label>
        <select id="vhost-nav-select" class="select-input vhost-dropdown">
          $nav_opts
        </select>
      </div>

      <div class="control-item">
        <span class="control-label">View Mode</span>
        <div class="btn-group">
          <a href="$slug.html" class="btn-chip">📈 Charts Overview</a>
          <a href="$slug-details.html" class="btn-chip active">🔎 Detailed Traffic &amp; Logs</a>
        </div>
      </div>
    </div>
  </header>

  <main class="main-container">
    <div class="section-header">
      <div class="vhost-title-row">
        <a href="$slug.html" class="btn btn-secondary btn-sm">← Back to $name_html Charts</a>
        <div>
          <h2 class="section-title">$name_html — Detailed Traffic Breakdown</h2>
          <p class="section-desc">Endpoints, Client IPs, User-Agents, Referrers, 4xx/5xx Error Inspector, and Recent Request Explorer</p>
        </div>
      </div>
    </div>

    <div class="subtabs-bar" role="tablist" aria-label="Detailed Traffic Sections">
      <button type="button" class="subtab-btn active" data-subtab="tab-endpoints">🔗 Top Endpoints &amp; URLs</button>
      <button type="button" class="subtab-btn" data-subtab="tab-clients">🌍 Client IPs, User-Agents &amp; Referrers</button>
      <button type="button" class="subtab-btn" data-subtab="tab-errors">⚠️ Error Inspector (4xx / 5xx)</button>
      <button type="button" class="subtab-btn" data-subtab="tab-rawlogs">🔎 Recent Request Log Explorer</button>
    </div>

    <!-- TAB 1: TOP ENDPOINTS -->
    <section id="tab-endpoints" class="subtab-panel">
      <div class="panel-card">
        <div class="panel-header">
          <div>
            <h3 class="panel-title">Top Requested URLs / Endpoints</h3>
            <p class="panel-subtitle">Search or filter endpoints by path or HTTP method</p>
          </div>
          <input type="search" id="search-endpoints" class="text-input" placeholder="Filter path or method...">
        </div>
        <div class="table-responsive">
          <table class="data-table">
            <thead>
              <tr>
                <th>Method</th>
                <th>Path</th>
                <th class="num">Requests</th>
                <th class="num">Total Bandwidth</th>
                <th class="num">Avg Size</th>
                <th class="num">4xx</th>
                <th class="num">5xx</th>
                <th>Inspect</th>
              </tr>
            </thead>
            <tbody id="tbody-vh-endpoints"></tbody>
          </table>
        </div>
      </div>
    </section>

    <!-- TAB 2: CLIENT IPs, USER-AGENTS & REFERRERS -->
    <section id="tab-clients" class="subtab-panel" hidden>
      <div class="grid-2col">
        <div class="panel-card">
          <div class="panel-header">
            <div>
              <h3 class="panel-title">Top Client IP Addresses</h3>
              <p class="panel-subtitle">Highest volume visitors and error counts</p>
            </div>
            <input type="search" id="search-ips" class="text-input" placeholder="Filter IP address...">
          </div>
          <div class="table-responsive">
            <table class="data-table">
              <thead>
                <tr>
                  <th>Client IP</th>
                  <th class="num">Requests</th>
                  <th class="num">Bandwidth</th>
                  <th class="num">4xx/5xx Errors</th>
                  <th>Inspect</th>
                </tr>
              </thead>
              <tbody id="tbody-vh-ips"></tbody>
            </table>
          </div>
        </div>

        <div class="panel-card">
          <div class="panel-header">
            <div>
              <h3 class="panel-title">Browsers, Bots &amp; HTTP Clients</h3>
              <p class="panel-subtitle">Classified User-Agent families</p>
            </div>
          </div>
          <div class="table-responsive">
            <table class="data-table compact">
              <thead>
                <tr>
                  <th>Category</th>
                  <th>Family</th>
                  <th class="num">Requests</th>
                  <th class="num">Bandwidth</th>
                </tr>
              </thead>
              <tbody id="tbody-vh-ua-families"></tbody>
            </table>
          </div>

          <div class="panel-header mt-md">
            <div>
              <h3 class="panel-title">Top HTTP Referrers</h3>
              <p class="panel-subtitle">External and internal referring URLs</p>
            </div>
          </div>
          <div class="table-responsive">
            <table class="data-table compact">
              <thead>
                <tr>
                  <th>Referrer URL</th>
                  <th class="num">Requests</th>
                </tr>
              </thead>
              <tbody id="tbody-vh-referrers"></tbody>
            </table>
          </div>
        </div>
      </div>
    </section>

    <!-- TAB 3: ERROR INSPECTOR -->
    <section id="tab-errors" class="subtab-panel" hidden>
      <div class="grid-2col">
        <div class="panel-card">
          <div class="panel-header">
            <div>
              <h3 class="panel-title">Top Failing Endpoints (4xx &amp; 5xx)</h3>
              <p class="panel-subtitle">Broken links, unauthorized probes, and server errors</p>
            </div>
          </div>
          <div class="table-responsive">
            <table class="data-table">
              <thead>
                <tr>
                  <th>Status</th>
                  <th>Method</th>
                  <th>Path</th>
                  <th class="num">Occurrences</th>
                  <th class="num">Unique IPs</th>
                  <th>Inspect</th>
                </tr>
              </thead>
              <tbody id="tbody-vh-error-urls"></tbody>
            </table>
          </div>
        </div>

        <div class="panel-card">
          <div class="panel-header">
            <div>
              <h3 class="panel-title">Top Error-Triggering IPs</h3>
              <p class="panel-subtitle">Clients and scanners generating 4xx/5xx responses</p>
            </div>
          </div>
          <div class="table-responsive">
            <table class="data-table">
              <thead>
                <tr>
                  <th>Client IP</th>
                  <th class="num">4xx Errors</th>
                  <th class="num">5xx Errors</th>
                  <th class="num">Distinct Paths</th>
                  <th>Inspect</th>
                </tr>
              </thead>
              <tbody id="tbody-vh-error-ips"></tbody>
            </table>
          </div>
        </div>
      </div>
    </section>

    <!-- TAB 4: RECENT REQUEST LOG EXPLORER -->
    <section id="tab-rawlogs" class="subtab-panel" hidden>
      <div class="panel-card">
        <div class="panel-header">
          <div>
            <h3 class="panel-title">Recent Request Log Explorer</h3>
            <p class="panel-subtitle">Filter embedded recent requests by path, IP, method, status, or client type</p>
          </div>
        </div>

        <form id="form-log-search" class="log-filter-bar">
          <div class="filter-field">
            <label for="filter-path">Path / Query</label>
            <input type="text" id="filter-path" placeholder="/api/v1 or ?id=" class="text-input">
          </div>
          <div class="filter-field">
            <label for="filter-ip">Client IP</label>
            <input type="text" id="filter-ip" placeholder="192.168.1." class="text-input">
          </div>
          <div class="filter-field">
            <label for="filter-method">Method</label>
            <select id="filter-method" class="select-input">
              <option value="">All Methods</option>
              <option value="GET">GET</option>
              <option value="POST">POST</option>
              <option value="PUT">PUT</option>
              <option value="DELETE">DELETE</option>
              <option value="HEAD">HEAD</option>
              <option value="OPTIONS">OPTIONS</option>
            </select>
          </div>
          <div class="filter-field">
            <label for="filter-status">Status</label>
            <select id="filter-status" class="select-input">
              <option value="">All Statuses</option>
              <option value="2xx">2xx Success</option>
              <option value="3xx">3xx Redirect</option>
              <option value="4xx">4xx Client Error</option>
              <option value="5xx">5xx Server Error</option>
              <option value="errors">All Errors (4xx + 5xx)</option>
              <option value="200">200 OK</option>
              <option value="301">301 Moved</option>
              <option value="302">302 Found</option>
              <option value="401">401 Unauthorized</option>
              <option value="403">403 Forbidden</option>
              <option value="404">404 Not Found</option>
              <option value="500">500 Internal Error</option>
              <option value="502">502 Bad Gateway</option>
              <option value="503">503 Unavailable</option>
            </select>
          </div>
          <div class="filter-field">
            <label for="filter-ua-cat">Client Type</label>
            <select id="filter-ua-cat" class="select-input">
              <option value="">All Types</option>
              <option value="Browser">Browser</option>
              <option value="Mobile">Mobile</option>
              <option value="Bot">Bot / Crawler</option>
              <option value="CLI/API">CLI / API</option>
              <option value="Other">Other</option>
            </select>
          </div>
          <div class="filter-actions">
            <button type="button" id="btn-clear-log-filters" class="btn btn-secondary">Clear Filters</button>
          </div>
        </form>

        <div class="table-responsive">
          <table class="data-table log-table">
            <thead>
              <tr>
                <th>Timestamp (UTC)</th>
                <th>Client IP</th>
                <th>Method</th>
                <th>Path &amp; Query</th>
                <th>Status</th>
                <th class="num">Size</th>
                <th>Client / User-Agent</th>
              </tr>
            </thead>
            <tbody id="tbody-raw-logs"></tbody>
          </table>
        </div>

        <div class="pagination-bar">
          <span id="raw-logs-summary" class="pagination-info">Showing 0 of 0 logs</span>
          <div class="btn-group">
            <button type="button" id="btn-logs-prev" class="btn btn-secondary btn-sm" disabled>← Previous</button>
            <span id="raw-logs-page-indicator" class="page-indicator">Page 1 of 1</span>
            <button type="button" id="btn-logs-next" class="btn btn-secondary btn-sm" disabled>Next →</button>
          </div>
        </div>
      </div>
    </section>
  </main>
</body>
</html>
HTML

    my $file = "$self->{output_dir}/vhosts/$slug-details.html";
    utf8::encode($html) if utf8::is_utf8($html);
    open my $fh, '>:raw', $file or croak "Cannot write '$file': $!";
    print {$fh} $html;
    close $fh;
    return $file;
}

1;
