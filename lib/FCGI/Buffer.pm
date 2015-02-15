package FCGI::Buffer;

use strict;
use warnings;

use Digest::MD5;
use IO::String;
use CGI::Info;
use Carp;
use HTTP::Date;

# TODO: Encapsulate the data

=head1 NAME

FCGI::Buffer - Verify and Optimise FCGI Output

=head1 VERSION

Version 0.02

=cut

our $VERSION = '0.02';

=head1 SYNOPSIS

FCGI::Buffer verifies the HTML that you produce by passing it through
C<HTML::Lint>.

FCGI::Buffer optimises FCGI programs by compressing output to speed up
the transmission and by nearly seamlessly making use of client and
server caches.

To make use of client caches, that is to say to reduce needless calls
to your server asking for the same data:

    use FCGI;
    use FCGI::Buffer;
    # ...
    my $request = FCGI::Request();
    while($request->FCGI::Accept() >= 0) {
        my $buffer = FCGI::Buffer->new();
        $buffer->init(
                optimise_content => 1,
                lint_content => 0,
        );
	# ...
    }

To also make use of server caches, that is to say to save regenerating
output when different clients ask you for the same data, you will need
to create a cache.
But that's simple:

    use FCGI;
    use CHI;
    use FCGI::Buffer;

    # ...
    my $request = FCGI::Request();
    while($request->FCGI::Accept() >= 0) {
        my $buffer = FCGI::Buffer->new();
        $buffer->init(
	    optimise_content => 1,
	    lint_content => 0,
	    cache => CHI->new(driver => 'File')
        );
	if($buffer->is_cached()) {
	    # Nothing has changed - use the version in the cache
	    $request->Finish();
	    next;
	# ...
    }

If you get errors about Wide characters in print it means that you've
forgotten to emit pure HTML on non-ascii characters.
See L<HTML::Entities>.
As a hack work around you could also remove accents and the like by using
L<Text::Unidecode>,
which works well but isn't really what you want.

=head1 SUBROUTINES/METHODS

=cut

use constant MIN_GZIP_LEN => 32;

=head2 new

Create an FCGI::Buffer object.  Do one of these for each FCGI::Accept.

=cut

# FIXME: Call init() on any arguments that are given
sub new {
	my $proto = shift;
	my $class = ref($proto) || $proto;

	my $buf = IO::String->new();
	my $old_buf = select($buf);

	my $rc = {
		buf => $buf,
		old_buf => $old_buf
	};
	$rc->{generate_etag} = 1;
	$rc->{generate_304} = 1;
	$rc->{generate_last_modified} = 1;
	$rc->{compress_content} = 1;
	$rc->{optimise_content} = 0;
	$rc->{lint_content} = 0;
	$rc->{o} = ();

	return bless $rc, $class;
}

sub DESTROY {
	return if ${^GLOBAL_PHASE} eq 'DESTRUCT';	# >= 5.14.0 only
	my $self = shift;

	if($self->{logger}) {
		# This will cause everything to get flushed and prevent
		# outputs to the logger.  We need to do that now since
		# if we leave it to Perl to delete later we may get
		# a mesage that Log4Perl::init() hasn't been called
		# $self->{logger} = undef;
	}
	select($self->{old_buf});
	if(!defined($self->{buf})) {
		return;
	}
	my $pos = $self->{buf}->getpos;
	$self->{buf}->setpos(0);
	my $buf;
	read($self->{buf}, $buf, $pos);
	my $headers;
	($headers, $self->{body}) = split /\r?\n\r?\n/, $buf, 2;

	unless($headers || $self->is_cached()) {
		# There was no output
		return;
	}
	if($ENV{'REQUEST_METHOD'} && ($ENV{'REQUEST_METHOD'} eq 'HEAD')) {
		$self->{send_body} = 0;
	} else {
		$self->{send_body} = 1;
	}

	if($headers) {
		foreach my $header (split(/\r?\n/, $headers)) {
			my ($header_name, $header_value) = split /\:\s*/, $header, 2;
			if (lc($header_name) eq 'content-type') {
				my @content_type;
				@content_type = split /\//, $header_value, 2;
				$self->{content_type} = \@content_type;
				last;
			}
		}
	}

	if(defined($self->{body}) && ($self->{body} eq '')) {
		# E.g. if header of Location is given with no body, for
		#	redirection
		$self->{body} = undef;
		if($self->{cache}) {
			# Don't try to retrieve it below from the cache
			$self->{send_body} = 0;
		}
	} elsif(defined($self->{content_type})) {
		my @content_type = @{$self->{content_type}};
		if(defined($content_type[0]) && (lc($content_type[0]) eq 'text') && (lc($content_type[1]) =~ /^html/) && defined($self->{body})) {
			if($self->{optimise_content}) {
				# require HTML::Clean;
				require HTML::Packer;	# Overkill using HTML::Clean and HTML::Packer...

				my $oldlength = length($self->{body});
				my $newlength;

				while(1) {
					$self->{body} = $self->_optimise_content();
					$newlength = length($self->{body});
					last if ($newlength >= $oldlength);
					$oldlength = $newlength;
				}

				# If we're on http://www.example.com and have a link
				# to http://www.example.com/foo/bar.htm, change the
				# link to /foo.bar.htm - there's no need to include
				# the site name in the link
				unless(defined($self->{info})) {
					if($self->{cache}) {
						$self->{info} = CGI::Info->new({ cache => $self->{cache} });
					} else {
						$self->{info} = CGI::Info->new();
					}
				}

				my $href = $self->{info}->host_name();
				my $protocol = $self->{info}->protocol();

				unless($protocol) {
					$protocol = 'http';
				}

				$self->{body} =~ s/<a\s+?href="$protocol:\/\/$href"/<a href="\/"/gim;
				$self->{body} =~ s/<a\s+?href="$protocol:\/\/$href/<a href="/gim;

				# TODO use URI->path_segments to change links in
				# /aa/bb/cc/dd.htm which point to /aa/bb/ff.htm to
				# ../ff.htm

				# TODO: <img border=0 src=...>
				$self->{body} =~ s/<img\s+?src="$protocol:\/\/$href"/<img src="\/"/gim;
				$self->{body} =~ s/<img\s+?src="$protocol:\/\/$href/<img src="/gim;

				# Don't use HTML::Clean because of RT402
				# my $h = new HTML::Clean(\$self->{body});
				# # $h->compat();
				# $h->strip();
				# my $ref = $h->data();

				# Don't always do javascript 'best' since it's confused
				# by the common <!-- HIDE technique.
				# See https://github.com/nevesenin/javascript-packer-perl/issues/1#issuecomment-4356790
				my $options = {
					remove_comments => 1,
					remove_newlines => 0,
					do_stylesheet => 'minify'
				};
				if($self->{optimise_content} >= 2) {
					$options->{do_javascript} = 'best';
					$self->{body} =~ s/(<script.*?>)\s*<!--/$1/gi;
					$self->{body} =~ s/\/\/-->\s*<\/script>/<\/script>/gi;
					$self->{body} =~ s/(<script.*?>)\s+/$1/gi;
				}
				$self->{body} = HTML::Packer->init()->minify(\$self->{body}, $options);
				if($self->{optimise_content} >= 2) {
					# Change document.write("a"); document.write("b")
					# into document.write("a"+"b");
					while(1) {
						$self->{body} =~ s/<script\s*?type\s*?=\s*?"text\/javascript"\s*?>(.*?)document\.write\((.+?)\);\s*?document\.write\((.+?)\)/<script type="text\/JavaScript">${1}document.write($2+$3)/igs;
						$newlength = length($self->{body});
						last if ($newlength >= $oldlength);
						$oldlength = $newlength;
					}
				}
			}
			if($self->{lint_content}) {
				require HTML::Lint;
				HTML::Lint->import;

				my $lint = HTML::Lint->new();
				$lint->parse($self->{body});

				if($lint->errors) {
					$headers = 'Status: 500 Internal Server Error';
					@{$self->{o}} = ('Content-type: text/plain');
					$self->{body} = '';
					foreach my $error ($lint->errors) {
						my $errtext = $error->where() . ': ' . $error->errtext() . "\n";
						warn($errtext);
						$self->{body} .= $errtext;
					}
				}
			}
		}
	}

	$self->{status} = 200;

	if(defined($headers) && ($headers =~ /^Status: (\d+)/m)) {
		$self->{status} = $1;
	}

	# Generate the eTag before compressing, since the compressed data
	# includes the mtime field which changes thus causing a different
	# Etag to be generated
	my $encode_loaded;
	if($ENV{'SERVER_PROTOCOL'} &&
	  ($ENV{'SERVER_PROTOCOL'} eq 'HTTP/1.1') &&
	  $self->{generate_etag} && defined($self->{body})) {
		# encode to avoid "Wide character in subroutine entry"
		require Encode;
		$encode_loaded = 1;
		$self->{etag} = '"' . Digest::MD5->new->add(Encode::encode_utf8($self->{body}))->hexdigest() . '"';
		push @{$self->{o}}, "ETag: $self->{etag}";
		if($ENV{'HTTP_IF_NONE_MATCH'} && $self->{generate_304} && ($self->{status} == 200)) {
			if($self->{logger}) {
				$self->{logger}->debug("Compare $ENV{HTTP_IF_NONE_MATCH} with $self->{etag}");
			}
			if($self->{etag}) {
				push @{$self->{o}}, "Status: 304 Not Modified";
				$self->{send_body} = 0;
				$self->{status} = 304;
				if($self->{logger}) {
					$self->{logger}->debug('Set status to 304');
				}
			}
		}
	}

	my $encoding = $self->_should_gzip();
	my $unzipped_body = $self->{body};

	if((length($encoding) > 0) && defined($self->{body})) {
		my $range = $ENV{'Range'} ? $ENV{'Range'} : $ENV{'HTTP_RANGE'};
		if($range && !$self->{cache}) {
			# TODO: Partials
			if($range =~ /^bytes=(\d*)-(\d*)/) {
				if($1 && $2) {
					$self->{body} = substr($self->{body}, $1, $2-$1);
				} elsif($1) {
					$self->{body} = substr($self->{body}, $1);
				} elsif($2) {
					$self->{body} = substr($self->{body}, 0, $2);
				}
				$unzipped_body = $self->{body};
			}
		}
		if(length($self->{body}) >= MIN_GZIP_LEN) {
			require Compress::Zlib;
			Compress::Zlib->import;

			# Avoid 'Wide character in memGzip'
			unless($encode_loaded) {
				require Encode;
				$encode_loaded = 1;
			}
			my $nbody = Compress::Zlib::memGzip(\Encode::encode_utf8($self->{body}));
			if(length($nbody) < length($self->{body})) {
				$self->{body} = $nbody;
				push @{$self->{o}}, "Content-Encoding: $encoding";
				push @{$self->{o}}, "Vary: Accept-Encoding";
			}
		}
	}

	if($self->{cache}) {
		require Storable;

		my $cache_hash;
		my $key = $self->_generate_key();

		# Cache unzipped version
		if(!defined($self->{body})) {
			if($self->{send_body}) {
				$self->{cobject} = $self->{cache}->get_object($key);
				if(defined($self->{cobject})) {
					$cache_hash = Storable::thaw($self->{cobject}->value());
					$headers = $cache_hash->{'headers'};
					@{$self->{o}} = ("X-FCGI-Buffer-$VERSION: Hit");
				} else {
					carp "Error retrieving data for key $key";
				}
			}

			# Nothing has been output yet, so we can check if it's
			# OK to send 304 if possible
			if($self->{send_body} && $ENV{'SERVER_PROTOCOL'} &&
			  ($ENV{'SERVER_PROTOCOL'} eq 'HTTP/1.1') &&
			  $self->{generate_304} && ($self->{status} == 200)) {
				if($ENV{'HTTP_IF_MODIFIED_SINCE'}) {
					$self->_check_modified_since({
						since => $ENV{'HTTP_IF_MODIFIED_SINCE'},
						modified => $self->{cobject}->created_at()
					});
				}
			}
			if($self->{send_body} && ($self->{status} == 200)) {
				$self->{body} = $cache_hash->{'body'};
				if(!defined($self->{body})) {
					# Panic
					$headers = 'Status: 500 Internal Server Error';
					@{$self->{o}} = ('Content-type: text/plain');
					$self->{body} = "Can't retrieve body for key $key, cache_hash contains:\n";
					foreach my $k (keys %{$cache_hash}) {
						$self->{body} .= "\t$k\n";
					}
					warn($self->{body});
					$self->{cache}->remove($key);
					carp "Can't retrieve body for key $key";
					$self->{send_body} = 0;
					$self->{status} = 500;
				}
			}
			if($self->{send_body} && $ENV{'SERVER_PROTOCOL'} &&
			  ($ENV{'SERVER_PROTOCOL'} eq 'HTTP/1.1') &&
			  ($self->{status} == 200)) {
				if($ENV{'HTTP_IF_NONE_MATCH'}) {
					if(!defined($self->{etag})) {
						unless($encode_loaded) {
							require Encode;
							$encode_loaded = 1;
						}
						$self->{etag} = '"' . Digest::MD5->new->add(Encode::encode_utf8($self->{body}))->hexdigest() . '"';
					}
					if(($self->{etag} =~ /\Q$ENV{'HTTP_IF_NONE_MATCH'}\E/) && $self->{generate_304}) {
						push @{$self->{o}}, "Status: 304 Not Modified";
						$self->{status} = 304;
						$self->{send_body} = 0;
						if($self->{logger}) {
							$self->{logger}->debug('Set status to 304');
						}
					}
				}
				if($self->{send_body} && (length($encoding) > 0)) {
					if(length($self->{body}) >= MIN_GZIP_LEN) {
						require Compress::Zlib;
						Compress::Zlib->import;

						# Avoid 'Wide character in memGzip'
						unless($encode_loaded) {
							require Encode;
							$encode_loaded = 1;
						}
						my $nbody = Compress::Zlib::memGzip(\Encode::encode_utf8($self->{body}));
						if(length($nbody) < length($self->{body})) {
							$self->{body} = $nbody;
							push @{$self->{o}}, "Content-Encoding: $encoding";
							push @{$self->{o}}, "Vary: Accept-Encoding";
						}
					}
				}
			}
			my $cannot_304 = !$self->{generate_304};
			if(defined($headers) && ($headers =~ /^ETag: "([a-z0-9]{32})"/m)) {
				$self->{etag} = $1;
			} else {
				$self->{etag} = $cache_hash->{'etag'};
			}
			if($ENV{'HTTP_IF_NONE_MATCH'} && $self->{send_body} && ($self->{status} != 304) && $self->{generate_304}) {
				if(defined($self->{etag}) && ($self->{etag} =~ /\Q$ENV{'HTTP_IF_NONE_MATCH'}\E/) && ($self->{status} == 200)) {
					push @{$self->{o}}, "Status: 304 Not Modified";
					$self->{send_body} = 0;
					$self->{status} = 304;
					if($self->{logger}) {
						$self->{logger}->debug('Set status to 304');
					}
				} else {
					$cannot_304 = 1;
				}
			} elsif($self->{generate_etag} && defined($self->{etag}) && ((!defined($headers)) || ($headers !~ /^ETag: /m))) {
				push @{$self->{o}}, "ETag: $self->{etag}";
			}
			if($self->{cobject}) {
				if($ENV{'HTTP_IF_MODIFIED_SINCE'} && ($self->{status} != 304) && (!$cannot_304)) {
					$self->_check_modified_since({
						since => $ENV{'HTTP_IF_MODIFIED_SINCE'},
						modified => $self->{cobject}->created_at()
					});
				} elsif($self->{generate_last_modified}) {
					push @{$self->{o}}, "Last-Modified: " . HTTP::Date::time2str($self->{cobject}->created_at());
				}
			}
		} else {
			if($self->{status} == 200) {
				unless($self->{cache_age}) {
					# It would be great if CHI::set()
					# allowed the time to be 'lru' for least
					# recently used.
					$self->{cache_age} = '10 minutes';
				}
				$cache_hash->{'body'} = $unzipped_body;
				if($self->{body} && $self->{send_body}) {
					my $body_length = length($self->{body});
					push @{$self->{o}}, "Content-Length: $body_length";
				}
				if(scalar(@{$self->{o}})) {
					# Remember, we're storing the UNzipped
					# version in the cache
					my $c;
					if(defined($headers) && length($headers)) {
						$c = $headers . "\r\n" . join("\r\n", @{$self->{o}});
					} else {
						$c = join("\r\n", @{$self->{o}});
					}
					$c =~ s/^Content-Encoding: .+$//mg;
					$c =~ s/^Vary: Accept-Encoding.*\r?$//mg;
					$c =~ s/\n+/\n/gs;
					if(length($c)) {
						$cache_hash->{'headers'} = $c;
					}
				} elsif(defined($headers) && length($headers)) {
					$headers =~ s/^Content-Encoding: .+$//mg;
					$headers =~ s/^Vary: Accept-Encoding.*\r?$//mg;
					$headers =~ s/\n+/\n/gs;
					if(length($headers)) {
						$cache_hash->{'headers'} = $headers;
					}
				}
				if($self->{generate_etag} && defined($self->{etag})) {
					$cache_hash->{'etag'} = $self->{etag};
				}
				$self->{cache}->set($key, Storable::freeze($cache_hash), $self->{cache_age});
				if($self->{logger}) {
					$self->{logger}->debug("store $key in the cache");
				}
				if($self->{generate_last_modified}) {
					$self->{cobject} = $self->{cache}->get_object($key);
					if(defined($self->{cobject})) {
						push @{$self->{o}}, "Last-Modified: " . HTTP::Date::time2str($self->{cobject}->created_at());
					} else {
						push @{$self->{o}}, "Last-Modified: " . HTTP::Date::time2str(time);
					}
				}
			}
			push @{$self->{o}}, "X-FCGI-Buffer-$VERSION: Miss";
		}
		# We don't need it any more, so give Perl a chance to
		# tidy it up seeing as we're in the destructor
		$self->{cache} = undef;
	}

	my $body_length = defined($self->{body}) ? length($self->{body}) : 0;

	if(defined($headers) && length($headers)) {
		# Put the original headers first, then those generated within
		# FCGI::Buffer
		unshift @{$self->{o}}, split(/\r\n/, $headers);
		if($self->{body} && $self->{send_body}) {
			my $already_done = 0;
			foreach(@{$self->{o}}) {
				if(/^Content-Length: /) {
					$already_done = 1;
					last;
				}
			}
			unless($already_done) {
				push @{$self->{o}}, "Content-Length: $body_length";
			}
		}
	} else {
		push @{$self->{o}}, "X-FCGI-Buffer-$VERSION: No headers";
	}

	if($body_length && $self->{send_body}) {
		push @{$self->{o}}, '';
		push @{$self->{o}}, $self->{body};
	}

	# XXXXXXXXXXXXXXXXXXXXXXX
	if(0) {
		# This code helps to debug Wide character prints
		my $wideCharWarningsIssued = 0;
		my $widemess;
		$SIG{__WARN__} = sub {
			$wideCharWarningsIssued += "@_" =~ /Wide character in .../;
			$widemess = "@_";
			if($logger) {
				$logger->fatal($widemess);
				my $i = 1;
				$logger->trace('Stack Trace');
				while((my @call_details = (caller($i++)))) {
					$logger->trace($call_details[1] . ':' . $call_details[2] . ' in function ' . $call_details[3]);
				}
			}
			CORE::warn(@_);     # call the builtin warn as usual
		};

		if(scalar @{$self->{o}}) {
			print join("\r\n", @{$self->{o}});
			if($wideCharWarningsIssued) {
				my $mess = join("\r\n", @{$self->{o}});
				$mess =~ /[^\x00-\xFF]/;
				open(my $fout, '>>', '/tmp/NJH');
				print $fout "$widemess:\n";
				print $fout $mess;
				print $fout 'x' x 40 . "\n";
				close $fout;
			}
		}
	} elsif(scalar @{$self->{o}}) {
		print join("\r\n", @{$self->{o}});
	}
	# XXXXXXXXXXXXXXXXXXXXXXX

	if((!$self->{send_body}) || !defined($self->{body})) {
		print "\r\n\r\n";
	}
}

sub _check_modified_since {
	my $self = shift;
	if(!$self->{generate_304}) {
		return;
	}
	my $params = shift;

	if(!defined($$params{since})) {
		return;
	}
	my $s = HTTP::Date::str2time($$params{since});
	if(!defined($s)) {
		# IF_MODIFIED_SINCE isn't a valid data
		return;
	}

	my $age = $self->_my_age();
	if(!defined($age)) {
		return;
	}
	if($age > $s) {
		# Script has been updated so it may produce different output
		return;
	}

	if($$params{modified} <= $s) {
		push @{$self->{o}}, "Status: 304 Not Modified";
		$self->{status} = 304;
		$self->{send_body} = 0;
		if($self->{logger}) {
			$self->{logger}->debug('Set status to 304');
		}
	}
}

sub _optimise_content {
	my $self = shift;

	# Regexp::List - wow!
	$self->{body} =~ s/(\s+|\r)\n|\n\+/\n/gs;
	# $self->{body} =~ s/\r\n/\n/gs;
	# $self->{body} =~ s/\s+\n/\n/gs;
	# $self->{body} =~ s/\n+/\n/gs;
	$self->{body} =~ s/\<\/option\>\s\<option/\<\/option\>\<option/gis;
	$self->{body} =~ s/\<\/div\>\s\<div/\<\/div\>\<div/gis;
	# $self->{body} =~ s/\<\/p\>\s\<\/div/\<\/p\>\<\/div/gis;
	# $self->{body} =~ s/\<div\>\s+/\<div\>/gis;	# Remove spaces after <div>
	$self->{body} =~ s/(<div>\s+|\s+<div>)/<div>/gis;
	$self->{body} =~ s/\s+<\/div\>/\<\/div\>/gis;	# Remove spaces before </div>
	$self->{body} =~ s/\s+\<p\>|\<p\>\s+/\<p\>/im;  # TODO <p class=
	$self->{body} =~ s/\s+\<\/p\>|\<\/p\>\s+/\<\/p\>/gis;
	$self->{body} =~ s/<html>\s+<head>/<html><head>/is;
	$self->{body} =~ s/\s*<\/head>\s+<body>\s*/<\/head><body>/is;
	$self->{body} =~ s/<html>\s+<body>/<html><body>/is;
	$self->{body} =~ s/<body>\s+/<body>/is;
	$self->{body} =~ s/\s+\<\/html/\<\/html/is;
	$self->{body} =~ s/\s+\<\/body/\<\/body/is;
	$self->{body} =~ s/\n\s+|\s+\n/\n/g;
	$self->{body} =~ s/\t+/ /g;
	$self->{body} =~ s/\s(\<.+?\>\s\<.+?\>)/$1/;
	$self->{body} =~ s/(\<.+?\>\s\<.+?\>)\s/$1/g;
	$self->{body} =~ s/\<p\>\s/\<p\>/gi;
	$self->{body} =~ s/\<\/p\>\s\<p\>/\<\/p\>\<p\>/gi;
	$self->{body} =~ s/\<\/tr\>\s\<tr\>/\<\/tr\>\<tr\>/gi;
	$self->{body} =~ s/\<\/td\>\s\<\/tr\>/\<\/td\>\<\/tr\>/gi;
	$self->{body} =~ s/\<\/td\>\s*\<td\>/\<\/td\>\<td\>/gis;
	$self->{body} =~ s/\<\/tr\>\s\<\/table\>/\<\/tr\>\<\/table\>/gi;
	$self->{body} =~ s/\<br\s?\/?\>\s?\<p\>/\<p\>/gi;
	$self->{body} =~ s/\<br\>\s/\<br\>/gi;
	$self->{body} =~ s/\<br\s?\/\>\s/\<br \/\>/gi;
	$self->{body} =~ s/ +/ /gs;	# Remove duplicate space, don't use \s+ it breaks JavaScript
	$self->{body} =~ s/\s\<p\>/\<p\>/gi;
	$self->{body} =~ s/\s\<script/\<script/gi;
	$self->{body} =~ s/(<script>\s|\s<script>)/<script>/gis;
	$self->{body} =~ s/(<\/script>\s|\s<\/script>)/<\/script>/gis;
	$self->{body} =~ s/\<td\>\s/\<td\>/gi;
	$self->{body} =~ s/\s?\<a\shref="(.+?)"\>\s?/ <a href="$1">/gis;
	$self->{body} =~ s/\s?<a\shref=\s"(.+?)"\>/ <a href="$1">/gis;
	$self->{body} =~ s/(\s?<hr>\s|\s<hr>\s?)/<hr>/gis;
	# $self->{body} =~ s/\s<hr>/<hr>/gis;
	# $self->{body} =~ s/<hr>\s/<hr>/gis;
	$self->{body} =~ s/<\/li>\s<li>/<\/li><li>/gis;
	$self->{body} =~ s/<\/li>\s<\/ul>/<\/li><\/ul>/gis;
	$self->{body} =~ s/<ul>\s<li>/<ul><li>/gis;

	return $self->{body};
}

# Create a key for the cache
sub _generate_key {
	my $self = shift;
	if($self->{cache_key}) {
		return $self->{cache_key};
	}
	unless(defined($self->{info})) {
		$self->{info} = CGI::Info->new({ cache => $self->{cache} });
	}

	# TODO: Use CGI::Lingua so that different languages are stored
	#	in different caches
	my $key = $self->{info}->browser_type() . '::' . $self->{info}->domain_name() . '::' . $self->{info}->script_name() . '::' . $self->{info}->as_string();
	if($ENV{'HTTP_COOKIE'}) {
		# Different states of the client are stored in different caches
		$key .= '::' . $ENV{'HTTP_COOKIE'};
	}
	$key =~ s/\//::/g;
	return $key;
}

=head2 init

Set various options and override default values.

    # Put this toward the top of your program before you do anything
    # By default, generate_tag, generate_304 and compress_content are ON,
    # optimise_content and lint_content are OFF.  Set optimise_content to 2 to
    # do aggressive JavaScript optimisations which may fail.
    use FCGI::Buffer;
    my $buffer = FCGI::Buffer->new();
    $buffer->init({
	generate_etag => 1,	# make good use of client's cache
	generate_last_modified => 1,	# more use of client's cache
	compress_content => 1,	# if gzip the output
	optimise_content => 0,	# optimise your program's HTML, CSS and JavaScript
	cache => CHI->new(driver => 'File'),	# cache requests
	cache_key => 'string',	# key for the cache
	logger => $self->{logger},
	lint->content => 0,	# Pass through HTML::Lint
	generate_304 => 1,	# Generate 304: Not modified
    );

If no cache_key is given, one will be generated which may not be unique.
The cache_key should be a unique value dependent upon the values set by the
browser.

The cache object will be an object that understands get_object(),
set(), remove() and created_at() messages, such as an L<CHI> object.

Logger will be an object that understands debug() such as an L<Log::Log4perl>
object.

To generate a last_modified header, you must give a cache object.

Init allows a reference of the options to be passed. So both of these work:
    use FCGI::Buffer;
    #...
    my $buffer = FCGI::Buffer->new();
    $b->init(generate_etag => 1);
    $b->init({ generate_etag => 1, info => CGI::Info->new() });

Generally speaking, passing by reference is better since it copies less on to
the stack.

=cut

sub init {
	my $self = shift;
	my %params = (ref($_[0]) eq 'HASH') ? %{$_[0]} : @_;

	# Safe options - can be called at any time
	if(defined($params{generate_etag})) {
		$self->{generate_etag} = $params{generate_etag};
	}
	if(defined($params{generate_last_modified})) {
		$self->{generate_last_modified} = $params{generate_last_modified};
	}
	if(defined($params{compress_content})) {
		$self->{compress_content} = $params{compress_content};
	}
	if(defined($params{optimise_content})) {
		$self->{optimise_content} = $params{optimise_content};
	}
	if(defined($params{lint_content})) {
		$self->{lint_content} = $params{lint_content};
	}
	if(defined($params{logger})) {
		$self->{logger} = $params{logger};
	}
	if(defined($params{generate_304})) {
		$self->{generate_304} = $params{generate_304};
	}
	if(defined($params{info}) && (!defined($self->{info}))) {
		$self->{info} = $params{info};
	}

	# Unsafe options - must be called before output has been started
	my $pos = $self->{buf}->getpos;
	if($pos > 0) {
		if(defined($self->{logger})) {
			$self->{logger}->warn("Too late to call init, $pos characters have been printed");
		} else {
			# Must do Carp::carp instead of carp for Test::Carp
			Carp::carp "Too late to call init, $pos characters have been printed";
		}
	}
	if(defined($params{cache}) && $self->can_cache()) {
		if(defined($ENV{'HTTP_CACHE_CONTROL'})) {
			my $control = $ENV{'HTTP_CACHE_CONTROL'};
			if(defined($self->{logger})) {
				$self->{logger}->debug("cache_control = $control");
			}
			if($control =~ /^max-age\s*=\s*(\d+)$/) {
				# There is an argument not to do this
				# since one client will affect others
				$self->{cache_age} = "$1 seconds";
				if(defined($self->{logger})) {
					$self->{logger}->debug("cache_age = $self->{cache_age}");
				}
			}
		}
		$self->{cache} = $params{cache};
		if(defined($params{cache_key})) {
			$self->{cache_key} = $params{cache_key};
		}
	}
}

sub import {
	# my $class = shift;
	shift;

	return unless @_;

	init(@_);
}

=head2 set_options

Synonym for init, kept for historical reasons.

=cut

sub set_options {
	my $self = shift;
	my %params = (ref($_[0]) eq 'HASH') ? %{$_[0]} : @_;

	$self->init(\%params);
}

=head2 can_cache

Returns true if the server is allowed to store the results locally.

=cut

sub can_cache {
	my $self = shift;

	if(defined($ENV{'NO_CACHE'}) || defined($ENV{'NO_STORE'})) {
		return 0;
	}
	if(defined($ENV{'HTTP_CACHE_CONTROL'})) {
		my $control = $ENV{'HTTP_CACHE_CONTROL'};
		if(defined($self->{logger})) {
			$self->{logger}->debug("cache_control = $control");
		}
		if(($control eq 'no-store') ||
		       ($control eq 'no-cache') ||
		       ($control eq 'private')) {
			return 0;
		}
	}
	return 1;
}

=head2 is_cached

Returns true if the output is cached. If it is then it means that all of the
expensive routines in the FCGI script can be by-passed because we already have
the result stored in the cache.

    # Put this toward the top of your program before you do anything

    # Example key generation - use whatever you want as something
    # unique for this call, so that subsequent calls with the same
    # values match something in the cache
    use CGI::Info;
    use CGI::Lingua;
    use FCGI::Buffer;

    my $i = CGI::Info->new();
    my $l = CGI::Lingua->new(supported => ['en']);

    # To use server side caching you must give the cache argument, however
    # the cache_key argument is optional - if you don't give one then one will
    # be generated for you
    my $buffer = FCGI::Buffer->new();
    if($buffer->can_cache()) {
        $buffer->init(
	    cache => CHI->new(driver => 'File'),
	    cache_key => $i->domain_name() . '/' . $i->script_name() . '/' . $i->as_string() . '/' . $l->language()
        );
        if($buffer->is_cached()) {
	    # Output will be retrieved from the cache and sent automatically
	    exit;
        }
    }
    # Not in the cache, so now do our expensive computing to generate the
    # results
    print "Content-type: text/html\n";
    # ...

=cut

sub is_cached {
	my $self = shift;

	unless($self->{cache}) {
		if($self->{logger}) {
			$self->{logger}->debug("is_cached: cache hasn't been enabled");
		}
		return 0;
	}

	my $key = $self->_generate_key();

	if($self->{logger}) {
		$self->{logger}->debug("is_cached: looking for key = $key");
	}
	$self->{cobject} = $self->{cache}->get_object($key);
	unless($self->{cobject}) {
		if($self->{logger}) {
			$self->{logger}->debug('not found in cache');
		}
		return 0;
	}
	unless($self->{cobject}->value($key)) {
		if($self->{logger}) {
			$self->{logger}->warn('is_cached: object is in the cache but not the data');
		}
		$self->{cobject} = undef;
		return 0;
	}

	# If the script has changed, don't use the cache since we may produce
	# different output
	my $age = $self->_my_age();
	unless(defined($age)) {
		if($self->{logger}) {
			$self->{logger}->debug("Can't determine script's age");
		}
		# Can't determine the age. Play it safe an assume we're not
		# cached
		$self->{cobject} = undef;
		return 0;
	}
	if($age > $self->{cobject}->created_at()) {
		# Script has been updated so it may produce different output
		if($self->{logger}) {
			$self->{logger}->debug('Script has been updated');
		}
		$self->{cobject} = undef;
		# Nothing will be in date and all new searches would miss
		# anyway, so may as well clear it all
		$self->{cache}->clear();
		return 0;
	}
	if($self->{logger}) {
		$self->{logger}->debug('Script is in the cache');
	}
	return 1;
}

sub _my_age {
	my $self = shift;

	if($self->{script_mtime}) {
		return $self->{script_mtime};
	}
	unless(defined($self->{info})) {
		if($self->{cache}) {
			$self->{info} = CGI::Info->new({ cache => $self->{cache} });
		} else {
			$self->{info} = CGI::Info->new();
		}
	}

	my $path = $self->{info}->script_path();
	unless(defined($path)) {
		return;
	}

	my @statb = stat($path);
	$self->{script_mtime} = $statb[9];
	return $self->{script_mtime};
}

sub _should_gzip {
	my $self = shift;

	if($self->{compress_content} && ($ENV{'HTTP_ACCEPT_ENCODING'} || $ENV{'HTTP_TE'})) {
		my $accept = lc($ENV{'HTTP_ACCEPT_ENCODING'} ? $ENV{'HTTP_ACCEPT_ENCODING'} : $ENV{'HTTP_TE'});
		foreach my $encoding ('x-gzip', 'gzip') {
			$_ = $accept;
			if(defined($self->{content_type})) {
				my @content_type = @{$self->{content_type}};
				if($content_type[0]) {
					if (m/$encoding/i && (lc($content_type[0]) eq 'text')) {
						return $encoding;
					}
				} else {
					if (m/$encoding/i) {
						return $encoding;
					}
				}
			}
		}
	}

	return '';
}

=head1 AUTHOR

Nigel Horne, C<< <njh at bandsman.co.uk> >>

=head1 BUGS

FCGI::Buffer should be safe even in scripts which produce lots of different
output, e.g. e-commerce situations.
On such pages, however, I strongly urge to setting generate_304 to 0 and
sending the HTTP header "Cache-Control: no-cache".

When using L<Template>, ensure that you don't use it to output to STDOUT,
instead you will need to capture into a variable and print that.
For example:

    my $output;
    $template->process($input, $vars, \$output) || ($output = $template->error());
    print $output;

Can produce buggy JavaScript if you use the <!-- HIDING technique.
This is a bug in L<JavaScript::Packer>, not FCGI::Buffer.
See https://github.com/nevesenin/javascript-packer-perl/issues/1#issuecomment-4356790

Mod_deflate can confuse this when compressing output.
Ensure that deflation is off for .pl files:

    SetEnvIfNoCase Request_URI \.(?:gif|jpe?g|png|pl)$ no-gzip dont-vary

If you request compressed output then uncompressed output (or vice
versa) on input that produces the same output, the status will be 304.
The letter of the spec says that's wrong, so I'm noting it here, but
in practice you should not see this happen or have any difficulties
because of it.

FCGI::Buffer has not been tested against FastCGI.

I advise adding FCGI::Buffer as the last use statement so that it is
cleared up first.  In particular it should be loaded after
L<Log::Log4Perl>, if you're using that, so that any messages it
produces are printed after the HTTP headers have been sent by
FCGI::Buffer;

Please report any bugs or feature requests to C<bug-fcgi-buffer at rt.cpan.org>,
or through the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=FCGI-Buffer>.
I will be notified, and then you'll automatically be notified of progress on
your bug as I make changes.

=head1 SEE ALSO

HTML::Packer, HTML::Lint

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc FCGI::Buffer

You can also look for information at:

=over 4

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=FCGI-Buffer>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/FCGI-Buffer>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/FCGI-Buffer>

=item * Search CPAN

L<http://search.cpan.org/dist/FCGI-Buffer/>

=back

=head1 ACKNOWLEDGEMENTS

The inspiration and code for some if this is cgi_buffer by Mark
Nottingham: http://www.mnot.net/cgi_buffer.

=head1 LICENSE AND COPYRIGHT

The licence for cgi_buffer is:

    "(c) 2000 Copyright Mark Nottingham <mnot@pobox.com>

    This software may be freely distributed, modified and used,
    provided that this copyright notice remain intact.

    This software is provided 'as is' without warranty of any kind."

The rest of the program is Copyright 2015 Nigel Horne,
and is released under the following licence: GPL

=cut

1; # End of FCGI::Buffer
