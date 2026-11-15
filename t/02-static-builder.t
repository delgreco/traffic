use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use POSIX qw(strftime);
use FindBin;
use lib "$FindBin::Bin/../lib";
use ApacheLog::StateStore;
use ApacheLog::ReportBuilder;

my $tmp_dir    = tempdir(CLEANUP => 1);
my $state_file = "$tmp_dir/traffic_state.json";
my $output_dir = "$tmp_dir/output";
my $log_file   = "$tmp_dir/alpha.example.com-access.log";

my $config = {
    state_file                  => $state_file,
    output_dir                  => $output_dir,
    raw_retention_days          => 30,
    max_recent_logs_per_vhost   => 500,
    default_vhost_from_filename => 1,
    filename_vhost_regex        => '^(.+?)(?:[-_.]access)?\\.log',
};

my $store = ApacheLog::StateStore->new(
    config     => $config,
    state_file => $state_file,
);

my $now = time();
my $ts_recent = strftime("%d/%b/%Y:%H:%M:%S +0000", gmtime($now - 3600));
my $ts_old    = strftime("%d/%b/%Y:%H:%M:%S +0000", gmtime($now - 45 * 86400));

open my $fh, '>', $log_file or die $!;
print {$fh} qq{10.1.1.1 - - [$ts_recent] "GET /index.html HTTP/1.1" 200 2048 "https://ref.example/" "Mozilla/5.0 Chrome/128.0"\n};
print {$fh} qq{10.1.1.2 - - [$ts_recent] "GET /missing.png HTTP/1.1" 404 512 "-" "Googlebot/2.1"\n};
print {$fh} qq{beta.example.com:443 10.2.2.9 - - [$ts_old] "POST /api/login HTTP/1.1" 500 128 "-" "curl/8.0"\n};
close $fh;

# 1. First ingestion pass
my $r1 = $store->ingest_file($log_file);
is($r1->{lines_read}, 3, 'Read 3 lines on first pass');
is($r1->{lines_ingested}, 3, 'Ingested 3 lines on first pass');
ok(-f $state_file, 'Persisted JSON state file to disk');

# 2. Second pass without changes should read 0 lines (incremental byte offset)
my $r2 = $store->ingest_file($log_file);
is($r2->{lines_read}, 0, 'Read 0 lines when file unchanged');

# 3. Append 1 new line and verify incremental read
open my $fh_app, '>>', $log_file or die $!;
print {$fh_app} qq{10.1.1.1 - - [$ts_recent] "GET /style.css HTTP/1.1" 200 1024 "-" "Mozilla/5.0 Chrome/128.0"\n};
close $fh_app;

my $r3 = $store->ingest_file($log_file);
is($r3->{lines_read}, 1, 'Incrementally read only the 1 newly appended line');
is($r3->{lines_ingested}, 1, 'Incrementally ingested only the 1 newly appended line');

# 4. Reload state from disk into a fresh StateStore instance and build static HTML site
my $store2 = ApacheLog::StateStore->new(
    config     => $config,
    state_file => $state_file,
);
my $builder = ApacheLog::ReportBuilder->new(
    store      => $store2,
    config     => $config,
    output_dir => $output_dir,
    assets_src => "$FindBin::Bin/../assets",
);

my $build_res = $builder->build_all();
is($build_res->{vhosts_count}, 2, 'Built static reports for 2 virtual hosts');

ok(-f "$output_dir/index.html", 'Generated output/index.html (All Vhosts Comparison)');
ok(-f "$output_dir/assets/report.js", 'Copied report.js asset');
ok(-f "$output_dir/assets/report.css", 'Copied report.css asset');
ok(-f "$output_dir/assets/chart.umd.min.js", 'Copied chart.umd.min.js asset');

ok(-f "$output_dir/vhosts/alpha.example.com.html", 'Generated alpha.example.com chart page');
ok(-f "$output_dir/vhosts/alpha.example.com-details.html", 'Generated alpha.example.com separate detailed traffic page');
ok(-f "$output_dir/vhosts/beta.example.com.html", 'Generated beta.example.com chart page');
ok(-f "$output_dir/vhosts/beta.example.com-details.html", 'Generated beta.example.com separate detailed traffic page');

# 5. Verify embedded data in HTML files
open my $idx_fh, '<:encoding(UTF-8)', "$output_dir/index.html" or die $!;
my $idx_html = do { local $/; <$idx_fh> };
close $idx_fh;
like($idx_html, qr/window\.REPORT_DATA\s*=\s*\{/, 'index.html embeds window.REPORT_DATA');
like($idx_html, qr/"page_type":"compare"/, 'index.html has page_type=compare');
like($idx_html, qr/vhosts\/alpha\.example\.com\.html/, 'index.html dropdown links to alpha.example.com.html');

open my $det_fh, '<:encoding(UTF-8)', "$output_dir/vhosts/alpha.example.com-details.html" or die $!;
my $det_html = do { local $/; <$det_fh> };
close $det_fh;
like( $det_html, qr/"page_type":"vhost_details"/, 'Details HTML has page_type=vhost_details' );
like( $det_html, qr/"\/missing\.png"/, 'Details HTML embeds endpoint & recent log data' );
like( $det_html, qr/vhosts\/beta\.example\.com-details\.html/, 'Details dropdown preserves details view mode for other vhosts' );

open my $chart_fh, '<:encoding(UTF-8)', "$output_dir/vhosts/alpha.example.com.html" or die $!;
my $chart_html = do { local $/; <$chart_fh> };
close $chart_fh;
like( $chart_html, qr/vhosts\/beta\.example\.com\.html/, 'Chart dropdown preserves charts view mode for other vhosts' );
like( $chart_html, qr/"ext_ref_domains":\[/, 'Chart HTML embeds ext_ref_domains array' );

# 6. Verify skip_common_format, external vs internal referrals, origin fallback, and campaigns
{
    my $dedup_log = "$tmp_dir/dedup.example.com-access.log";
    open my $dfh, '>', $dedup_log or die $!;
    print {$dfh} qq{10.9.9.1 - - [$ts_recent] "GET / HTTP/1.1" 200 100\n}; # common duplicate
    print {$dfh} qq{10.9.9.1 - - [$ts_recent] "GET /?utm_source=bing&utm_medium=cpc&utm_campaign=launch HTTP/1.1" 200 100 "https://alpha.example.com/about" "Mozilla/5.0 Chrome/128.0"\n};
    print {$dfh} qq{10.9.9.2 - - [$ts_recent] "GET /api/ping HTTP/1.1" 200 50 "-" "Mozilla/5.0 Chrome/128.0" "https://widget.external.org"\n};
    print {$dfh} qq{10.9.9.3 - - [$ts_recent] "GET /cart HTTP/1.1" 200 100 "https://dedup.example.com/" "Mozilla/5.0 Chrome/128.0"\n};
    close $dfh;

    my $r_dedup = $store->ingest_file(
        $dedup_log,
        default_vhost      => 'dedup.example.com',
        skip_common_format => 1,
    );
    is( $r_dedup->{lines_read}, 4, 'Read 4 lines from dedup test log' );
    is( $r_dedup->{lines_skipped}, 1, 'Skipped 1 common-format line when skip_common_format=1' );
    is( $r_dedup->{lines_ingested}, 3, 'Ingested 3 combined/combined-origin lines' );

    ApacheLog::ReportBuilder->new(
        store      => $store,
        output_dir => $output_dir,
    )->build_all();

    open my $dd_fh, '<:encoding(UTF-8)', "$output_dir/vhosts/dedup.example.com-details.html" or die $!;
    my $dd_html = do { local $/; <$dd_fh> };
    close $dd_fh;
    like( $dd_html, qr/"domain":"alpha\.example\.com"/, 'Details HTML includes external referrer domain' );
    like( $dd_html, qr/"domain":"widget\.external\.org"/, 'Details HTML includes Origin header fallback external domain' );
    like( $dd_html, qr/"int_ref_urls":\[\{[^}]*"url":"https:\/\/dedup\.example\.com\/"/, 'Details HTML tracks internal self-referrals separately' );
    like( $dd_html, qr/"campaign":"launch"/, 'Details HTML embeds extracted campaign attribution' );
    like( $dd_html, qr/"path_type":"page"/, 'Details HTML embeds path_type=page on endpoints' );
    like( $dd_html, qr/data-ep-type="page"/, 'Details HTML includes resource-type filter chips' );

    open my $alpha_chart_fh, '<:encoding(UTF-8)', "$output_dir/vhosts/alpha.example.com.html" or die $!;
    my $alpha_chart_html = do { local $/; <$alpha_chart_fh> };
    close $alpha_chart_fh;
    like( $alpha_chart_html, qr/"path_types":\[/, 'Chart HTML embeds path_types breakdown' );
    like( $alpha_chart_html, qr/"path_type":"image"/, 'Chart HTML records image requests in path_types' );
    like( $alpha_chart_html, qr/id="chart-vh-path-types"/, 'Chart HTML includes Content Types canvas' );
}

# 7. Verify Fail2ban Apache jail status parsing and main-page embedding
{
    my @jails = ApacheLog::ReportBuilder::_parse_fail2ban_jail_list(
        "Status\n|- Number of jail:\t5\n`- Jail list:\tapache-auth, apache-badbots, apache-noscript, apache-probes, sshd\n"
    );
    is_deeply( \@jails, [qw( apache-auth apache-badbots apache-noscript apache-probes )], 'Filtered only Apache jails from fail2ban jail list' );

    my $parsed_jail = ApacheLog::ReportBuilder::_parse_fail2ban_jail_status(
        'apache-probes',
        "Status for the jail: apache-probes\n|- Filter\n|  |- Currently failed:\t2\n|  |- Total failed:\t18\n|  `- File list:\t/var/log/apache2/access.log /var/log/apache2/other_vhosts_access.log\n`- Actions\n   |- Currently banned:\t1\n   |- Total banned:\t4\n   `- Banned IP list:\t185.176.255.79\n"
    );
    is( $parsed_jail->{currently_failed}, 2, 'Parsed currently_failed' );
    is( $parsed_jail->{total_failed}, 18, 'Parsed total_failed' );
    is( $parsed_jail->{currently_banned}, 1, 'Parsed currently_banned' );
    is( $parsed_jail->{total_banned}, 4, 'Parsed total_banned' );
    is_deeply( $parsed_jail->{banned_ips}, ['185.176.255.79'], 'Parsed banned_ips' );
    is( $parsed_jail->{watched_files}, 2, 'Parsed watched file count' );

    ApacheLog::ReportBuilder->new(
        store      => $store,
        output_dir => $output_dir,
        fail2ban   => {
            available              => 1,
            collected_at           => '2026-11-15 18:00:00 UTC',
            total_currently_banned => 1,
            total_banned           => 4,
            total_failed           => 18,
            jails                  => [ $parsed_jail ],
        },
    )->build_all();

    open my $f2b_idx_fh, '<:encoding(UTF-8)', "$output_dir/index.html" or die $!;
    my $f2b_idx_html = do { local $/; <$f2b_idx_fh> };
    close $f2b_idx_fh;
    like( $f2b_idx_html, qr/id="tbody-fail2ban-jails"/, 'index.html renders Fail2ban Apache Protection panel' );
    like( $f2b_idx_html, qr/"jail":"apache-probes"/, 'index.html embeds fail2ban jail JSON payload' );
    like( $f2b_idx_html, qr/185\.176\.255\.79/, 'index.html embeds banned IP list for Apache jails' );
}

done_testing();
