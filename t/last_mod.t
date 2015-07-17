#!perl -w

# Check FCGI::Buffer correctly sets the Last-Modified header when requested

use strict;
use warnings;
use Test::Most;
use Capture::Tiny ':all';
use DateTime;
use HTTP::Date;
# use Test::NoWarnings;	# HTML::Clean has them

BEGIN {
	use_ok('FCGI::Buffer');
}

my $hash = {};
my $test_run = 0;

sub writer {
	my $b = new_ok('FCGI::Buffer');

	ok($b->can_cache() == 1);
	ok($b->is_cached() == 0);

	my $c = CHI->new(driver => 'Memory', datastore => $hash);

	$b->init({cache => $c, cache_key => 'foo', logger => MyLogger->new()});
	ok($b->is_cached() == ($test_run >= 1));
	$test_run++;

	unless($b->is_cached()) {
		print "Content-type: text/html; charset=ISO-8859-1\n\n";
		print "<HTML><BODY>   Hello World</BODY></HTML>\n";
	}

}

LAST_MODIFIED: {
	delete $ENV{'REMOTE_ADDR'};
	delete $ENV{'HTTP_USER_AGENT'};
	delete $ENV{'NO_CACHE'};
	delete $ENV{'NO_STORE'};
	$ENV{'SERVER_PROTOCOL'} = 'HTTP/1.1';

	my $test_count = 27;

	SKIP: {
		eval {
			require CHI;

			CHI->import();
		};

		SKIP: {
			$test_count = 29;
			if($@) {
				diag('CHI required to test');
				skip 'CHI required to test', 28;
			}

			my ($stdout, $stderr) = capture { writer() };

			ok($stderr eq '');
			ok($stdout !~ /^Content-Encoding: gzip/m);
			ok($stdout =~ /^ETag: "/m);

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
			$ENV{'HTTP_IF_MODIFIED_SINCE'} = 'Mon, 13 Jul 2015 15:09:08 GMT';
			($stdout, $stderr) = capture { writer() };

			ok($stderr eq '');
			($headers, $body) = split /\r?\n\r?\n/, $stdout, 2;
			ok($headers !~ /^Status: 304 Not Modified/mi);

			ok($body ne '');

			$ENV{'HTTP_IF_MODIFIED_SINCE'} = DateTime->now();
			($stdout, $stderr) = capture { writer() };

			ok($stderr eq '');
			($headers, $body) = split /\r?\n\r?\n/, $stdout, 2;
			ok($headers =~ /^Status: 304 Not Modified/mi);
			ok($body eq '');
		}
	}
	done_testing($test_count);
}

package MyLogger;

sub new {
	my ($proto, %args) = @_;

	my $class = ref($proto) || $proto;

	return bless { }, $class;
}

sub info {
	my $self = shift;
	my $message = shift;

	::diag($message);
}

sub trace {
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
