#!perl -w

# Check FCGI::Buffer correctly sets the Last-Modified header when requested

use strict;
use warnings;
use Test::Most;
use Capture::Tiny ':all';
use DateTime;
# use Test::NoWarnings;	# HTML::Clean has them

BEGIN {
	use_ok('FCGI::Buffer');
}

sub writer {
	my $b = new_ok('FCGI::Buffer');

	ok($b->can_cache() == 1);
	ok($b->is_cached() == 0);
	my $hash = {};
	my $c = CHI->new(driver => 'Memory', datastore => $hash);

	$b->init({cache => $c, cache_key => 'foo'});

	print "Content-type: text/html; charset=ISO-8859-1\n\n";
	print "<HTML><BODY>   Hello World</BODY></HTML>\n";
	ok($b->is_cached() == 0);
}

LAST_MODIFIED: {
	delete $ENV{'REMOTE_ADDR'};
	delete $ENV{'HTTP_USER_AGENT'};
	delete $ENV{'NO_CACHE'};
	delete $ENV{'NO_STORE'};

	my $test_count = 13;

	SKIP: {
		eval {
			require CHI;

			CHI->import();
		};

		SKIP: {
			$test_count = 15;
			if($@) {
				diag('CHI required to test');
				skip 'CHI required to test', 14;
			}

			my ($stdout, $stderr) = capture { writer() };

			ok($stderr eq '');
			ok($stdout !~ /^Content-Encoding: gzip/m);
			ok($stdout !~ /^ETag: "/m);

			my ($headers, $body) = split /\r?\n\r?\n/, $stdout, 2;

			ok($headers =~ /^Last-Modified:\s+(.+)/m);
			my $date = $1;
			ok(defined($date));

			ok($headers =~ /^Content-Length:\s+(\d+)/m);
			my $length = $1;
			ok(defined($length));

			ok($body =~ /^<HTML><BODY>   Hello World<\/BODY><\/HTML>/m);

			ok(length($body) eq $length);

			eval {
				require DateTime::Format::HTTP;

				DateTime::Format::HTTP->import();
			};

			if($@) {
				skip 'DateTime::Format::HTTP required to test everything', 1 if $@;
			} else {
				my $dt = DateTime::Format::HTTP->parse_datetime($date);
				ok($dt <= DateTime->now());
			}
		}
	}
	done_testing($test_count);
}
