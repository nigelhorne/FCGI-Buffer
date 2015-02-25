#!perl -Tw

# Doesn't test anything useful yet, other than handling of empty bodies in the cache

use strict;
use warnings;
use Test::Most tests => 7;
use Storable;
use Capture::Tiny ':all';
# use Test::NoWarnings;	# HTML::Clean has them

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

		skip 'CHI not installed', 4 if $@;

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

			$b->init({ optimise_content => 1, generate_etag => 0, cache => $cache, cache_key => 'xyzzy' });

			print "Content-type: text/html; charset=ISO-8859-1\n\n";
		}

		my ($stdout, $stderr) = capture { test1() };

		my ($headers, $body) = split /\r?\n\r?\n/, $stdout, 2;

		ok(length($body) == 0);
		ok($headers eq 'Content-type: text/html; charset=ISO-8859-1');
		ok($stderr eq '');
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
