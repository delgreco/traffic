package ApacheLog::StateStore;
use strict;
use warnings;
use Fcntl qw(:seek);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use IO::Uncompress::Gunzip;
use JSON::PP;
use Carp qw(croak);
use ApacheLog::Parser;

sub load_config {
    my ($class, $config_path) = @_;
    $config_path ||= $ENV{TRAFFIC_CONFIG} || 'config/traffic.json';
    if (!-f $config_path) {
        return {
            state_file                => 'state/traffic_state.json',
            output_dir                => 'output',
            raw_retention_days        => 30,
            max_recent_logs_per_vhost => 1000,
            default_vhost_from_filename => 1,
            filename_vhost_regex      => '^(.+?)(?:[-_.]access)?\\.log',
            log_sources => [],
        };
    }
    open my $fh, '<:encoding(UTF-8)', $config_path
        or croak "Cannot open config file '$config_path': $!";
    local $/;
    my $raw = <$fh>;
    close $fh;
    return JSON::PP::decode_json($raw);
}

sub new {
    my ($class, %args) = @_;
    my $config     = $args{config} || $class->load_config($args{config_path});
    my $state_file = $args{state_file} || $ENV{TRAFFIC_STATE} || $config->{state_file} || 'state/traffic_state.json';
    my $parser     = $args{parser} || ApacheLog::Parser->new(config => $config);

    my $self = bless {
        config                    => $config,
        state_file                => $state_file,
        parser                    => $parser,
        raw_retention_days        => defined $args{raw_retention_days}
            ? $args{raw_retention_days}
            : ($config->{raw_retention_days} // 30),
        max_recent_logs_per_vhost => $args{max_recent_logs_per_vhost}
            || $config->{max_recent_logs_per_vhost}
            || 1000,
        state                     => undef,
    }, $class;

    $self->load_state();
    return $self;
}

sub empty_state {
    return {
        version         => 1,
        updated_at      => time(),
        ingestion_state => {},
        inode_offsets   => {},
        vhosts          => {},
    };
}

sub load_state {
    my ($self) = @_;
    my $file = $self->{state_file};
    if (-f $file) {
        open my $fh, '<:encoding(UTF-8)', $file
            or croak "Cannot read state file '$file': $!";
        local $/;
        my $raw = <$fh>;
        close $fh;
        if (defined $raw && $raw =~ /\S/) {
            my $decoded = eval { JSON::PP::decode_json($raw) };
            if ($decoded && ref $decoded eq 'HASH') {
                $decoded->{ingestion_state} ||= {};
                $decoded->{inode_offsets}   ||= {};
                $decoded->{vhosts}          ||= {};
                $self->{state} = $decoded;
                return $self->{state};
            }
        }
    }
    $self->{state} = $self->empty_state();
    return $self->{state};
}

sub save_state {
    my ($self) = @_;
    my $file = $self->{state_file};
    my $dir  = dirname($file);
    make_path($dir) if $dir && $dir ne '.' && !-d $dir;

    $self->{state}{updated_at} = time();
    my $coder = JSON::PP->new->utf8->canonical;
    my $json  = $coder->encode($self->{state});

    my $tmp = "$file.tmp.$$";
    open my $fh, '>', $tmp
        or croak "Cannot write temporary state file '$tmp': $!";
    print {$fh} $json;
    close $fh;
    rename $tmp, $file
        or croak "Cannot rename '$tmp' to '$file': $!";
    return 1;
}

sub reset_state {
    my ($self) = @_;
    $self->{state} = $self->empty_state();
    if (-f $self->{state_file}) {
        $self->save_state();
    }
    return 1;
}

sub state {
    my ($self) = @_;
    return $self->{state};
}

sub vhost_slug {
    my ($name) = @_;
    my $slug = lc($name // 'default');
    $slug =~ s/[^a-z0-9._-]+/_/g;
    $slug =~ s/^_+|_+$//g;
    return length($slug) ? $slug : 'default';
}

sub _ensure_vhost {
    my ($self, $name, $ts) = @_;
    my $vhosts = $self->{state}{vhosts};
    my $vh = $vhosts->{$name};
    if (!$vh) {
        $vh = {
            name         => $name,
            slug         => vhost_slug($name),
            first_seen   => $ts,
            last_seen    => $ts,
            hourly       => {}, # hour_bucket => { requests, bytes, s2xx, s3xx, s4xx, s5xx, bots, humans }
            endpoints    => {}, # "METHOD path" => { method, path, requests, bytes, error_4xx, error_5xx, last_seen }
            methods      => {}, # METHOD => { requests, bytes }
            ips          => {}, # client_ip => { requests, bytes, error_count, last_seen }
            referrers    => {}, # referer => requests
            ua_categories => {}, # category => { requests, bytes }
            ua_families  => {}, # "category|family" => { category, family, requests, bytes }
            error_codes  => {}, # status => requests
            error_urls   => {}, # "status|METHOD|path" => { status, method, path, requests, ips => {} }
            error_ips    => {}, # client_ip => { count_4xx, count_5xx, paths => {} }
            recent_logs  => [], # bounded array of recent raw log hashes
        };
        $vhosts->{$name} = $vh;
    } else {
        $vh->{first_seen} = $ts if $ts < $vh->{first_seen};
        $vh->{last_seen}  = $ts if $ts > $vh->{last_seen};
    }
    return $vh;
}

sub ingest_configured_sources {
    my ($self, %opts) = @_;
    my $sources = $self->{config}{log_sources} || [];
    my %totals = (
        files_processed => 0,
        lines_read      => 0,
        lines_ingested  => 0,
        lines_skipped   => 0,
        vhosts_updated  => {},
    );

    for my $src (@$sources) {
        my $pattern = $src->{path} or next;
        my $vhost   = $src->{vhost};
        my @files   = glob($pattern);
        for my $file (sort @files) {
            next unless -f $file && -r $file;
            if ($file =~ /\.gz$/i && $self->{state}{archives_backfilled} && !$opts{force}) {
                next;
            }
            my $res = $self->ingest_file(
                $file,
                default_vhost => $vhost,
                force         => $opts{force},
                no_save       => 1,
            );
            $totals{files_processed}++;
            $totals{lines_read}     += $res->{lines_read};
            $totals{lines_ingested} += $res->{lines_ingested};
            $totals{lines_skipped}  += $res->{lines_skipped};
            for my $vh (keys %{ $res->{vhosts_updated} || {} }) {
                $totals{vhosts_updated}{$vh} += $res->{vhosts_updated}{$vh};
            }
        }
    }

    $self->{state}{archives_backfilled} = 1 if $totals{files_processed} > 0;
    $self->prune_and_trim();
    $self->save_state();
    return \%totals;
}

sub ingest_file {
    my ($self, $file_path, %opts) = @_;
    my $abs_path = File::Spec->rel2abs($file_path);
    croak "File does not exist: $abs_path" unless -f $abs_path;

    my @st = stat($abs_path);
    my ($inode, $size) = ($st[1], $st[7]);
    my $is_gz = ($abs_path =~ /\.gz$/i) ? 1 : 0;

    my $ing_state = $self->{state}{ingestion_state}{$abs_path};
    my $known_inode_offset = $self->{state}{inode_offsets}{$inode};
    my $start_offset = 0;

    if (!$opts{force}) {
        if ($is_gz) {
            if ($ing_state && $ing_state->{inode} == $inode && $ing_state->{byte_offset} > 0) {
                return {
                    file_path      => $abs_path,
                    lines_read     => 0,
                    lines_ingested => 0,
                    lines_skipped  => 0,
                    vhosts_updated => {},
                    skipped_file   => 1,
                };
            }
        } else {
            if ($ing_state && $ing_state->{inode} == $inode && $size >= $ing_state->{byte_offset}) {
                $start_offset = $ing_state->{byte_offset};
            } elsif (defined $known_inode_offset && $size >= $known_inode_offset) {
                $start_offset = $known_inode_offset;
            }
        }
    }

    if (!$is_gz && $start_offset == $size && $size > 0 && !$opts{force}) {
        return {
            file_path      => $abs_path,
            lines_read     => 0,
            lines_ingested => 0,
            lines_skipped  => 0,
            vhosts_updated => {},
        };
    }

    my $fh;
    if ($is_gz) {
        $fh = IO::Uncompress::Gunzip->new($abs_path)
            or croak "Cannot open gzip file '$abs_path': $IO::Uncompress::Gunzip::GunzipError";
    } else {
        open $fh, '<', $abs_path or croak "Cannot open file '$abs_path': $!";
        if ($start_offset > 0) {
            seek($fh, $start_offset, SEEK_SET);
        }
    }

    my $res = $self->_process_handle(
        $fh,
        file_path     => $abs_path,
        default_vhost => $opts{default_vhost},
    );

    my $end_offset = $is_gz ? $size : tell($fh);
    close $fh;

    $self->{state}{ingestion_state}{$abs_path} = {
        inode            => $inode,
        byte_offset      => $end_offset,
        last_ingested_at => time(),
    };
    $self->{state}{inode_offsets}{$inode} = $end_offset unless $is_gz;

    if (!$opts{no_save}) {
        $self->prune_and_trim();
        $self->save_state();
    }

    $res->{file_path} = $abs_path;
    return $res;
}

sub _process_handle {
    my ($self, $fh, %opts) = @_;
    my $lines_read     = 0;
    my $lines_ingested = 0;
    my $lines_skipped  = 0;
    my %vhosts_updated;

    my $retention_days = $self->{raw_retention_days};
    my $cutoff_ts = ($retention_days && $retention_days > 0)
        ? (time() - ($retention_days * 86400))
        : 0;
    my $max_recent = $self->{max_recent_logs_per_vhost};

    while (my $line = <$fh>) {
        $lines_read++;
        my $row = $self->{parser}->parse_line(
            $line,
            default_vhost => $opts{default_vhost},
            file_path     => $opts{file_path},
        );
        if (!$row) {
            $lines_skipped++;
            next;
        }

        $lines_ingested++;
        my $vhost_name = $row->{vhost};
        $vhosts_updated{$vhost_name}++;

        my $ts     = $row->{timestamp};
        my $status = $row->{status};
        my $bytes  = $row->{bytes};
        my $is_bot = ($row->{ua_category} eq 'Bot') ? 1 : 0;

        my $vh = $self->_ensure_vhost($vhost_name, $ts);

        # 1. Hourly rollup bucket
        my $hour_bucket = $ts - ($ts % 3600);
        my $h = ($vh->{hourly}{$hour_bucket} ||= {
            requests       => 0,
            bytes          => 0,
            status_2xx     => 0,
            status_3xx     => 0,
            status_4xx     => 0,
            status_5xx     => 0,
            bot_requests   => 0,
            human_requests => 0,
        });
        $h->{requests}++;
        $h->{bytes} += $bytes;
        if    ($status >= 200 && $status < 300) { $h->{status_2xx}++; }
        elsif ($status >= 300 && $status < 400) { $h->{status_3xx}++; }
        elsif ($status >= 400 && $status < 500) { $h->{status_4xx}++; }
        elsif ($status >= 500)                  { $h->{status_5xx}++; }
        if ($is_bot) { $h->{bot_requests}++; } else { $h->{human_requests}++; }

        # 2. Endpoint rollup
        my $ep_key = "$row->{method} $row->{path}";
        my $ep = ($vh->{endpoints}{$ep_key} ||= {
            method    => $row->{method},
            path      => $row->{path},
            requests  => 0,
            bytes     => 0,
            error_4xx => 0,
            error_5xx => 0,
            last_seen => $ts,
        });
        $ep->{requests}++;
        $ep->{bytes} += $bytes;
        $ep->{error_4xx}++ if $status >= 400 && $status < 500;
        $ep->{error_5xx}++ if $status >= 500;
        $ep->{last_seen} = $ts if $ts > $ep->{last_seen};

        # 3. HTTP Method rollup
        my $m = ($vh->{methods}{ $row->{method} } ||= { requests => 0, bytes => 0 });
        $m->{requests}++;
        $m->{bytes} += $bytes;

        # 4. Client IP rollup
        my $ip = ($vh->{ips}{ $row->{client_ip} } ||= {
            requests    => 0,
            bytes       => 0,
            error_count => 0,
            last_seen   => $ts,
        });
        $ip->{requests}++;
        $ip->{bytes} += $bytes;
        $ip->{error_count}++ if $status >= 400;
        $ip->{last_seen} = $ts if $ts > $ip->{last_seen};

        # 5. Referrer rollup
        if (defined $row->{referer} && $row->{referer} ne '') {
            $vh->{referrers}{ $row->{referer} }++;
        }

        # 6. User-Agent category & family rollups
        my $uac = ($vh->{ua_categories}{ $row->{ua_category} } ||= { requests => 0, bytes => 0 });
        $uac->{requests}++;
        $uac->{bytes} += $bytes;

        my $uaf_key = "$row->{ua_category}|$row->{ua_family}";
        my $uaf = ($vh->{ua_families}{$uaf_key} ||= {
            ua_category => $row->{ua_category},
            ua_family   => $row->{ua_family},
            requests    => 0,
            bytes       => 0,
        });
        $uaf->{requests}++;
        $uaf->{bytes} += $bytes;

        # 7. Error inspector rollups (4xx / 5xx)
        if ($status >= 400) {
            $vh->{error_codes}{$status}++;
            my $eu_key = "$status|$row->{method}|$row->{path}";
            my $eu = ($vh->{error_urls}{$eu_key} ||= {
                status   => $status,
                method   => $row->{method},
                path     => $row->{path},
                requests => 0,
                ips      => {},
            });
            $eu->{requests}++;
            $eu->{ips}{ $row->{client_ip} } = 1;

            my $eip = ($vh->{error_ips}{ $row->{client_ip} } ||= {
                count_4xx => 0,
                count_5xx => 0,
                paths     => {},
            });
            if ($status >= 500) { $eip->{count_5xx}++; } else { $eip->{count_4xx}++; }
            $eip->{paths}{ $row->{path} } = 1;
        }

        # 8. Recent raw log buffer (if within raw_retention_days)
        if ($cutoff_ts == 0 || $ts >= $cutoff_ts) {
            push @{ $vh->{recent_logs} }, {
                timestamp    => $ts,
                client_ip    => $row->{client_ip},
                method       => $row->{method},
                path         => $row->{path},
                query_string => $row->{query_string},
                status       => $status,
                bytes        => $bytes,
                referer      => $row->{referer},
                user_agent   => $row->{user_agent},
                ua_category  => $row->{ua_category},
                ua_family    => $row->{ua_family},
            };
            if (@{ $vh->{recent_logs} } > $max_recent * 2) {
                @{ $vh->{recent_logs} } = splice(@{ $vh->{recent_logs} }, -$max_recent);
            }
        }
    }

    return {
        lines_read     => $lines_read,
        lines_ingested => $lines_ingested,
        lines_skipped  => $lines_skipped,
        vhosts_updated => \%vhosts_updated,
    };
}

sub prune_and_trim {
    my ($self) = @_;
    my $retention_days = $self->{raw_retention_days};
    my $cutoff_ts = ($retention_days && $retention_days > 0)
        ? (time() - ($retention_days * 86400))
        : 0;
    my $max_recent = $self->{max_recent_logs_per_vhost};

    for my $vh (values %{ $self->{state}{vhosts} || {} }) {
        my @logs = @{ $vh->{recent_logs} || [] };
        if ($cutoff_ts > 0) {
            @logs = grep { $_->{timestamp} >= $cutoff_ts } @logs;
        }
        @logs = sort { $b->{timestamp} <=> $a->{timestamp} } @logs;
        if (@logs > $max_recent) {
            @logs = @logs[0 .. $max_recent - 1];
        }
        $vh->{recent_logs} = \@logs;
    }
    return 1;
}

1;
