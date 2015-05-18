#!perl -Tw

# Test what happens when CHI isn't available

use strict;
use warnings;
use Test::Most tests => 8;
use Storable;
use Capture::Tiny ':all';
use CGI::Info;
use Test::NoWarnings;

eval "use Test::Without::Module qw(CHI)";

BEGIN {
	use_ok('FCGI::Buffer');
}

NOCACHED: {
	if ($@) {
		plan skip_all => 'Test::Without::Module required for testing when no CHI is installed';
	} else {
		delete $ENV{'REMOTE_ADDR'};
		delete $ENV{'HTTP_USER_AGENT'};

		delete $ENV{'HTTP_ACCEPT_ENCODING'};
		delete $ENV{'HTTP_TE'};
		delete $ENV{'SERVER_PROTOCOL'};
		delete $ENV{'HTTP_RANGE'};

		sub test1 {
			my $b = new_ok('FCGI::Buffer');

			ok($b->is_cached() == 0);
			ok($b->can_cache() == 1);

			$b->init({
				optimise_content => 1,
				generate_etag => 0,
				cache_key => 'test1',
				logger => MyLogger->new()
			});

			print "Content-type: text/html; charset=ISO-8859-1\n\n";
		}

		my ($stdout, $stderr) = capture { test1() };

		my ($headers, $body) = split /\r?\n\r?\n/, $stdout, 2;

		ok(length($body) == 0);
		ok($headers =~ /Content-type: text\/html; charset=ISO-8859-1/m);
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
