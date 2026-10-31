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
like($det_html, qr/"page_type":"vhost_details"/, 'Details HTML has page_type=vhost_details');
like($det_html, qr/"\/missing\.png"/, 'Details HTML embeds endpoint & recent log data');

done_testing();
