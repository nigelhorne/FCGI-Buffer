#!perl -Tw

# FIXME:  create the SQLite database, and remove when done also remove static pages

use strict;
use warnings;
use Test::Most tests => 74;
use Storable;
use Capture::Tiny ':all';
use CGI::Info;
use Test::NoWarnings;
use autodie qw(:all);
use Test::TempDir::Tiny;

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

		skip 'CHI not installed', 50 if $@;

		diag("Using CHI $CHI::VERSION");

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

			$b->init({
				cache => $cache,
				info => new_ok('CGI::Info'),
				save_to => $save_to
			});

			ok($b->can_cache() == 1);

			print "Content-type: text/html; charset=ISO-8859-1\n\n";

			print "<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 4.01 Transitional//EN\n",
				"<HTML><HEAD><TITLE>Hello, world</TITLE></HEAD>",
				"<BODY><P>The quick brown fox jumped over the lazy dog.</P>",
				'<A HREF="/cgi-bin/test4.cgi?arg1=a&arg2=b">link</a>',
				"</BODY></HTML>\n";

			ok($b->can_cache() == 1);
		}

		($stdout, $stderr) = capture { test5() };
		ok($stderr eq '');

		($headers, $body) = split /\r?\n\r?\n/, $stdout, 2;

		ok($headers =~ /Content-type: text\/html; charset=ISO-8859-1/mi);
		ok($headers =~ /^ETag:\s+.+/m);
		ok($body =~ /\/cgi-bin\/test4.cgi/m);

		($stdout, $stderr) = capture { test5() };
		ok($stderr eq '');

		($headers, $body) = split /\r?\n\r?\n/, $stdout, 2;

		ok($headers =~ /Content-type: text\/html; charset=ISO-8859-1/mi);
		ok($headers =~ /^ETag:\s+.+/m);
		ok($body =~ /"$tempdir\/.+\.html"/m);
	}
}

# On some platforms it's failing - find out why
package MyLogger;

sub new {
	my ($proto, %args) = @_;

	my $class = ref($proto) || $proto;

	return bless { }, $class;
}

sub debug {
	my $self = shift;
	my $message = shift;

	if($ENV{'TEST_VERBOSE'}) {
		::diag($message);
	}
}
