package MyLogger;

use strict;
use warnings;

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

sub AUTOLOAD {
	our $AUTOLOAD;
	my $param = $AUTOLOAD;

	unless($param eq 'MyLogger::DESTROY') {
		::diag("Need to define $param");
	}
}

1;
