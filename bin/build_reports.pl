#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Getopt::Long qw(GetOptions);
use ApacheLog::StateStore;
use ApacheLog::ReportBuilder;

my @files;
my $default_vhost;
my $config_path;
my $state_file;
my $output_dir;
my $force        = 0;
my $rebuild_only = 0;
my $reset_state  = 0;
my $help         = 0;

GetOptions(
    'file|f=s@'      => \@files,
    'vhost|v=s'      => \$default_vhost,
    'config|c=s'     => \$config_path,
    'state|s=s'      => \$state_file,
    'output-dir|o=s' => \$output_dir,
    'force'          => \$force,
    'rebuild-only'   => \$rebuild_only,
    'reset'          => \$reset_state,
    'help|h'         => \$help,
) or die "Error in command line arguments. Run with --help for usage.\n";

if ($help) {
    print <<"USAGE";
Apache Traffic Static HTML Report Generator

Usage:
  perl bin/build_reports.pl [options] [log_file1 log_file2 ...]

Options:
  --file, -f <path>           Path or glob to Apache access log file (repeatable)
  --vhost, -v <name>          Explicit default virtual host name if not in %v
  --config, -c <path>         Path to config JSON (default: config/traffic.json)
  --state, -s <path>          Override JSON state file path (default: state/traffic_state.json)
  --output-dir, -o <dir>      Override static HTML output directory (default: output)
  --force                     Re-read log files from byte offset 0
  --rebuild-only              Regenerate static HTML files from existing JSON state without reading logs
  --reset                     Clear all saved state before running
  --help, -h                  Show this help message
USAGE
    exit 0;
}

push @files, @ARGV if @ARGV;

my $config = ApacheLog::StateStore->load_config($config_path);
my $store  = ApacheLog::StateStore->new(
    config     => $config,
    state_file => $state_file,
);

if ($reset_state) {
    $store->reset_state();
    print "State reset complete.\n";
}

if (!$rebuild_only) {
    my $total_read     = 0;
    my $total_ingested = 0;
    my $total_skipped  = 0;
    my %vhosts_seen;

    if (@files) {
        for my $pattern (@files) {
            my @expanded = (-f $pattern) ? ($pattern) : glob($pattern);
            if (!@expanded) {
                warn "Warning: No files matched '$pattern'\n";
                next;
            }
            for my $f (@expanded) {
                my $res = $store->ingest_file(
                    $f,
                    default_vhost => $default_vhost,
                    force         => $force,
                    no_save       => 1,
                );
                $total_read     += $res->{lines_read};
                $total_ingested += $res->{lines_ingested};
                $total_skipped  += $res->{lines_skipped};
                for my $vh (keys %{ $res->{vhosts_updated} || {} }) {
                    $vhosts_seen{$vh} += $res->{vhosts_updated}{$vh};
                }
                printf "Processed %s: %d read, %d ingested, %d skipped\n",
                    $f, $res->{lines_read}, $res->{lines_ingested}, $res->{lines_skipped};
            }
        }
        $store->prune_and_trim();
        $store->save_state();
    } else {
        my $res = $store->ingest_configured_sources(force => $force);
        $total_read     = $res->{lines_read};
        $total_ingested = $res->{lines_ingested};
        $total_skipped  = $res->{lines_skipped};
        %vhosts_seen    = %{ $res->{vhosts_updated} || {} };
        printf "Processed %d configured files: %d read, %d ingested, %d skipped\n",
            $res->{files_processed}, $total_read, $total_ingested, $total_skipped;
    }

    if (keys %vhosts_seen) {
        print "Virtual hosts updated:\n";
        for my $vh (sort keys %vhosts_seen) {
            printf "  - %-30s +%d requests\n", $vh, $vhosts_seen{$vh};
        }
    }
}

my $builder = ApacheLog::ReportBuilder->new(
    store      => $store,
    config     => $config,
    output_dir => $output_dir,
    assets_src => "$FindBin::Bin/../assets",
);

my $build_res = $builder->build_all();
printf "Generated static HTML report site in '%s' (%d virtual hosts, %d HTML pages written).\n",
    $build_res->{output_dir},
    $build_res->{vhosts_count},
    scalar(@{ $build_res->{files_written} });
