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

=head2 new

Creates a new ApacheLog::Parser instance with optional filename vhost regex configuration.

=cut

sub new {
    my ( $class, %args ) = @_;
    my $config = $args{config} || {};
    my $regex = $args{filename_vhost_regex}
        || $config->{filename_vhost_regex}
        || '^(.+?)(?:[-_.]access)?\\.log';

    return bless {
        filename_vhost_regex        => qr/$regex/i,
        default_vhost_from_filename => exists $config->{default_vhost_from_filename}
            ? $config->{default_vhost_from_filename}
            : 1,
    }, $class;
}

=head2 vhost_from_filename

Derives a normalized virtual host name from an Apache log file path when %v is absent.

=cut

sub vhost_from_filename {
    my ( $self, $filepath ) = @_;
    return 'default' unless defined $filepath && length $filepath;
    my $base = basename( $filepath );
    $base =~ s/\.(?:gz|bz2|xz|\d+)$//i;
    if ( $base =~ $self->{filename_vhost_regex} ) {
        my $vh = lc( $1 );
        $vh =~ s/^[^a-z0-9]+|[^a-z0-9]+$//g;
        return $vh if length $vh && $vh ne 'access' && $vh ne 'other_vhosts';
    }
    return 'default';
}

=head2 normalize_vhost

Lowercases a virtual host string and strips any trailing :port suffix.

=cut

sub normalize_vhost {
    my ( $vhost ) = @_;
    return undef unless defined $vhost && length $vhost;
    $vhost = lc( $vhost );
    $vhost =~ s/:\d+$//;
    $vhost =~ s/^\s+|\s+$//g;
    return ( $vhost eq '-' || $vhost eq '' ) ? undef : $vhost;
}

=head2 parse_line

Parses a single Apache access log line in vhost_combined, combined, or common format,
including an optional trailing "%{Origin}i" quoted header field.

=cut

sub parse_line {
    my ( $self, $line, %opts ) = @_;
    return undef unless defined $line;
    $line =~ s/[\r\n]+$//;
    return undef if $line eq '' || $line =~ /^\s*#/;

    my ( $vhost_raw, $client_ip, $ident, $user, $ts_str, $request, $status, $bytes_raw, $referer, $ua, $origin );

    # Pattern 1: vhost_combined (%v %h %l %u [%t] "%r" %>s %b "%{Referer}i" "%{User-Agent}i" ["%{Origin}i"])
    if ( $line =~ /^(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+\[([^\]]+)\]\s+"((?:\\"|[^"])*)"\s+(\d{3})\s+(\d+|-)(?:\s+"((?:\\"|[^"])*)"\s+"((?:\\"|[^"])*)"(?:\s+"((?:\\"|[^"])*)")?)?/ ) {
        ( $vhost_raw, $client_ip, $ident, $user, $ts_str, $request, $status, $bytes_raw, $referer, $ua, $origin )
            = ( $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11 );
    }
    # Pattern 2: combined or common (%h %l %u [%t] "%r" %>s %b ["%{Referer}i" "%{User-Agent}i" ["%{Origin}i"]])
    elsif ( $line =~ /^(\S+)\s+(\S+)\s+(\S+)\s+\[([^\]]+)\]\s+"((?:\\"|[^"])*)"\s+(\d{3})\s+(\d+|-)(?:\s+"((?:\\"|[^"])*)"\s+"((?:\\"|[^"])*)"(?:\s+"((?:\\"|[^"])*)")?)?/ ) {
        ( $client_ip, $ident, $user, $ts_str, $request, $status, $bytes_raw, $referer, $ua, $origin )
            = ( $1, $2, $3, $4, $5, $6, $7, $8, $9, $10 );
    }
    else {
        return undef;
    }

    my $has_referer_ua = defined( $referer ) ? 1 : 0;

    my $epoch = parse_apache_timestamp( $ts_str );
    return undef unless defined $epoch;

    my $vhost = normalize_vhost( $vhost_raw )
        || normalize_vhost( $opts{default_vhost} )
        || ( $self->{default_vhost_from_filename} && $opts{file_path} ? $self->vhost_from_filename( $opts{file_path} ) : undef )
        || 'default';

    my ( $method, $path, $query_string, $protocol ) = parse_request_line( $request );
    my $bytes = ( $bytes_raw eq '-' || ! defined $bytes_raw ) ? 0 : int( $bytes_raw );

    $referer = '' if ! defined $referer || $referer eq '-';
    $ua      = '' if ! defined $ua      || $ua eq '-';
    $origin  = '' if ! defined $origin  || $origin eq '-' || lc( $origin ) eq 'null';

    my ( $ua_category, $ua_family ) = classify_user_agent( $ua );

    return {
        vhost          => $vhost,
        timestamp      => $epoch,
        client_ip      => $client_ip,
        method         => $method,
        path           => $path,
        query_string   => $query_string,
        protocol       => $protocol,
        status         => int( $status ),
        bytes          => $bytes,
        referer        => $referer,
        origin         => $origin,
        has_referer_ua => $has_referer_ua,
        user_agent     => $ua,
        ua_category    => $ua_category,
        ua_family      => $ua_family,
    };
}

=head2 parse_apache_timestamp

Converts an Apache CLF timestamp string into Unix epoch seconds (UTC).

=cut

sub parse_apache_timestamp {
    my ( $ts_str ) = @_;
    return undef unless defined $ts_str;
    if ( $ts_str =~ m{^(\d{1,2})/([A-Za-z]{3})/(\d{4}):(\d{2}):(\d{2}):(\d{2})\s*([+\-]\d{4})?$} ) {
        my ( $day, $mon_str, $year, $hour, $min, $sec, $tz ) = ( $1, $2, $3, $4, $5, $6, $7 );
        my $mon = $MONTH_MAP{$mon_str};
        return undef unless defined $mon;

        my $epoch = eval { timegm( $sec, $min, $hour, $day, $mon, $year - 1900 ) };
        return undef if $@ || ! defined $epoch;

        if ( defined $tz && $tz =~ /^([+\-])(\d{2})(\d{2})$/ ) {
            my $sign = $1 eq '-' ? -1 : 1;
            my $offset_secs = $sign * ( $2 * 3600 + $3 * 60 );
            $epoch -= $offset_secs;
        }
        return $epoch;
    }
    return undef;
}

=head2 parse_request_line

Splits an HTTP request line into method, clean path, query string, and protocol.

=cut

sub parse_request_line {
    my ( $req ) = @_;
    return ( '-', '/', '', '' ) if ! defined $req || $req eq '' || $req eq '-';

    my ( $method, $uri, $proto ) = split /\s+/, $req, 3;
    $method = uc( $method // 'GET' );
    $uri    = '/' unless defined $uri && length $uri;
    $proto  = $proto // 'HTTP/1.1';

    $uri =~ s{^https?://[^/]+}{}i;
    $uri = '/' if $uri eq '';

    my ( $path, $query ) = split /\?/, $uri, 2;
    $path = '/' if ! defined $path || $path eq '';
    $query //= '';

    return ( $method, $path, $query, $proto );
}

=head2 classify_referer

Extracts the normalized referrer domain and classifies a Referer or Origin URL
as internal (matching the target virtual host or its www alias) or external.

=cut

sub classify_referer {
    my ( $url, $vhost ) = @_;
    return undef unless defined $url;
    $url =~ s/^\s+|\s+$//g;
    return undef if $url eq '' || $url eq '-' || lc( $url ) eq 'null';

    my $domain;
    if ( $url =~ m{^https?://([^/:?#]+)}i ) {
        $domain = lc( $1 );
    }
    elsif ( $url =~ m{^android-app://([^/?#]+)}i ) {
        $domain = 'android-app://' . lc( $1 );
    }
    elsif ( $url =~ m{^([a-z0-9.-]+\.[a-z]{2,})(?:[:/?#]|$)}i ) {
        $domain = lc( $1 );
    }
    else {
        $domain = '(other)';
    }

    my $vh_norm  = lc( $vhost // '' );
    $vh_norm     =~ s/^www\.//;
    my $dom_norm = $domain;
    $dom_norm    =~ s/^www\.//;

    my $scope = ( $vh_norm ne '' && $dom_norm eq $vh_norm ) ? 'internal' : 'external';

    return {
        scope  => $scope,
        domain => $domain,
        url    => $url,
    };
}

=head2 _url_decode

Decodes application/x-www-form-urlencoded characters for query parameter inspection.

=cut

sub _url_decode {
    my ( $str ) = @_;
    return '' unless defined $str;
    $str =~ tr/+/ /;
    $str =~ s/%([0-9A-Fa-f]{2})/chr( hex( $1 ) )/ge;
    return $str;
}

=head2 extract_campaign_params

Extracts UTM tags and click-ID referral parameters (fbclid, gclid, msclkid, mc_cid, ref)
from a parsed request query string.

=cut

sub extract_campaign_params {
    my ( $query_string ) = @_;
    return undef unless defined $query_string && length $query_string;

    my %found;
    for my $pair ( split /&/, $query_string ) {
        next unless $pair =~ /^([^=]+)=(.*)$/;
        my $k = lc( _url_decode( $1 ) );
        my $v = _url_decode( $2 );
        next unless length $v;

        if ( $k =~ /^(?:utm_source|utm_medium|utm_campaign|utm_content|utm_term|fbclid|gclid|msclkid|mc_cid|ref)$/ ) {
            $found{$k} = $v;
        }
    }

    return undef unless keys %found;

    my $click_type = '';
    if    ( exists $found{gclid} )   { $click_type = 'Google Ads (gclid)'; }
    elsif ( exists $found{fbclid} )  { $click_type = 'Meta/Facebook (fbclid)'; }
    elsif ( exists $found{msclkid} ) { $click_type = 'Microsoft Ads (msclkid)'; }
    elsif ( exists $found{mc_cid} )  { $click_type = 'Mailchimp (mc_cid)'; }
    elsif ( exists $found{ref} )     { $click_type = 'ref=' . $found{ref}; }

    return {
        source     => $found{utm_source}   // ( $click_type ? $click_type : '(direct-tag)' ),
        medium     => $found{utm_medium}   // '',
        campaign   => $found{utm_campaign} // '',
        click_type => $click_type,
    };
}

=head2 classify_user_agent

Categorizes a User-Agent string into Browser, Mobile, Bot, CLI/API, or Other along with its family name.

=cut

sub classify_user_agent {
    my ( $ua ) = @_;
    return ( 'Other', 'Unknown' ) if ! defined $ua || $ua eq '';

    # 1. Bots / Crawlers / Spiders
    if ( $ua =~ /(Googlebot|bingbot|Baiduspider|YandexBot|DuckDuckBot|Slurp|AhrefsBot|SemrushBot|MJ12bot|DotBot|PetalBot|GPTBot|ClaudeBot|CCBot|Bytespider|facebookexternalhit|Twitterbot|LinkedInBot|Applebot|Pingdom|UptimeRobot|StatusCake|bot|crawler|spider|scraper)/i ) {
        my $match = $1;
        my $family = 'Other Bot';
        if    ( $match =~ /Googlebot/i )   { $family = 'Googlebot'; }
        elsif ( $match =~ /bingbot/i )     { $family = 'Bingbot'; }
        elsif ( $match =~ /AhrefsBot/i )   { $family = 'AhrefsBot'; }
        elsif ( $match =~ /SemrushBot/i )  { $family = 'SemrushBot'; }
        elsif ( $match =~ /GPTBot|ClaudeBot|CCBot/i ) { $family = 'AI Crawler'; }
        elsif ( $match =~ /Pingdom|UptimeRobot|StatusCake/i ) { $family = 'Uptime Monitor'; }
        elsif ( $match =~ /facebook|Twitter|LinkedIn/i ) { $family = 'Social Preview'; }
        return ( 'Bot', $family );
    }

    # 2. CLI / API / Programmatic Clients
    if ( $ua =~ m{(curl|Wget|python-requests|python-httpx|aiohttp|Go-http-client|Java/|Apache-HttpClient|okhttp|axios|node-fetch|PostmanRuntime|Insomnia|libwww-perl|Mojo)}i ) {
        my $m = lc( $1 );
        my $family = 'API Client';
        if    ( $m eq 'curl' )             { $family = 'curl'; }
        elsif ( $m eq 'wget' )             { $family = 'Wget'; }
        elsif ( $m =~ /python/ )           { $family = 'Python HTTP'; }
        elsif ( $m =~ /go-http/ )          { $family = 'Go HTTP'; }
        elsif ( $m =~ /postman|insomnia/ ) { $family = 'API Tester'; }
        elsif ( $m =~ /perl|mojo/ )        { $family = 'Perl HTTP'; }
        return ( 'CLI/API', $family );
    }

    # 3. Browsers (Mobile & Desktop)
    my $is_mobile = ( $ua =~ /Mobile|Android|iPhone|iPad|iPod/i ) ? 1 : 0;
    my $category  = $is_mobile ? 'Mobile' : 'Browser';

    if    ( $ua =~ /Edg(?:e|A|iOS)?\//i )      { return ( $category, 'Edge' ); }
    elsif ( $ua =~ /OPR\/|Opera/i )            { return ( $category, 'Opera' ); }
    elsif ( $ua =~ /Chrome\/|CriOS\//i )       { return ( $category, 'Chrome' ); }
    elsif ( $ua =~ /Firefox\/|FxiOS\//i )      { return ( $category, 'Firefox' ); }
    elsif ( $ua =~ /Safari\//i && $ua =~ /Version\//i ) { return ( $category, 'Safari' ); }
    elsif ( $ua =~ /MSIE|Trident\//i )         { return ( $category, 'Internet Explorer' ); }

    return ( 'Other', 'Other' );
}

1;
