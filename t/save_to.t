#!perl -w

# Tests for the save_to feature: the static pages that it writes and the
# links that it rewrites to point to them

use strict;
use warnings;
use Test::Most tests => 17;
use Test::Needs 'CHI', 'DBD::SQLite';
use Capture::Tiny ':all';
use CGI::Info;
use File::Spec;
use File::Temp qw(tempdir);
use Test::NoWarnings;

BEGIN {
	use_ok('FCGI::Buffer');
}

# A minimal stand-in for CGI::Lingua
package My::Lingua;

sub new { my ($class, $language) = @_; return bless { language => $language }, $class }
sub language { return $_[0]->{language} }

package main;

delete @ENV{qw(
	HTTP_ACCEPT_ENCODING HTTP_TE SERVER_PROTOCOL HTTP_RANGE HTTP_USER_AGENT
	REMOTE_ADDR HTTP_IF_NONE_MATCH HTTP_IF_MODIFIED_SINCE HTTP_COOKIE PATH_INFO
	C_DOCUMENT_ROOT HTTP_CACHE_CONTROL
)};
$ENV{'GATEWAY_INTERFACE'} = 'CGI/1.1';
$ENV{'REQUEST_METHOD'} = 'GET';
$ENV{'SCRIPT_NAME'} = '/cgi-bin/page.fcgi';

# Run one request through FCGI::Buffer.  Returns the body and stderr
sub request {
	my %args = @_;

	my %env = %{$args{'env'} || {}};
	my $request_uri = $args{'uri'};
	my $query_string = ($request_uri =~ /\?(.*)$/) ? $1 : '';

	local $ENV{'REQUEST_URI'} = $request_uri;
	local $ENV{'QUERY_STRING'} = $query_string;
	local @ENV{keys %env} = values %env;

	my ($stdout, $stderr) = capture {
		my $b = FCGI::Buffer->new();
		my $info = CGI::Info->new();
		$b->init({
			info => $info,
			cache => $args{'cache'},
			save_to => $args{'save_to'},
			($args{'no_lingua'} ? () : (lingua => $args{'lingua'} || My::Lingua->new('English'))),
			($args{'optimise_content'} ? (optimise_content => $args{'optimise_content'}) : ()),
		});
		print "Content-type: text/html\n\n",
			'<HTML><HEAD><TITLE>t</TITLE></HEAD><BODY>', $args{'html'}, "</BODY></HTML>\n";
	};
	my ($headers, $body) = split /\r?\n\r?\n/, $stdout, 2;
	return ($body, $stderr);
}

# A new document root, save_to area and cache for each scenario
sub setup {
	my %args = @_;

	my $docroot = tempdir(CLEANUP => 1);
	my $dir = $args{'outside_docroot'} ? tempdir(CLEANUP => 1) : File::Spec->catdir($docroot, 'static');
	$ENV{'DOCUMENT_ROOT'} = $docroot;
	return (
		$docroot,
		{ directory => $dir, ttl => 3600, create_table => 1 },
		CHI->new(driver => 'Memory', datastore => {})
	);
}

sub slurp {
	my $file = shift;
	open(my $fin, '<', $file) or return;
	local $/;
	my $rc = <$fin>;
	close $fin;
	return $rc;
}

# Turn a URL path from a rewritten link back into the file it should serve
sub url_to_file {
	my ($docroot, $url) = @_;
	my @segments = map { my $s = $_; $s =~ s/%([0-9A-F]{2})/chr(hex($1))/ge; $s } split(/\//, $url);
	shift @segments;	# Leading empty segment
	return File::Spec->catfile($docroot, @segments);
}

subtest 'links to self in a static page point to its URL, not its filename' => sub {
	my ($docroot, $save_to, $cache) = setup();

	my ($body, $stderr) = request(
		uri => '/cgi-bin/page.fcgi?a=1',
		html => '<a href="/cgi-bin/page.fcgi?a=1">self</a><a href="?b=2">other</a>',
		cache => $cache,
		save_to => $save_to,
	);
	is($stderr, '', 'no errors');

	my $file = File::Spec->catfile($docroot, 'static', 'web', 'English', 'page.fcgi', 'a=1.html');
	ok(-f $file, 'static page is written') or return;
	my $html = slurp($file);
	like($html, qr{<a href="/static/web/English/page\.fcgi/a=1\.html">self</a>}, 'self link points to the static URL');
	unlike($html, qr/\Q$docroot\E/, 'the document root is not in the static page');
	like($html, qr{<a href="/cgi-bin/page\.fcgi\?b=2">other</a>}, 'relative links are made absolute');
};

subtest 'a request with no arguments is not saved as a hidden .html file' => sub {
	my ($docroot, $save_to, $cache) = setup();

	my (undef, $stderr) = request(
		uri => '/cgi-bin/page.fcgi',
		html => 'home page',
		cache => $cache,
		save_to => $save_to,
	);
	is($stderr, '', 'no errors');

	my $sdir = File::Spec->catdir($docroot, 'static', 'web', 'English', 'page.fcgi');
	ok(!-e File::Spec->catfile($sdir, '.html'), 'no .html file');
	ok(-f File::Spec->catfile($sdir, 'index.html'), 'index.html is written');

	my ($body) = request(
		uri => '/cgi-bin/page.fcgi?a=1',
		html => '<a href="/cgi-bin/page.fcgi">home</a>',
		cache => $cache,
		save_to => $save_to,
	);
	like($body, qr{<a href="/static/web/English/page\.fcgi/index\.html">home</a>}, 'link to the home page uses index.html');
};

subtest 'a document root with a trailing slash still gives an absolute URL' => sub {
	my ($docroot, $save_to, $cache) = setup();
	local $ENV{'DOCUMENT_ROOT'} = "$docroot/";

	request(uri => '/cgi-bin/page.fcgi?a=1', html => 'a', cache => $cache, save_to => $save_to);
	my ($body) = request(
		uri => '/cgi-bin/page.fcgi?b=2',
		html => '<a href="/cgi-bin/page.fcgi?a=1">a</a>',
		cache => $cache,
		save_to => $save_to,
	);
	like($body, qr{<a href="/static/web/English/page\.fcgi/a=1\.html">a</a>}, 'URL starts with a /');
};

subtest 'save_to is turned off when it is outside of the document root' => sub {
	my ($docroot, $save_to, $cache) = setup(outside_docroot => 1);

	my @warnings;
	local $SIG{__WARN__} = sub { push @warnings, @_ };

	request(uri => '/cgi-bin/page.fcgi?a=1', html => 'a', cache => $cache, save_to => $save_to);
	ok(!-e File::Spec->catfile($save_to->{'directory'}, 'web', 'English', 'page.fcgi', 'a=1.html'), 'no page which nothing could link to');
	is(scalar(@warnings), 1, 'a warning is given');
	like($warnings[0], qr/not under the document root/, 'saying why');

	my ($body, $stderr) = request(
		uri => '/cgi-bin/page.fcgi?b=2',
		html => '<a href="/cgi-bin/page.fcgi?a=1">a</a>',
		cache => $cache,
		save_to => $save_to,
	);
	is($stderr, '', 'no errors');
	is(scalar(@warnings), 1, 'the warning is only given once');
	like($body, qr{<a href="/cgi-bin/page\.fcgi\?a=1">a</a>}, 'link still points to the CGI script');
};

subtest 'unsafe characters in arguments give a working, escaped URL' => sub {
	my ($docroot, $save_to, $cache) = setup();

	foreach my $test(
		[ 'q=a%5Cb%26c%25d', 'backslash' ],
		[ 'q=caf%C3%A9%20%2Fx', 'utf8' ],
	) {
		my ($query, $html) = @{$test};
		request(uri => "/cgi-bin/page.fcgi?$query", html => $html, cache => $cache, save_to => $save_to);
		my ($body) = request(
			uri => '/cgi-bin/page.fcgi?x=1',
			html => qq{<a href="/cgi-bin/page.fcgi?$query">$html</a>},
			cache => $cache,
			save_to => $save_to,
		);
		ok($body =~ m{<a href="(/static/[^"]+\.html)">$html</a>}, "$html: link is rewritten") or next;
		my $url = $1;
		unlike($url, qr/[#?\\&\s]|%(?![0-9A-F]{2})/, "$html: URL has no unescaped characters");
		my $file = url_to_file($docroot, $url);
		ok(-f $file, "$html: the URL leads to the static page");
		like(slurp($file), qr/\Q$html\E/, "$html: and it is the right page");
	}
};

subtest 'arguments differing only by spaces get different static pages' => sub {
	my ($docroot, $save_to, $cache) = setup();

	request(uri => '/cgi-bin/page.fcgi?city=New%20York', html => 'with space', cache => $cache, save_to => $save_to);
	request(uri => '/cgi-bin/page.fcgi?city=NewYork', html => 'without space', cache => $cache, save_to => $save_to);

	my $sdir = File::Spec->catdir($docroot, 'static', 'web', 'English', 'page.fcgi');
	opendir(my $dh, $sdir) or die "$sdir: $!";
	my @files = grep { /\.html$/ } readdir($dh);
	closedir($dh);
	is(scalar(@files), 2, 'two static pages') or diag(join(', ', @files));
};

subtest 'optimise_content does not empty links to the script itself' => sub {
	local $ENV{'SERVER_NAME'} = 'www.example.com';
	local $ENV{'HTTP_HOST'} = 'www.example.com';

	my ($body, $stderr) = request(
		uri => '/cgi-bin/page.fcgi?a=1',
		optimise_content => 1,
		html => '<a href="/cgi-bin/page.fcgi">home</a> <a href="/cgi-bin/page.fcgi?b=2" class="c">b</a> ' .
			'<a href="http://www.example.com.evil.org/x">evil</a> <a href="http://www.example.com/y">y</a>',
	);
	is($stderr, '', 'no errors');
	like($body, qr{<a href="/cgi-bin/page\.fcgi">home</a>}, 'link to script with no arguments is untouched');
	like($body, qr{<a href="\?b=2" class="c">b</a>}, 'link to script with arguments is shortened');
	like($body, qr{<a href="//www\.example\.com\.evil\.org/x">}, 'other site with our name as a prefix is not made local');
	like($body, qr{<a href="/y">}, 'link to our own site is made local');
};

subtest 'regex metacharacters in URLs' => sub {
	my ($docroot, $save_to, $cache) = setup();

	my (undef, $stderr) = request(uri => '/cgi-bin/page.fcgi?a=(1', html => 'paren', cache => $cache, save_to => $save_to);
	is($stderr, '', 'a ( in the URL does not die');

	request(uri => '/cgi-bin/page.fcgi?q=a+b', html => 'plus', cache => $cache, save_to => $save_to);
	my $body;
	($body, $stderr) = request(
		uri => '/cgi-bin/page.fcgi?x=1',
		html => '<a href="/cgi-bin/page.fcgi?q=a+b">plus</a><a href="/cgi-bin/page.fcgi?q=aab">aab</a>',
		cache => $cache,
		save_to => $save_to,
	);
	is($stderr, '', 'no errors');
	like($body, qr{<a href="/static/[^"]+\.html">plus</a>}, 'link with a + is rewritten');
	like($body, qr{<a href="/cgi-bin/page\.fcgi\?q=aab">aab</a>}, 'a different link which would match a+b as a regex is not');
};

subtest 'links with ; and &amp; are found' => sub {
	my ($docroot, $save_to, $cache) = setup();

	request(uri => '/cgi-bin/page.fcgi?a=1;b=2', html => 'semi', cache => $cache, save_to => $save_to);
	request(uri => '/cgi-bin/page.fcgi?c=1&d=2', html => 'amp', cache => $cache, save_to => $save_to);
	my ($body) = request(
		uri => '/cgi-bin/page.fcgi?x=1',
		html => '<a href="/cgi-bin/page.fcgi?a=1;b=2">semi</a><a href="?c=1&amp;d=2">amp</a>',
		cache => $cache,
		save_to => $save_to,
	);
	like($body, qr{<a href="/static/[^"]+\.html">semi</a>}, 'link with ; is rewritten');
	like($body, qr{<a href="/static/[^"]+\.html">amp</a>}, 'link with &amp; is rewritten');
};

subtest 'languages with punctuation' => sub {
	my ($docroot, $save_to, $cache) = setup();
	my $lingua = My::Lingua->new('English (United Kingdom)');

	request(uri => '/cgi-bin/page.fcgi?a=1', html => 'a', cache => $cache, save_to => $save_to, lingua => $lingua);
	my ($body, $stderr) = request(
		uri => '/cgi-bin/page.fcgi?b=2',
		html => '<a href="/cgi-bin/page.fcgi?a=1">a</a>',
		cache => $cache,
		save_to => $save_to,
		lingua => $lingua,
	);
	is($stderr, '', 'no errors');
	ok($body =~ m{<a href="(/static/[^"]+\.html)">a</a>}, 'link is rewritten') or return;
	ok(-f url_to_file($docroot, $1), 'the URL leads to the static page');
};

subtest 'quotes in the URL' => sub {
	my ($docroot, $save_to, $cache) = setup();

	my (undef, $stderr) = request(uri => "/cgi-bin/page.fcgi?name=O'Brien", html => 'quote', cache => $cache, save_to => $save_to);
	is($stderr, '', 'no errors');
	my ($body) = request(
		uri => '/cgi-bin/page.fcgi?x=1',
		html => q{<a href="/cgi-bin/page.fcgi?name=O'Brien">quote</a>},
		cache => $cache,
		save_to => $save_to,
	);
	like($body, qr{<a href="/static/[^"]+\.html">quote</a>}, 'the page was recorded and the link rewritten');
};

subtest 'pages that depend on cookies are not saved' => sub {
	my ($docroot, $save_to, $cache) = setup();
	my $sdir = File::Spec->catdir($docroot, 'static', 'web', 'English', 'page.fcgi');

	request(
		uri => '/cgi-bin/page.fcgi?a=1',
		html => 'Logged in as Fred',
		cache => $cache,
		save_to => $save_to,
		env => { HTTP_COOKIE => 'session=fred' },
	);
	ok(!-e File::Spec->catfile($sdir, 'a=1.html'), 'no static page when there is a session cookie');

	request(
		uri => '/cgi-bin/page.fcgi?b=2',
		html => 'Anyone',
		cache => $cache,
		save_to => $save_to,
		env => { HTTP_COOKIE => '__utma=1; __utmz=2' },
	);
	ok(-f File::Spec->catfile($sdir, 'b=2.html'), 'analytics cookies do not stop the page being saved');

	request(
		uri => '/cgi-bin/page.fcgi?c=3',
		html => 'Anyone',
		cache => $cache,
		save_to => $save_to,
		env => { HTTP_COOKIE => 'csrf_token=1:2:3' },
	);
	ok(-f File::Spec->catfile($sdir, 'c=3.html'), 'a csrf_token cookie does not stop the page being saved');

	request(
		uri => '/cgi-bin/page.fcgi?d=4',
		html => 'Logged in as Fred',
		cache => $cache,
		save_to => $save_to,
		env => { HTTP_COOKIE => 'csrf_token=1:2:3; session=fred' },
	);
	ok(!-e File::Spec->catfile($sdir, 'd=4.html'), 'a csrf_token cookie does not hide a session cookie');
};

subtest 'a csrf_token cookie is not part of the cache key' => sub {
	my (undef, undef, $cache) = setup();

	foreach my $token('1:2:3', '4:5:6') {
		request(uri => '/cgi-bin/page.fcgi?a=1', html => 'Anyone', cache => $cache, env => { HTTP_COOKIE => "csrf_token=$token" });
	}
	is(scalar($cache->get_keys()), 1, 'clients with different tokens share one entry');
};

subtest 'save_to works without a lingua object' => sub {
	my ($docroot, $save_to, $cache) = setup();

	my (undef, $stderr) = request(uri => '/cgi-bin/page.fcgi?a=1', html => 'a', cache => $cache, save_to => $save_to, no_lingua => 1);
	is($stderr, '', 'no errors');
	ok(-f File::Spec->catfile($docroot, 'static', 'web', 'default', 'page.fcgi', 'a=1.html'), 'static page is written');
	my $body;
	($body, $stderr) = request(
		uri => '/cgi-bin/page.fcgi?b=2',
		html => '<a href="/cgi-bin/page.fcgi?a=1">a</a>',
		cache => $cache,
		save_to => $save_to,
		no_lingua => 1,
	);
	is($stderr, '', 'no errors');
	like($body, qr{<a href="/static/web/default/page\.fcgi/a=1\.html">a</a>}, 'link is rewritten');
};

subtest 'PATH_INFO is part of the cache key' => sub {
	my ($docroot, $save_to, $cache) = setup();

	request(uri => '/cgi-bin/page.fcgi/a', html => 'page a', cache => $cache, env => { PATH_INFO => '/a' });

	local $ENV{'PATH_INFO'} = '/b';
	local $ENV{'REQUEST_URI'} = '/cgi-bin/page.fcgi/b';
	local $ENV{'QUERY_STRING'} = '';
	my $is_cached;
	capture {
		my $b = FCGI::Buffer->new();
		$b->init({ info => CGI::Info->new(), cache => $cache });
		$is_cached = $b->is_cached();
	};
	ok(!$is_cached, '/b is not served from the cache entry for /a');
};
