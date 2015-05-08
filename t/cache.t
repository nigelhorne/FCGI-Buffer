#!perl -Tw

# Doesn't test much useful yet

use strict;
use warnings;
use Test::Most tests => 52;
use Storable;
use Capture::Tiny ':all';
use CGI::Info;
use Test::NoWarnings;

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

		skip 'CHI not installed', 11 if $@;

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
		ok($headers eq 'Content-type: text/html; charset=ISO-8859-1');
		ok($stderr eq '');

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
		ok($headers eq 'Content-type: text/html; charset=ISO-8859-1');
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

			print "Content-type: text/html; charset=ISO-8859-1\n\n";

			print "<HTML><HEAD></HEAD><BODY>Hello, World</BODY></HTML>\n";
		}

		($stdout, $stderr) = capture { test3() };
		ok($stderr eq '');

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

			print "<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 4.01 Transitional//EN\n";
			print "<HTML><HEAD><TITLE>Hello, world</TITLE></HEAD><BODY><P>The quick brown fox jumped over the lazy dog.</P></BODY></HTML>\n";
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

			print "<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 4.01 Transitional//EN\n";
			print "<HTML><HEAD><TITLE>Hello, world</TITLE></HEAD><BODY><P>The quick brown fox jumped over the lazy dog.</P></BODY></HTML>\n";

			ok($b->is_cached() == 1);
		}

		($stdout, $stderr) = capture { test4a() };
		ok($stderr eq '');

		($headers, $body) = split /\r?\n\r?\n/, $stdout, 2;

		ok($headers =~ /^Status: 304 Not Modified/mi);
		ok($headers =~ /Content-type: text\/html; charset=ISO-8859-1/mi);
		ok($headers =~ /^ETag:\s+(.+)/m);
		ok($1 eq $etag);
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

	# Enable this for debugging
	# ::diag($message);
}
