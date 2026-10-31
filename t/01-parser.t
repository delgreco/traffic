use strict;
use warnings;
use Test::More;
use lib 'lib';
use ApacheLog::Parser;

my $parser = ApacheLog::Parser->new();

# 1. Test vhost_combined (%v with port)
{
    my $line = 'Shop.Example.com:443 203.0.113.45 - - [25/Oct/2026:14:22:01 +0000] "GET /products/shoes?color=blue&size=10 HTTP/2.0" 200 15420 "https://www.google.com/" "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"';
    my $res = $parser->parse_line($line);
    ok($res, 'Parsed vhost_combined line');
    is($res->{vhost}, 'shop.example.com', 'Normalized vhost and stripped :443');
    is($res->{client_ip}, '203.0.113.45', 'Extracted client IP');
    is($res->{method}, 'GET', 'Extracted method');
    is($res->{path}, '/products/shoes', 'Extracted clean path');
    is($res->{query_string}, 'color=blue&size=10', 'Extracted query string');
    is($res->{protocol}, 'HTTP/2.0', 'Extracted protocol');
    is($res->{status}, 200, 'Extracted status code');
    is($res->{bytes}, 15420, 'Extracted bytes');
    is($res->{referer}, 'https://www.google.com/', 'Extracted referer');
    is($res->{ua_category}, 'Browser', 'Classified desktop Chrome as Browser');
    is($res->{ua_family}, 'Chrome', 'Classified family as Chrome');
}

# 2. Test standard combined log with filename vhost fallback
{
    my $line = '198.51.100.12 - frank [25/Oct/2026:14:25:10 +0000] "POST /api/v1/checkout HTTP/1.1" 502 - "-" "Googlebot/2.1 (+http://www.google.com/bot.html)"';
    my $res = $parser->parse_line($line, file_path => '/var/log/apache2/api.example.com-access.log');
    ok($res, 'Parsed standard combined line');
    is($res->{vhost}, 'api.example.com', 'Derived vhost from filename');
    is($res->{client_ip}, '198.51.100.12', 'Extracted client IP');
    is($res->{method}, 'POST', 'Extracted POST method');
    is($res->{path}, '/api/v1/checkout', 'Extracted path');
    is($res->{status}, 502, 'Extracted 502 status');
    is($res->{bytes}, 0, 'Converted "-" bytes to 0');
    is($res->{referer}, '', 'Converted "-" referer to empty string');
    is($res->{ua_category}, 'Bot', 'Classified Googlebot as Bot');
    is($res->{ua_family}, 'Googlebot', 'Classified family as Googlebot');
}

# 3. Test common log format (no referer/UA) and explicit default_vhost
{
    my $line = '192.0.2.99 - - [25/Oct/2026:15:00:00 +0000] "HEAD /healthz HTTP/1.1" 204 0';
    my $res = $parser->parse_line($line, default_vhost => 'status.example.org');
    ok($res, 'Parsed common log format');
    is($res->{vhost}, 'status.example.org', 'Used explicit default_vhost');
    is($res->{method}, 'HEAD', 'Extracted HEAD method');
    is($res->{status}, 204, 'Extracted 204 status');
}

# 4. Test CLI/API User-Agent classification
{
    my $line = 'blog.example.com:80 10.0.0.5 - - [25/Oct/2026:15:10:00 +0000] "GET /feed.xml HTTP/1.1" 200 4096 "-" "curl/8.5.0"';
    my $res = $parser->parse_line($line);
    is($res->{ua_category}, 'CLI/API', 'Classified curl as CLI/API');
    is($res->{ua_family}, 'curl', 'Classified family as curl');
}

done_testing();
