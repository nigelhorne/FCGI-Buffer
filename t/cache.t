#!perl -Tw

use strict;
use warnings;
use Test::Most tests => 116;
use Storable;
use Capture::Tiny ':all';
use CGI::Info;
use CGI::Lingua;
use Test::NoWarnings;
use autodie qw(:all);
use Test::TempDir::Tiny;
use Compress::Zlib;

BEGIN {
	use_ok('FCGI::Buffer');
}

CACHED: {
	delete $ENV{'REMOTE_ADDR'};
	delete $ENV{'HTTP_USER_AGENT'};

	SKIP: {
		eval {
			require CHI;

			CHI->import;
		};

		if($@) {
			diag('CHI required to test caching');
			skip 'CHI not installed', 112;
		} else {
			diag("Using CHI $CHI::VERSION");
		}

		my $cache = CHI->new(driver => 'Memory', datastore => {});

		delete $ENV{'HTTP_ACCEPT_ENCODING'};
		delete $ENV{'HTTP_TE'};
		delete $ENV{'SERVER_PROTOCOL'};
		delete $ENV{'HTTP_RANGE'};

		sub test1 {
			my $b = new_ok('FCGI::Buffer');

			ok($b->is_cached() == 0);
			ok($b->can_cache() == 1);

			$b->init({ optimise_content => 1, generate_etag => 0, cache => $cache, cache_key => 'test1' });

			print "Content-type: text/html; charset=ISO-8859-1\n\n";
		}

		my ($stdout, $stderr) = capture { test1() };

		my ($headers, $body) = split /\r?\n\r?\n/, $stdout, 2;

		ok(length($body) == 0);
		ok($headers =~ /Content-type: text\/html; charset=ISO-8859-1/m);
		ok($stderr eq '');

		$ENV{'GATEWAY_INTERFACE'} = 'CGI/1.1';
		$ENV{'REQUEST_METHOD'} = 'GET';
		$ENV{'QUERY_STRING'} = 'FCGI::Buffer=testing';

		sub test2 {
			my $b = new_ok('FCGI::Buffer');

			ok($b->is_cached() == 0);
			ok($b->can_cache() == 1);

			$b->init({
				optimise_content => 1,
				generate_etag => 0,
				cache => $cache,
				cache_key => 'test2',
				info => new_ok('CGI::Info')
			});

			print "Content-type: text/html; charset=ISO-8859-1\n\n";
		}

		($stdout, $stderr) = capture { test2() };

		($headers, $body) = split /\r?\n\r?\n/, $stdout, 2;

		ok(length($body) == 0);
		ok($headers =~ /Content-type: text\/html; charset=ISO-8859-1/m);
		ok($stderr eq '');

		$ENV{'SERVER_PROTOCOL'} = 'HTTP/1.1';

		sub test3 {
			my $b = new_ok('FCGI::Buffer');

			$b->init({
				cache => $cache,
				cache_key => 'test3',
				info => new_ok('CGI::Info')
			});

			ok($b->is_cached() == 0);
			ok($b->can_cache() == 1);

			print "Content-type: text/html; charset=ISO-8859-1\n\n",
				"<HTML><HEAD></HEAD><BODY>Hello, World</BODY></HTML>\n";
		}

		($stdout, $stderr) = capture { test3() };
		is($stderr, '', 'nothing on STDERR');

		($headers, $body) = split /\r?\n\r?\n/, $stdout, 2;

		ok($headers =~ /Content-type: text\/html; charset=ISO-8859-1/mi);
		ok($headers !~ /^Content-Encoding: gzip/m);
		ok($headers =~ /^ETag:\s+(.+)/m);
		my $etag = $1;
		ok(defined($etag));
		$etag =~ s/\r//;

		$ENV{'HTTP_IF_NONE_MATCH'} = $etag;
		sub test3a {
			my $b = new_ok('FCGI::Buffer');

			$b->init({
				cache => $cache,
				cache_key => 'test3',
				info => new_ok('CGI::Info')
			});

			ok($b->can_cache() == 1);

			print "Content-type: text/html; charset=ISO-8859-1\n\n";

			print "<HTML><HEAD></HEAD><BODY>Hello, World</BODY></HTML>\n";

			ok($b->is_cached() == 1);
		}

		($stdout, $stderr) = capture { test3a() };
		ok($stderr eq '');

		($headers, $body) = split /\r?\n\r?\n/, $stdout, 2;

		ok($headers =~ /^Status: 304 Not Modified/mi);
		ok($headers =~ /Content-type: text\/html; charset=ISO-8859-1/mi);
		ok($headers !~ /^Content-Encoding: gzip/m);
		ok($headers =~ /^ETag:\s+(.+)/m);
		ok($1 eq $etag);

		# ---- gzip in the cache ------
		sub test4 {
			my $b = new_ok('FCGI::Buffer');

			$b->init({
				cache => $cache,
				cache_key => 'test4',
				info => new_ok('CGI::Info')
			});

			ok($b->is_cached() == 0);
			ok($b->can_cache() == 1);

			print "Content-type: text/html; charset=ISO-8859-1\n\n";

			print "<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 4.01 Transitional//EN\n",
				"<HTML><HEAD><TITLE>Hello, world</TITLE></HEAD><BODY><P>The quick brown fox jumped over the lazy dog.</P></BODY></HTML>\n";
		}

		delete $ENV{'HTTP_IF_NONE_MATCH'};
		$ENV{'HTTP_ACCEPT_ENCODING'} = 'gzip';
		($stdout, $stderr) = capture { test4() };
		ok($stderr eq '');

		($headers, $body) = split /\r?\n\r?\n/, $stdout, 2;

		ok($headers =~ /Content-type: text\/html; charset=ISO-8859-1/mi);
		ok($headers =~ /^Content-Encoding: gzip/m);
		ok($headers =~ /^ETag:\s+(.+)/m);
		$etag = $1;
		ok(defined($etag));
		$etag =~ s/\r//;

		ok(Compress::Zlib::memGunzip($body) =~ /<HTML><HEAD><TITLE>Hello, world<\/TITLE><\/HEAD><BODY><P>The quick brown fox jumped over the lazy dog.<\/P><\/BODY><\/HTML>/m);

		$ENV{'HTTP_IF_NONE_MATCH'} = $etag;
		sub test4a {
			my $b = new_ok('FCGI::Buffer');

			$b->init({
				cache => $cache,
				cache_key => 'test4',
				info => new_ok('CGI::Info'),
				logger => MyLogger->new()
			});

			ok($b->can_cache() == 1);

			print "Content-type: text/html; charset=ISO-8859-1\n\n";

			print "<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 4.01 Transitional//EN\n",
				"<HTML><HEAD><TITLE>Hello, world</TITLE></HEAD><BODY><P>The quick brown fox jumped over the lazy dog.</P></BODY></HTML>\n";

			ok($b->is_cached() == 1);
		}

		($stdout, $stderr) = capture { test4a() };
		ok($stderr eq '');

		($headers, $body) = split /\r?\n\r?\n/, $stdout, 2;

		ok($headers =~ /^Status: 304 Not Modified/mi);
		ok($headers =~ /Content-type: text\/html; charset=ISO-8859-1/mi);
		ok($headers =~ /^ETag:\s+(.+)/m);
		ok($1 eq $etag);

		my $tempdir = tempdir();
		delete $ENV{'LANGUAGE'};
		delete $ENV{'LC_ALL'};
		delete $ENV{'LC_MESSAGES'};
		delete $ENV{'LANG'};
		if($^O eq 'MSWin32') {
			$ENV{'IGNORE_WIN32_LOCALE'} = 1;
		}
		$ENV{'HTTP_ACCEPT_LANGUAGE'} = 'en-gb,en;q=0.5';
		my $save_to = {
			directory => $tempdir,
			# directory => '/tmp/njh',	# FIXME
			ttl => '3600',
		};

		# Check if static links have been put in
		delete $ENV{'HTTP_IF_NONE_MATCH'};
		$ENV{'REQUEST_URI'} = '/cgi-bin/test4.cgi?arg1=a&arg2=b';
		$ENV{'QUERY_STRING'} = 'arg1=a&arg2=b';
		delete $ENV{'HTTP_ACCEPT_ENCODING'};

		($stdout, $stderr) = capture { test4a() };
		ok($stderr eq '');

		($headers, $body) = split /\r?\n\r?\n/, $stdout, 2;

		ok($headers =~ /Content-type: text\/html; charset=ISO-8859-1/mi);

		sub test5 {
			my $b = new_ok('FCGI::Buffer');
			my $info = new_ok('CGI::Info');

			$b->init({
				cache => $cache,
				info => $info,
				lingua => new_ok('CGI::Lingua' => [
					supported => ['en'],
					dont_use_ip => 1,
					info => $info,
				]),
				save_to => $save_to
			});

			ok($b->can_cache() == 1);

			print "Content-type: text/html; charset=ISO-8859-1\n\n";

			print "<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 4.01 Transitional//EN\n",
				"<HTML><HEAD><TITLE>Hello, world</TITLE></HEAD>",
				"<BODY><P>The quick brown fox jumped over the lazy dog.</P>",
				'<A HREF="/cgi-bin/test4.cgi?arg1=a&arg2=b">link</a>',
				"</BODY></HTML>\n";
		}

		($stdout, $stderr) = capture { test5() };
		ok($stderr eq '');

		($headers, $body) = split /\r?\n\r?\n/, $stdout, 2;

		like($headers, qr/Content-type: text\/html; charset=ISO-8859-1/mi, 'HTML output');
		like($headers, qr/^ETag:\s+.+/m, 'ETag header is present');
		like($headers, qr/^Expires: /m, 'Expires header is present');

		like($body, qr/\/cgi-bin\/test4.cgi/m, 'Nothing to optimise on first pass');
		ok($headers =~ /^Content-Length:\s+(\d+)/m);
		my $length = $1;
		ok(defined($length));
		ok(length($body) eq $length);

		($stdout, $stderr) = capture { test5() };
		ok($stderr eq '');

		($headers, $body) = split /\r?\n\r?\n/, $stdout, 2;

		ok($headers =~ /Content-type: text\/html; charset=ISO-8859-1/mi);
		ok($headers =~ /^ETag:\s+.+/m);
		ok($headers =~ /^Expires: /m);

		ok($body =~ /"$tempdir\/.+\.html"/m);

		$ENV{'REQUEST_URI'} = '/cgi-bin/test5.cgi?fred=wilma';
		($stdout, $stderr) = capture { test5() };
		ok($stderr eq '');

		($headers, $body) = split /\r?\n\r?\n/, $stdout, 2;

		ok($headers =~ /Content-type: text\/html; charset=ISO-8859-1/mi);
		ok($headers =~ /^ETag:\s+.+/m);
		ok($headers =~ /^Expires: /m);

		ok($body =~ /"$tempdir\/.+\.html"/m);

		# no cache argument to init()
		sub test5a {
			my $b = new_ok('FCGI::Buffer');

			$b->init({
				info => new_ok('CGI::Info'),
				lingua => CGI::Lingua->new(
					supported => ['en'],
					dont_use_ip => 1,
				),
				save_to => $save_to
			});

			ok($b->can_cache() == 1);

			print "Content-type: text/html; charset=ISO-8859-1\n\n";

			print "<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 4.01 Transitional//EN\n",
				"<HTML><HEAD><TITLE>Hello, world</TITLE></HEAD>",
				"<BODY><P>The quick brown fox jumped over the lazy dog.</P>",
				'<A HREF="/cgi-bin/test4.cgi?arg1=a&arg2=b">link</a>',
				"</BODY></HTML>\n";
		}

		($stdout, $stderr) = capture { test5a() };
		ok($stderr eq '');

		($headers, $body) = split /\r?\n\r?\n/, $stdout, 2;

		ok($headers =~ /Content-type: text\/html; charset=ISO-8859-1/mi);
		ok($headers =~ /^ETag:\s+.+/m);
		ok($headers =~ /^Expires: /m);

		ok($body =~ /"$tempdir\/.+\.html"/m);
		ok($body !~ /"\?arg1=a/m);

		ok($headers =~ /^Content-Length:\s+(\d+)/m);
		$length = $1;
		ok(defined($length));
		ok(length($body) eq $length);

		# Calling self
		$ENV{'REQUEST_URI'} = '/cgi-bin/test4.cgi?arg3=c';
		sub test5b {
			my $b = new_ok('FCGI::Buffer');
			my $info = new_ok('CGI::Info');

			$b->init({
				info => $info,
				lingua => CGI::Lingua->new(
					supported => ['en'],
					dont_use_ip => 1,
					info => $info,
				),
				save_to => $save_to,
				logger => MyLogger->new()
			});

			ok($b->can_cache() == 1);

			print "Content-type: text/html; charset=ISO-8859-1\n\n";

			print "<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 4.01 Transitional//EN\n",
				"<HTML><HEAD><TITLE>Hello, world</TITLE></HEAD>",
				"<BODY><P>The quick brown fox jumped over the lazy dog.</P>",
				'<A HREF="?arg1=a&arg2=b">link</a>',
				'<A HREF="?arg1=a&arg2=b">link</a>',
				"</BODY></HTML>\n";
		}

		($stdout, $stderr) = capture { test5b() };
		ok($stderr eq '');

		($headers, $body) = split /\r?\n\r?\n/, $stdout, 2;

		ok($headers =~ /Content-type: text\/html; charset=ISO-8859-1/mi);
		ok($headers =~ /^ETag:\s+.+/m);
		ok($headers =~ /^Expires: /m);
		ok($headers !~ /^Content-Encoding: gzip/m);

		ok($body =~ /"$tempdir\/.+\.html"/m);
		ok($body !~ /"\?arg1=a/m);

		ok($headers =~ /^Content-Length:\s+(\d+)/m);
		$length = $1;
		ok(defined($length));
		ok(length($body) eq $length);

		ok(-r "$tempdir/fcgi.buffer.sql");
		ok(-d "$tempdir/web/English");
	}
}

# On some platforms it's failing - find out why
package MyLogger;

sub new {
	my ($proto, %args) = @_;

	my $class = ref($proto) || $proto;

	return bless { }, $class;
}

sub info {
	my $self = shift;
	my $message = shift;

	if($ENV{'TEST_VERBOSE'}) {
		::diag($message);
	}
}

sub debug {
	my $self = shift;
	my $message = shift;

	if($ENV{'TEST_VERBOSE'}) {
		::diag($message);
	}
}

sub AUTOLOAD {
	our $AUTOLOAD;
	my $param = $AUTOLOAD;

	unless($param eq 'MyLogger::DESTROY') {
		::diag("Need to define $param");
	}
}
