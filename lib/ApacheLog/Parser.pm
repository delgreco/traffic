package ApacheLog::Parser;
use strict;
use warnings;
use Time::Local qw(timegm);
use File::Basename qw(basename);

my %MONTH_MAP = (
    Jan => 0, Feb => 1, Mar => 2, Apr => 3,
    May => 4, Jun => 5, Jul => 6, Aug => 7,
    Sep => 8, Oct => 9, Nov => 10, Dec => 11,
);

sub new {
    my ($class, %args) = @_;
    my $config = $args{config} || {};
    my $regex = $args{filename_vhost_regex}
        || $config->{filename_vhost_regex}
        || '^(.+?)(?:[-_.]access)?\\.log';

    return bless {
        filename_vhost_regex       => qr/$regex/i,
        default_vhost_from_filename => exists $config->{default_vhost_from_filename}
            ? $config->{default_vhost_from_filename}
            : 1,
    }, $class;
}

sub vhost_from_filename {
    my ($self, $filepath) = @_;
    return 'default' unless defined $filepath && length $filepath;
    my $base = basename($filepath);
    $base =~ s/\.(?:gz|bz2|xz|\d+)$//i;
    if ($base =~ $self->{filename_vhost_regex}) {
        my $vh = lc($1);
        $vh =~ s/^[^a-z0-9]+|[^a-z0-9]+$//g;
        return $vh if length $vh && $vh ne 'access' && $vh ne 'other_vhosts';
    }
    return 'default';
}

sub normalize_vhost {
    my ($vhost) = @_;
    return undef unless defined $vhost && length $vhost;
    $vhost = lc($vhost);
    $vhost =~ s/:\d+$//; # Strip :80 or :443 suffix from %v
    $vhost =~ s/^\s+|\s+$//g;
    return ($vhost eq '-' || $vhost eq '') ? undef : $vhost;
}

sub parse_line {
    my ($self, $line, %opts) = @_;
    return undef unless defined $line;
    $line =~ s/[\r\n]+$//;
    return undef if $line eq '' || $line =~ /^\s*#/;

    my ($vhost_raw, $client_ip, $ident, $user, $ts_str, $request, $status, $bytes_raw, $referer, $ua);

    # Pattern 1: vhost_combined (%v %h %l %u [%t] "%r" %>s %b "%{Referer}i" "%{User-Agent}i")
    # Note: In vhost_combined, the first token is vhost[:port] followed by client IP/host
    if ($line =~ /^(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+\[([^\]]+)\]\s+"((?:\\"|[^"])*)"\s+(\d{3})\s+(\d+|-)(?:\s+"((?:\\"|[^"])*)"\s+"((?:\\"|[^"])*)")?/) {
        ($vhost_raw, $client_ip, $ident, $user, $ts_str, $request, $status, $bytes_raw, $referer, $ua)
            = ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10);
    }
    # Pattern 2: combined or common (%h %l %u [%t] "%r" %>s %b ["%{Referer}i" "%{User-Agent}i"])
    elsif ($line =~ /^(\S+)\s+(\S+)\s+(\S+)\s+\[([^\]]+)\]\s+"((?:\\"|[^"])*)"\s+(\d{3})\s+(\d+|-)(?:\s+"((?:\\"|[^"])*)"\s+"((?:\\"|[^"])*)")?/) {
        ($client_ip, $ident, $user, $ts_str, $request, $status, $bytes_raw, $referer, $ua)
            = ($1, $2, $3, $4, $5, $6, $7, $8, $9);
    } else {
        return undef;
    }

    my $epoch = parse_apache_timestamp($ts_str);
    return undef unless defined $epoch;

    my $vhost = normalize_vhost($vhost_raw)
        || normalize_vhost($opts{default_vhost})
        || ($self->{default_vhost_from_filename} && $opts{file_path} ? $self->vhost_from_filename($opts{file_path}) : undef)
        || 'default';

    my ($method, $path, $query_string, $protocol) = parse_request_line($request);
    my $bytes = ($bytes_raw eq '-' || !defined $bytes_raw) ? 0 : int($bytes_raw);

    $referer = '' if !defined $referer || $referer eq '-';
    $ua      = '' if !defined $ua      || $ua eq '-';

    my ($ua_category, $ua_family) = classify_user_agent($ua);

    return {
        vhost        => $vhost,
        timestamp    => $epoch,
        client_ip    => $client_ip,
        method       => $method,
        path         => $path,
        query_string => $query_string,
        protocol     => $protocol,
        status       => int($status),
        bytes        => $bytes,
        referer      => $referer,
        user_agent   => $ua,
        ua_category  => $ua_category,
        ua_family    => $ua_family,
    };
}

sub parse_apache_timestamp {
    my ($ts_str) = @_;
    return undef unless defined $ts_str;
    # Format: 25/Oct/2026:15:04:02 +0000
    if ($ts_str =~ m{^(\d{1,2})/([A-Za-z]{3})/(\d{4}):(\d{2}):(\d{2}):(\d{2})\s*([+\-]\d{4})?$}) {
        my ($day, $mon_str, $year, $hour, $min, $sec, $tz) = ($1, $2, $3, $4, $5, $6, $7);
        my $mon = $MONTH_MAP{$mon_str};
        return undef unless defined $mon;

        my $epoch = eval { timegm($sec, $min, $hour, $day, $mon, $year - 1900) };
        return undef if $@ || !defined $epoch;

        if (defined $tz && $tz =~ /^([+\-])(\d{2})(\d{2})$/) {
            my $sign = $1 eq '-' ? -1 : 1;
            my $offset_secs = $sign * ($2 * 3600 + $3 * 60);
            $epoch -= $offset_secs;
        }
        return $epoch;
    }
    return undef;
}

sub parse_request_line {
    my ($req) = @_;
    return ('-', '/', '', '') if !defined $req || $req eq '' || $req eq '-';

    my ($method, $uri, $proto) = split /\s+/, $req, 3;
    $method = uc($method // 'GET');
    $uri    = '/' unless defined $uri && length $uri;
    $proto  = $proto // 'HTTP/1.1';

    # If full URL in proxy request (e.g. GET http://example.com/foo?bar=1 HTTP/1.1), strip scheme+host
    $uri =~ s{^https?://[^/]+}{}i;
    $uri = '/' if $uri eq '';

    my ($path, $query) = split /\?/, $uri, 2;
    $path = '/' if !defined $path || $path eq '';
    $query //= '';

    return ($method, $path, $query, $proto);
}

sub classify_user_agent {
    my ($ua) = @_;
    return ('Other', 'Unknown') if !defined $ua || $ua eq '';

    # 1. Bots / Crawlers / Spiders
    if ($ua =~ /(Googlebot|bingbot|Baiduspider|YandexBot|DuckDuckBot|Slurp|AhrefsBot|SemrushBot|MJ12bot|DotBot|PetalBot|GPTBot|ClaudeBot|CCBot|Bytespider|facebookexternalhit|Twitterbot|LinkedInBot|Applebot|Pingdom|UptimeRobot|StatusCake|bot|crawler|spider|scraper)/i) {
        my $match = $1;
        my $family = 'Other Bot';
        if    ($match =~ /Googlebot/i)   { $family = 'Googlebot'; }
        elsif ($match =~ /bingbot/i)     { $family = 'Bingbot'; }
        elsif ($match =~ /AhrefsBot/i)   { $family = 'AhrefsBot'; }
        elsif ($match =~ /SemrushBot/i)  { $family = 'SemrushBot'; }
        elsif ($match =~ /GPTBot|ClaudeBot|CCBot/i) { $family = 'AI Crawler'; }
        elsif ($match =~ /Pingdom|UptimeRobot|StatusCake/i) { $family = 'Uptime Monitor'; }
        elsif ($match =~ /facebook|Twitter|LinkedIn/i) { $family = 'Social Preview'; }
        return ('Bot', $family);
    }

    # 2. CLI / API / Programmatic Clients
    if ($ua =~ m{(curl|Wget|python-requests|python-httpx|aiohttp|Go-http-client|Java/|Apache-HttpClient|okhttp|axios|node-fetch|PostmanRuntime|Insomnia|libwww-perl|Mojo)}i) {
        my $m = lc($1);
        my $family = 'API Client';
        if    ($m eq 'curl')             { $family = 'curl'; }
        elsif ($m eq 'wget')             { $family = 'Wget'; }
        elsif ($m =~ /python/)           { $family = 'Python HTTP'; }
        elsif ($m =~ /go-http/)          { $family = 'Go HTTP'; }
        elsif ($m =~ /postman|insomnia/) { $family = 'API Tester'; }
        elsif ($m =~ /perl|mojo/)        { $family = 'Perl HTTP'; }
        return ('CLI/API', $family);
    }

    # 3. Browsers (Mobile & Desktop)
    my $is_mobile = ($ua =~ /Mobile|Android|iPhone|iPad|iPod/i) ? 1 : 0;
    my $category  = $is_mobile ? 'Mobile' : 'Browser';

    if    ($ua =~ /Edg(?:e|A|iOS)?\//i)      { return ($category, 'Edge'); }
    elsif ($ua =~ /OPR\/|Opera/i)            { return ($category, 'Opera'); }
    elsif ($ua =~ /Chrome\/|CriOS\//i)       { return ($category, 'Chrome'); }
    elsif ($ua =~ /Firefox\/|FxiOS\//i)      { return ($category, 'Firefox'); }
    elsif ($ua =~ /Safari\//i && $ua =~ /Version\//i) { return ($category, 'Safari'); }
    elsif ($ua =~ /MSIE|Trident\//i)         { return ($category, 'Internet Explorer'); }

    return ('Other', 'Other');
}

1;
