package FCGI::Buffer;

use strict;
use warnings;

# FIXME: save_to treats ?arg1=a&arg2=b and ?arg2=b&arg1=a as different
# FIXME: save_to treats /cgi-bin/foo.fcgi and /cgi-bin2/foo.fcgi as the same

use Digest::MD5;
use File::Path;
use File::Spec;
use IO::String;
use CGI::Info;
use Carp;
use HTTP::Date;
use DBI;
use Readonly;

Readonly my $DEFAULT_GENERATE_304 => 1;
Readonly my $DEFAULT_GENERATE_LAST_MODIFIED => 1;
Readonly my $DEFAULT_COMPRESS_CONTENT => 1;
Readonly my $DEFAULT_OPTIMISE_CONTENT => 0;
Readonly my $DEFAULT_LINT_CONTENT => 0;
Readonly my $MIN_GZIP_LEN => 32;
Readonly my $DEFAULT_PROTOCOL => 'http';
Readonly my $DEFAULT_CACHE_DURATION => '10 minutes';
Readonly my $DEFAULT_SAVE_TO_TTL => 600;
Readonly my $SAVE_TO_DATABASE => 'fcgi.buffer.sql';

# The protocols that understand ETag, If-None-Match and If-Modified-Since
Readonly my $CONDITIONAL_PROTOCOL => qr/^HTTP\/(?:1\.1|2\.0)$/;

# Cache-Control directives in a request which forbid using the server cache
Readonly my %NO_CACHE_DIRECTIVES => map { $_ => 1 } qw(no-store no-cache private);

# Content encodings that we can produce, and the module needed for each
Readonly my %ENCODING_MODULE => (
	'gzip' => 'Compress::Zlib',
	'x-gzip' => 'Compress::Zlib',
	'br' => 'IO::Compress::Brotli',
	'zstd' => 'Compress::Zstd',
);

# Options to init() which can be changed at any time, and are only changed
# when a defined value is given
Readonly my @SAFE_OPTIONS => qw(
	generate_etag generate_last_modified compress_content optimise_content
	lint_content logger lingua generate_304
);

=head1 NAME

FCGI::Buffer - Verify, Cache and Optimise FCGI Output

=head1 VERSION

Version 0.22

=cut

our $VERSION = '0.22';

=head1 SYNOPSIS

FCGI::Buffer verifies the HTML that you produce by passing it through
C<HTML::Lint>.

FCGI::Buffer optimises FCGI programs by reducing, filtering and compressing
output to speed up the transmission and by nearly seamlessly making use of
client and server caches.

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

To also make use of server caches, that is to say,
to save regenerating output when different clients ask you for the same data,
you will need to create a cache.
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
    }

To temporarily prevent the use of server-side caches, for example, whilst
debugging before publishing a code change, set the NO_CACHE environment variable
to any non-zero value.
This will also stop ETag from being added to the header.
If you get errors about Wide characters in print,
you've forgotten to emit pure HTML on non-ASCII characters.
See L<HTML::Entities>.
As a hack work around you could also remove accents and the like by using
L<Text::Unidecode>,
which works well but isn't really what you want.

=head1 SUBROUTINES/METHODS

=cut

=head2 new

Create an FCGI::Buffer object.
Do one of these for each FCGI::Accept.

=cut

# FIXME: Call init() on any arguments that are given
sub new
{
	my $proto = shift;
	my $class = ref($proto) || $proto;

	# Use FCGI::Buffer->new(), not FCGI::Buffer::new()
	if(!defined($class)) {
		carp(__PACKAGE__, ': use ->new() not ::new() to instantiate');
		return;
	}

	# Handle hash or hashref arguments
	my %args;
	if((@_ == 1) && (ref $_[0] eq 'HASH')) {
		%args = %{$_[0]};
	} elsif((@_ % 2) == 0) {
		%args = @_;
	} else {
		carp(__PACKAGE__, ': Invalid arguments passed to new()');
		return;
	}

	# Initialize buffer and object properties
	my $buf = IO::String->new() or croak(__PACKAGE__, ': Failed to initialize IO::String');
	my $rc = {
		buf => $buf,
		old_buf => select($buf),
		generate_304 => $DEFAULT_GENERATE_304,
		generate_last_modified => $DEFAULT_GENERATE_LAST_MODIFIED,
		compress_content => $DEFAULT_COMPRESS_CONTENT,
		optimise_content => $DEFAULT_OPTIMISE_CONTENT,
		lint_content => $DEFAULT_LINT_CONTENT,
		%args,
	};
	# $rc->{o} = ();

	# Premise 1: an ETag is only useful if the protocol supports If-None-Match
	# Premise 2: an explicit generate_etag argument is the caller's decision
	# Conclusion: default it from the protocol, but only when it isn't given
	if(!defined($rc->{generate_etag})) {
		$rc->{generate_etag} = _is_conditional_protocol() ? 1 : 0;
	}

	# Return the blessed object
	return bless $rc, $class;
}

sub DESTROY
{
	if(defined($^V) && ($^V ge 'v5.14.0')) {
		return if ${^GLOBAL_PHASE} eq 'DESTRUCT';	# >= 5.14.0 only
	}
	my $self = shift;

	if($self->{'logger'}) {
		$self->{'logger'}->trace('>In ' . __PACKAGE__ . ' DESTROY');
	}
	select($self->{old_buf});
	if((!defined($self->{buf})) || (!defined($self->{buf}->getpos()))) {
		# Unlikely
		if($self->{'logger'}) {
			$self->{'logger'}->info('Nothing to send');
		}
		return;
	}
	my $pos = $self->{buf}->getpos();
	$self->{buf}->setpos(0);
	my $buf;
	read($self->{buf}, $buf, $pos);
	my $headers;
	($headers, $self->{body}) = split /\r?\n\r?\n/, $buf, 2;

	if($self->{'logger'}) {
		if($ENV{'HTTP_IF_NONE_MATCH'}) {
			$self->{logger}->debug("HTTP_IF_NONE_MATCH: $ENV{HTTP_IF_NONE_MATCH}");
		}
		if($ENV{'HTTP_IF_MODIFIED_SINCE'}) {
			$self->{logger}->debug("HTTP_IF_MODIFIED_SINCE: $ENV{HTTP_IF_MODIFIED_SINCE}");
		}
		$self->{logger}->debug("Generate_etag = $self->{generate_etag}, ",
			"Generate_304 = $self->{generate_304}, ",
			"Generate_last_modified = $self->{generate_last_modified}");
	}

	unless($headers || $self->is_cached()) {
		if($self->{'logger'}) {
			$self->{'logger'}->debug('There was no output');
		}
		if(!defined($headers)) {
			require HTTP::Status;
			HTTP::Status->import();

			if(!defined($self->{'status'})) {
				if($self->{'info'}) {
					$self->{'status'} = $self->{'info'}->status();
				} else {
					$self->{'status'} = 200;
				}
			}
			print 'Status: ', $self->{status}, ' ',
				HTTP::Status::status_message($self->{status}),
				"\n\n";
		}
		return;
	}
	$self->{send_body} = (defined($ENV{'REQUEST_METHOD'}) && ($ENV{'REQUEST_METHOD'} eq 'HEAD')) ? 0 : 1;

	if($headers) {
		$self->_set_content_type($headers);
	}

	if(defined($self->{body}) && ($self->{body} eq '')) {
		# E.g. if header of Location is given with no body, for
		#	redirection
		delete $self->{body};
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

				if($self->{'logger'}) {
					$self->{'logger'}->trace('Packer');
				}

				# Level 1 is one pass, higher levels repeat until
				# the body stops shrinking
				my $oldlength = length($self->{body});
				$self->_optimise_content();
				if($self->{optimise_content} >= 2) {
					while(length($self->{body}) < $oldlength) {
						$oldlength = length($self->{body});
						$self->_optimise_content();
					}
				}

				# If we're on http://www.example.com and have a link
				# to http://www.example.com/foo/bar.htm, change the
				# link to /foo/bar.htm - there's no need to include
				# the site name in the link
				my $info = $self->_info();
				my $href = $info->host_name();
				my $protocol = $info->protocol() || $DEFAULT_PROTOCOL;

				$self->{body} =~ s/<a\s+href="\Q$protocol\E:\/\/\Q$href\E"/<a href="\/"/gi;
				$self->{body} =~ s/<a\s+href="\Q$protocol\E:\/\/\Q$href\E(?=[\/?#])/<a href="/gi;
				$self->{body} =~ s/<a\s+href="\Q$protocol\E:\/\//<a href="\/\//gi;

				# If we're in "/cgi-bin/foo.cgi?arg1=a" replace
				# "/cgi-bin/foo.cgi?arg2=b" with "?arg2=b"
				# A link to "/cgi-bin/foo.cgi" with no arguments is
				# left alone, since href="" would mean the current
				# page, arguments and all

				my $script_name = $ENV{'SCRIPT_NAME'};
				if(defined($script_name) && ($script_name =~ /^\//)) {
					$self->{body} =~ s/<a\s+href="\Q$script_name\E(\?[^"]+)"/<a href="$1"/gi;
				}

				# TODO use URI->path_segments to change links in
				# /aa/bb/cc/dd.htm which point to /aa/bb/ff.htm to
				# ../ff.htm

				# TODO: <img border=0 src=...>
				$self->{body} =~ s/<img\s+src="\Q$protocol\E:\/\/\Q$href\E"/<img src="\/"/gi;
				$self->{body} =~ s/<img\s+src="\Q$protocol\E:\/\/\Q$href\E(?=[\/?#])/<img src="/gi;

				# Don't use HTML::Clean because of RT402
				# my $h = new HTML::Clean(\$self->{body});
				# # $h->compat();
				# $h->strip();
				# my $ref = $h->data();

				# Don't always do javascript 'best' since it's confused
				# by the common <!-- HIDE technique.
				my $options = {
					remove_comments => 1,
					remove_newlines => 0,
					do_stylesheet => 'minify'
				};
				if($self->{optimise_content} >= 2) {
					$options->{do_javascript} = 'best';
					# [^>] stops the tag running on into the
					# rest of the page
					$self->{body} =~ s/(<script[^>]*+>)\s*+<!--/$1/gi;
					$self->{body} =~ s/\/\/-->\s*+<\/script>/<\/script>/gi;
					$self->{body} =~ s/(<script[^>]*+>)\s++/$1/gi;
				}
				$self->{body} = HTML::Packer->init()->minify(\$self->{body}, $options);
				if($self->{optimise_content} >= 2) {
					# Change document.write("a"); document.write("b")
					# into document.write("a"+"b");
					# Premise 1: every substitution removes
					#	");document.write(" and adds "+"
					# Premise 2: so every substitution shortens the body
					# Conclusion: looping until nothing is substituted
					#	is the same as looping until it stops
					#	shrinking, and always terminates
					# Nothing may cross a </script>, otherwise
					# writes in different scripts get merged
					1 while($self->{body} =~ s{
						(<script\s+type\s*=\s*"text/javascript"\s*>)		# $1: opening tag, kept as written
						((?:(?!</script>).)*?)					# $2: code before the writes, within this script
						document\.write\(((?:(?!</script>)[^;])*?)\);\s*+	# $3: first argument
						document\.write\(((?:(?!</script>)[^;])*?)\)		# $4: second argument
					}{$1${2}document.write($3+$4)}gisx);
				}
			}
			if($self->{lint_content}) {
				require HTML::Lint;
				HTML::Lint->import;

				if($self->{'logger'}) {
					$self->{'logger'}->trace('Lint');
				}
				my $lint = HTML::Lint->new();
				$lint->parse($self->{body});
				$lint->eof();

				if($lint->errors) {
					$headers = 'Status: 500 Internal Server Error';
					@{$self->{o}} = ('Content-type: text/plain');
					$self->{body} = '';
					foreach my $error ($lint->errors) {
						my $errtext = $error->where() . ': ' . $error->errtext() . "\n";
						if($self->{logger}) {
							$self->{logger}->warn($errtext);
						} else {
							warn($errtext);
						}
						$self->{body} .= $errtext;
					}
				}
			}
		}
	}

	if(defined($headers) && ($headers =~ /^Status: (\d+)/m)) {
		$self->{status} = $1;
	} elsif(defined($self->{info})) {
		$self->{status} = $self->{info}->status();
	} else {
		$self->{status} = 200;
	}

	if($self->{'logger'}) {
		$self->{'logger'}->debug("Initial status = $self->{status}");
	}

	# Generate the eTag before compressing, since the compressed data
	# includes the mtime field which changes thus causing a different
	# Etag to be generated
	if($self->{generate_etag} && defined($self->{body}) && _is_conditional_protocol()) {
		$self->_generate_etag();

		if($ENV{'HTTP_IF_NONE_MATCH'} && $self->{generate_304} && ($self->{status} == 200)) {
			$self->_check_if_none_match();
		}
	}

	my $dbh;
	if(my $save_to = $self->{save_to}) {
		my $sqlite_file = File::Spec->catfile($save_to->{directory}, $SAVE_TO_DATABASE);
		if($self->{logger}) {
			$self->{logger}->debug("save_to sqlite file: $sqlite_file");
		}
		# Both branches connected in the same way, they only differ in
		# whether the table may need to be created
		my $is_new = !-r $sqlite_file;
		if($is_new && !-d $save_to->{directory}) {
			mkdir $save_to->{directory};
		}
		$dbh = DBI->connect("dbi:SQLite:dbname=$sqlite_file", undef, undef);
		if($is_new && $save_to->{create_table}) {
			$dbh->prepare('CREATE TABLE fcgi_buffer(key char PRIMARY KEY, language char, browser_type char, path char UNIQUE NOT NULL, uri char NOT NULL, creation timestamp NOT NULL)')->execute();
		}
	}

	my $encoding = $self->_should_gzip();
	my $unzipped_body = $self->{body};

	if(defined($unzipped_body)) {
		my $range = $ENV{'Range'} || $ENV{'HTTP_RANGE'};

		# TODO: Partials
		if($range && !$self->{cache} && defined(my $partial = _apply_range($self->{body}, $range))) {
			$self->{body} = $unzipped_body = $partial;
			$self->_set_status(206);
		}
		$self->_compress({ encoding => $encoding });
	}

	if($self->{cache}) {
		require Storable;

		if($self->{'cache_age'}) {
			# Legacy
			$self->{'cache_duration'} = $self->{'cache_age'};
		}

		my $cache_hash;
		my $key = $self->_generate_key();

		# Cache unzipped version
		if(!defined($self->{body})) {
			if($self->{send_body}) {
				$self->{cobject} = $self->{cache}->get_object($key);
				if(defined($self->{cobject})) {
					$cache_hash = Storable::thaw($self->{cobject}->value());
					$headers = $cache_hash->{'headers'};
					$self->_set_content_type($headers);
					@{$self->{o}} = ("X-FCGI-Buffer-$VERSION: Hit", @{$self->_x_cache_headers('HIT', 'HIT')});
				} elsif($self->{logger}) {
					$self->{logger}->warn(ref($self), ": Error retrieving data for key $key");
				} else {
					carp(ref($self), ": error retrieving data for key $key");
				}
			}

			# Nothing has been output yet, so we can check if it's
			# OK to send 304 if possible
			# _check_modified_since() checks generate_304 itself
			if($self->{send_body} && ($self->{status} == 200) && $ENV{'HTTP_IF_MODIFIED_SINCE'} && $self->{'cobject'} && _is_conditional_protocol()) {
				$self->_check_modified_since({
					since => $ENV{'HTTP_IF_MODIFIED_SINCE'},
					modified => $self->{cobject}->created_at()
				});
			}
			if($self->{send_body} && ($self->{status} == 200) && defined($cache_hash)) {
				$self->{body} = $cache_hash->{'body'};
				if($dbh) {
					my $changes = $self->_save_to($self->{body}, $dbh);
					if($changes && (my $ttl = $self->{save_to}->{ttl})) {
						push @{$self->{o}}, 'Expires: ' . HTTP::Date::time2str(time + $ttl);
					}
				}
				if(!defined($self->{body})) {
					# Panic
					$headers = 'Status: 500 Internal Server Error';
					@{$self->{o}} = ('Content-type: text/plain');
					$self->{body} = "Can't retrieve body for key $key, cache_hash contains:\n";
					foreach my $k (keys %{$cache_hash}) {
						$self->{body} .= "\t$k\n";
					}

					if($dbh) {
						my $query = 'SELECT DISTINCT path FROM fcgi_buffer WHERE key = ?';
						my $sth = $dbh->prepare($query);
						if($self->{logger}) {
							$self->{logger}->debug("$query: $key");
						}
						if($sth->execute($key) && (my $href = $sth->fetchrow_hashref())) {
							if(my $path = $href->{'path'}) {
								unlink($path);
							}
						}
						$query = 'DELETE FROM fcgi_buffer WHERE key = ?';
						$dbh->do($query, undef, $key);
						if($self->{logger}) {
							$self->{logger}->debug("$query: $key");
						}
					}

					$self->{cache}->remove($key);

					if($self->{logger}) {
						$self->{logger}->error("Can't retrieve body for key $key");
						$self->{logger}->warn($self->{body});
					} else {
						carp("Can't retrieve body for key $key");
						warn($self->{body});
					}
					$self->{send_body} = 0;
					$self->_set_status(500);
				}
			}
			# _generate_etag() does nothing if there's already an ETag
			if($self->{send_body} && ($self->{status} == 200) && $ENV{'HTTP_IF_NONE_MATCH'} && $self->{generate_etag} && _is_conditional_protocol()) {
				$self->_generate_etag();
				$self->_check_if_none_match();
			}
			if($self->{status} == 200) {
				$encoding = $self->_should_gzip();
				if($self->{send_body}) {
					if($self->{generate_etag} && ((!defined($headers)) || ($headers !~ /^ETag: /m))) {
						$self->_generate_etag();
					}
					$self->_compress({ encoding => $encoding });
				}
			}
			unless($self->{etag}) {
				# Keep the quotes, they're part of the ETag and
				# If-None-Match includes them
				if(defined($headers) && ($headers =~ /^ETag:\s*("[a-f0-9]{32}")/mi)) {
					$self->{etag} = $1;
				} else {
					$self->{etag} = $cache_hash->{'etag'};
				}
			}
			# Premise 1: If-Modified-Since may only give a 304 if
			#	If-None-Match didn't rule it out
			# Premise 2: If-None-Match rules it out only when it is
			#	checked and fails
			# Conclusion: a 304 is possible unless generate_304 is off,
			#	or the If-None-Match check was made and failed
			my $can_304 = $self->{generate_304};
			if($can_304 && $ENV{'HTTP_IF_NONE_MATCH'} && $self->{send_body} && ($self->{status} != 304)) {
				$can_304 = $self->_check_if_none_match();
			}
			if($self->{cobject}) {
				if($can_304 && $ENV{'HTTP_IF_MODIFIED_SINCE'} && ($self->{status} != 304)) {
					$self->_check_modified_since({
						since => $ENV{'HTTP_IF_MODIFIED_SINCE'},
						modified => $self->{cobject}->created_at()
					});
				}
				if(($self->{status} == 200) && $self->{generate_last_modified}) {
					if($self->{logger}) {
						$self->{logger}->debug('Set Last-Modified to ', HTTP::Date::time2str($self->{cobject}->created_at()));
					}
					push @{$self->{o}}, 'Last-Modified: ' . HTTP::Date::time2str($self->{cobject}->created_at());
				}
			}
		} else {
			# Not in the server-side cache
			if($self->{status} == 200) {
				my $changes = $self->_save_to($unzipped_body, $dbh);

				unless($self->{cache_duration}) {
					# It would be great if CHI::set()
					# allowed the time to be 'lru' for least
					# recently used.
					$self->{cache_duration} = $DEFAULT_CACHE_DURATION;
				}
				$cache_hash->{'body'} = $unzipped_body;
				if($changes && $encoding) {
					$self->_compress({ encoding => $encoding });
				}
				if($self->{o} && scalar(@{$self->{o}})) {
					# Remember, we're storing the UNzipped
					# version in the cache
					my $c;
					if(defined($headers) && length($headers)) {
						$c = "$headers\r\n" . join("\r\n", @{$self->{o}});
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
				if($self->{generate_etag}) {
					$self->_generate_etag();
					$cache_hash->{'etag'} = $self->{etag};
				}
				# TODO: Support the Expires header
				# if($headers !~ /^Expires: /m))) {
				# }
				if($self->{logger}) {
					$self->{logger}->debug("Store $key in the cache, age = ", $self->{cache_duration}, ' ', length($cache_hash->{'body'}), ' bytes');
				}
				$self->{cache}->set($key, Storable::freeze($cache_hash), $self->{cache_duration});

				# Create a static page with the information and link to that in the output
				# HTML
				# Pages whose content depends on the client's cookies
				# or Vary headers are never saved, since anyone
				# following the static link would be given them
				if($dbh && $self->{info} && $self->{save_to} && (my $request_uri = $ENV{'REQUEST_URI'}) && !$self->{_key_is_per_client}) {
					my $query = 'SELECT DISTINCT creation FROM fcgi_buffer WHERE key = ?';
					if($self->{logger}) {
						$self->{logger}->debug("$query: $key");
					}
					my $sth = $dbh->prepare($query);
					$sth->execute($key);
					if(my $href = $sth->fetchrow_hashref()) {
						if(my $ttl = $self->{save_to}->{ttl}) {
							push @{$self->{o}}, 'Expires: ' .
								HTTP::Date::time2str($href->{'creation'} + $ttl);
						}
					} else {
						my $dir = $self->{save_to}->{directory};
						my $browser_type = $self->{info}->browser_type();
						my $language = $self->_save_to_language();
						my $bdir = File::Spec->catfile($dir, _safe_filename($browser_type));
						if($bdir =~ /^(.+)$/) {
							$bdir = $1;	# Untaint
						}
						my $ldir = File::Spec->catfile($bdir, _safe_filename($language));
						my $sdir = File::Spec->catfile($ldir, _safe_filename($self->{info}->script_name()));
						if($self->{logger}) {
							$self->{logger}->debug("Create paths to $sdir");
						}
						File::Path::make_path($sdir);
						my $path = File::Spec->catfile($sdir, $self->_save_to_filename() . '.html');
						if($path =~ /^(.+)$/) {
							$path = $1;	# Untaint
						}
						if(open(my $fout, '>', $path)) {
							my $copy = $unzipped_body;

							# handle <a href="?arg3=4">Call self with different args</a>
							# The static page is somewhere else, so
							# make the links absolute
							my $r = $request_uri;
							$r =~ s/\?.*$//;
							$copy =~ s/<a\s+href="(\?[^"]*)"/<a href="$r$1"/gi;

							# Links to this page now point to its static copy
							my $changes = 0;
							if(defined(my $url = $self->_path_to_url($path))) {
								$changes = ($copy =~ s/((?i:<a\s+href="))\Q$request_uri\E"/$1$url"/g);
							}

							# Avoid Wide character
							unless($self->{_encode_loaded}) {
								require Encode;
								$self->{_encode_loaded} = 1;
							}
							print $fout Encode::encode_utf8($copy);
							close $fout;
							# Do INSERT OR REPLACE in case another program has
							# got in first,
							$query = "INSERT OR REPLACE INTO fcgi_buffer(key, language, browser_type, path, uri, creation) VALUES(?, ?, ?, ?, ?, strftime('\%s','now'))";
							if($self->{logger}) {
								$self->{logger}->debug("$query: $key, $language, $browser_type, $path, $request_uri");
							}
							$dbh->prepare($query)->execute($key, $language, $browser_type, $path, $request_uri);

							if($changes && (my $ttl = $self->{save_to}->{ttl})) {
								push @{$self->{o}}, 'Expires: ' . HTTP::Date::time2str(time + $ttl);
							}
						} else {
							if($self->{logger}) {
								$self->{logger}->warn("Can't create $path");
							}
						}
					}
				}
				if($self->{generate_last_modified}) {
					$self->{cobject} = $self->{cache}->get_object($key);
					if(defined($self->{cobject})) {
						push @{$self->{o}}, 'Last-Modified: ' . HTTP::Date::time2str($self->{cobject}->created_at());
					} else {
						push @{$self->{o}}, 'Last-Modified: ' . HTTP::Date::time2str(time);
					}
				}
			}
			push @{$self->{o}}, @{$self->_x_cache_headers(defined($self->{x_cache}) ? $self->{x_cache} : 'MISS', 'MISS')}, "X-FCGI-Buffer-$VERSION: Miss";
		}
		# We don't need it any more, so give Perl a chance to
		# tidy it up seeing as we're in the destructor
		delete $self->{cache};
	} elsif($self->{info}) {
		push @{$self->{o}}, @{$self->_x_cache_headers('MISS', 'MISS')};
		if($self->{generate_last_modified}) {
			if(my $age = $self->_my_age()) {
				push @{$self->{o}}, 'Last-Modified: ' . HTTP::Date::time2str($age);
			}
		}
		# _check_modified_since() checks generate_304 itself
		if($ENV{'HTTP_IF_MODIFIED_SINCE'} && ($self->{status} != 304)) {
			$self->_check_modified_since({
				since => $ENV{'HTTP_IF_MODIFIED_SINCE'},
				modified => $self->_my_age()
			});
		}
		if($self->_save_to($unzipped_body, $dbh) && $encoding) {
			$self->_compress({ encoding => $encoding });
		}
	} else {
		push @{$self->{o}}, @{$self->_x_cache_headers('MISS', 'MISS')};
	}

	# The branch that was taken when there was no ETag had an empty body,
	# but called is_cached() which looks in the cache, so it is removed
	if($self->{generate_etag} && defined($self->{etag}) && ((!defined($headers)) || ($headers !~ /^ETag: /m))) {
		push @{$self->{o}}, "ETag: $self->{etag}";
		if($self->{logger}) {
			$self->{logger}->debug("Set ETag to $self->{etag}");
		}
	}

	my $body_length = 0;
	if(defined($self->{body})) {
		if(utf8::is_utf8($self->{body})) {
			utf8::encode($self->{body});
		}
		$body_length = length($self->{body});
	}

	if(defined($headers) && length($headers)) {
		# Put the original headers first, then those generated within
		# FCGI::Buffer
		unshift @{$self->{o}}, split(/\r\n/, $headers);
		if($self->{body} && $self->{send_body}) {
			unless(grep(/^Content-Length: \d/, @{$self->{o}})) {
				push @{$self->{o}}, "Content-Length: $body_length";
			}
		}
		unless(grep(/^Status: \d/, @{$self->{o}})) {
			require HTTP::Status;
			HTTP::Status->import();

			push @{$self->{o}}, 'Status: ' . $self->{status} . ' ' . HTTP::Status::status_message($self->{status});
			$self->_set_status($self->{status});
		}
	} else {
		push @{$self->{o}}, "X-FCGI-Buffer-$VERSION: No headers";
	}

	if($body_length && $self->{send_body}) {
		push @{$self->{o}}, ('', $self->{body});
	}

	# The Wide character debugging code that was here was inside if(0), so
	# could never run
	if(scalar(@{$self->{o}})) {
		print join("\r\n", @{$self->{o}});
	}

	if(!($self->{send_body} && defined($self->{body}))) {
		print "\r\n\r\n";
	}
}

sub _generate_etag {
	my $self = shift;

	return if defined($self->{'etag'});
	return unless defined($self->{'body'});

	if(!defined($self->{_encode_loaded})) {
		# encode to avoid "Wide character in subroutine entry"
		require Encode;
		$self->{_encode_loaded} = 1;
	}
	$self->{etag} = '"' . Digest::MD5->new->add(Encode::encode_utf8($self->{body}))->hexdigest() . '"';
	if($self->{'logger'}) {
		$self->{'logger'}->debug('Etag = ', $self->{'etag'});
	}
}

sub _check_modified_since {
	my $self = shift;

	if($self->{logger}) {
		$self->{logger}->trace('In _check_modified_since');
	}

	if(!$self->{generate_304}) {
		return;
	}
	my $params = shift;

	if(!defined($$params{since})) {
		return;
	}
	my $s = HTTP::Date::str2time($$params{since});
	if(!defined($s)) {
		if($self->{logger}) {
			$self->{logger}->info("$$params{since} is not a valid date");
		}
		return;
	}

	my $age = $self->_my_age();
	if(!defined($age)) {
		if($self->{logger}) {
			$self->{logger}->info("Can't determine my age");
		}
		return;
	}
	if($age > $s) {
		if($self->{logger}) {
			$self->{logger}->debug('_check_modified_since: script has been modified');
		}
		# Script has been updated so it may produce different output
		return;
	}

	if($self->{logger}) {
		$self->{logger}->debug("_check_modified_since: Compare $$params{modified} with $s");
	}
	if($$params{modified} <= $s) {
		push @{$self->{o}}, 'Status: 304 Not Modified';
		$self->_set_status(304);
		$self->{send_body} = 0;
		if($self->{logger}) {
			$self->{logger}->debug('Set status to 304');
		}
	}
}

# Reduce output, e.g. remove superfluous white-space.
sub _optimise_content {
	my $self = shift;

	# FIXME: regex bad, HTML parser good
	# Regexp::List - wow!
	# Remove whitespace around newlines.  Possessive quantifiers and only
	# starting at the beginning of a run of whitespace keep it linear
	$self->{body} =~ s{
		(?<![^\S\n])	# start only at the beginning of a whitespace run
		[^\S\n]*+	# trailing spaces, tabs and \r before the newline
		\n
		\s*+		# blank lines and indentation after it
	}{\n}gx;
	# $self->{body} =~ s/\r\n/\n/gs;
	# $self->{body} =~ s/\s+\n/\n/gs;
	# $self->{body} =~ s/\n+/\n/gs;
	# $self->{body} =~ s/\n\s+|\s+\n/\n/g;
	$self->{body} =~ s/\<\/div\>\s+\<div/\<\/div\>\<div/gis;
	# $self->{body} =~ s/\<\/p\>\s\<\/div/\<\/p\>\<\/div/gis;
	# $self->{body} =~ s/\<div\>\s+/\<div\>/gis;	# Remove spaces after <div>
	# In these, (?<!\s) and possessive quantifiers stop each alternation
	# being retried at every position inside a long run of whitespace
	$self->{body} =~ s/(?:<div>\s++|(?<!\s)\s++<div>)/<div>/gi;
	$self->{body} =~ s/\s+<\/div\>/\<\/div\>/gis;	# Remove spaces before </div>
	$self->{body} =~ s/(?:(?<!\s)\s++<p>|<p>\s++)/<p>/i;	# TODO <p class=
	$self->{body} =~ s/(?:(?<!\s)\s++<\/p>|<\/p>\s++)/<\/p>/gi;
	$self->{body} =~ s/<html>\s+<head>/<html><head>/is;
	$self->{body} =~ s/(?<!\s)\s*+<\/head>\s++<body>\s*+/<\/head><body>/i;
	$self->{body} =~ s/<html>\s+<body>/<html><body>/is;
	$self->{body} =~ s/<body>\s+/<body>/is;
	$self->{body} =~ s/\s+\<\/html/\<\/html/is;
	$self->{body} =~ s/\s+\<\/body/\<\/body/is;
	# $self->{body} =~ s/(\<.+?\>\s\<.+?\>)\s/$1/g;
	$self->{body} =~ s/\<p\>\s/\<p\>/gi;
	$self->{body} =~ s/\<\/p\>\s\<p\>/\<\/p\>\<p\>/gi;
	$self->{body} =~ s/\<\/tr\>\s\<tr\>/\<\/tr\>\<tr\>/gi;
	$self->{body} =~ s/\<\/td\>\s\<\/tr\>/\<\/td\>\<\/tr\>/gi;
	$self->{body} =~ s/\<\/td\>\s*\<td\>/\<\/td\>\<td\>/gis;
	$self->{body} =~ s/\<\/tr\>\s\<\/table\>/\<\/tr\>\<\/table\>/gi;
	$self->{body} =~ s/\<br\s?\/?\>\s?\<p\>/\<p\>/gi;
	$self->{body} =~ s/\<br\>\s+/\<br\>/gi;
	$self->{body} =~ s/\s+\<br/\<br/gi;
	$self->{body} =~ s/\<br\s?\/\>\s/\<br \/\>/gi;
	$self->{body} =~ s/[ \t]+/ /gs;	# Remove duplicate space, don't use \s+ it breaks JavaScript
	$self->{body} =~ s/\s\<p\>/\<p\>/gi;
	$self->{body} =~ s/\s\<script/\<script/gi;
	$self->{body} =~ s/(<script>\s|\s<script>)/<script>/gis;
	$self->{body} =~ s/(<\/script>\s|\s<\/script>)/<\/script>/gis;
	$self->{body} =~ s/\<td\>\s/\<td\>/gi;
	# The link can't leave its quotes, so these can't span tags or
	# backtrack across the rest of the page
	$self->{body} =~ s{
		(?<!\s)\s++		# a whole run of whitespace, starting at its first character
		<a\shref="([^"]*+)">	# $1: the link
		\s?
	}{ <a href="$1">}gix;
	$self->{body} =~ s{
		\s?
		<a\shref=\s"([^"]*+)">	# $1: the link
	}{ <a href="$1">}gix;
	$self->{body} =~ s/\s+<\/a\>\s+/<\/a> /gis;
	$self->{body} =~ s/(?:\s?<hr>\s++|(?<!\s)\s++<hr>\s?)/<hr>/gi;
	# $self->{body} =~ s/\s<hr>/<hr>/gis;
	# $self->{body} =~ s/<hr>\s/<hr>/gis;
	$self->{body} =~ s/<\/li>\s+<li>/<\/li><li>/gis;
	$self->{body} =~ s/<\/li>\s+<\/ul>/<\/li><\/ul>/gis;
	$self->{body} =~ s/<ul>\s+<li>/<ul><li>/gis;
	$self->{body} =~ s/\s+<\/li>/<\/li>/gis;
	$self->{body} =~ s/\<\/option\>\s+\<option/\<\/option\>\<option/gis;
	$self->{body} =~ s/<title>\s*(.+?)\s*<\/title>/<title>$1<\/title>/is;
	$self->{body} =~ s/<\/center>\s+<center>/ /gis;
}

# Create a key for the cache
sub _generate_key {
	my $self = shift;
	if($self->{cache_key}) {
		return $self->{cache_key};
	}
	$self->_info();

	my $key = __PACKAGE__ . '::' . $self->{info}->browser_type() . '::' . $self->{info}->domain_name() . '::' . $self->{info}->script_name() . '::' . $self->{info}->as_string();

	if(defined($ENV{'PATH_INFO'}) && length($ENV{'PATH_INFO'})) {
		# /cgi-bin/foo.fcgi/bar and /cgi-bin/foo.fcgi/baz are different pages
		$key .= '::PATH_INFO=' . $ENV{'PATH_INFO'};
	}
	if($self->{lingua}) {
		$key .= '::' . $self->{lingua}->language();
	}
	if($ENV{'HTTP_COOKIE'}) {
		# Different states of the client are stored in different caches
		# Don't put different Google Analytics in different caches, and anyway they
		# would be wrong
		foreach my $cookie(split(/;\s*/, $ENV{'HTTP_COOKIE'})) {
			unless($cookie =~ /^__utm[abcz]/) {
				$key .= "::$cookie";
				$self->{_key_is_per_client} = 1;
			}
		}
	}

	# Honour the Vary headers
	my $headers = $self->{'headers'};
	if($headers && ($headers =~ /^Vary: /m)) {
		if(defined($self->{logger})) {
			$self->{logger}->debug('Found Vary header');
		}
		foreach my $h1(split(/\r?\n/, $headers)) {
			my ($h1_name, $h1_value) = split /\:\s*/, $h1, 2;
			if(lc($h1_name) eq 'vary') {
				foreach my $h2(split(/\r?\n/, $headers)) {
					my ($h2_name, $h2_value) = split /\:\s*/, $h2, 2;
					if($h2_name eq $h1_value) {
						$key .= "::$h2_value";
						$self->{_key_is_per_client} = 1;
						last;
					}
				}
			}
		}
	}
	$key =~ s/\//::/g;
	$key =~ s/(?:::){2,}/::/g;
	$key =~ s/::$//;
	if(defined($self->{logger})) {
		$self->{logger}->trace("Returning $key");
	}
	$self->{cache_key} = $key;
	return $key;
}

=head2 init

Set various options and override default values.

    # Put this toward the top of your program before you do anything
    # By default, generate_tag, generate_304 and compress_content are ON,
    # optimise_content and lint_content are OFF.  Set optimise_content to 2 to
    # do aggressive JavaScript optimisations which may fail.
    use FCGI::Buffer;

    my $buffer = FCGI::Buffer->new()->init({
	generate_etag => 1,	# make good use of client's cache
	generate_last_modified => 1,	# more use of client's cache
	compress_content => 1,	# if gzip the output
	optimise_content => 0,	# optimise your program's HTML, CSS and JavaScript
	cache => CHI->new(driver => 'File'),	# cache requests
	cache_key => 'string',	# key for the cache
	cache_duration => '10 minutes',	# how long to store responses in the cache
	logger => $self->{logger},
	lint_content => 0,	# Pass through HTML::Lint
	generate_304 => 1,	# When appropriate, generate 304: Not modified
	save_to => { directory => '/var/www/htdocs/save_to', ttl => 600, create_table => 1 },
	info => CGI::Info->new(),
	lingua => CGI::Lingua->new(),
    });

If no cache_key is given, one will be generated which may not be unique.
The cache_key should be a unique value dependent upon the values set by the
browser.

The cache object will be an object that understands get_object(),
set(), remove() and created_at() messages, such as an L<CHI> object. It is
used as a server-side cache to reduce the need to rerun database accesses.

Items stay in the server-side cache by default for 10 minutes.
This can be overridden by the cache_control HTTP header in the request, and
the default can be changed by the cache_duration argument to init().

Save_to is feature which stores output of dynamic pages to your
htdocs tree and replaces future links that point to that page with static links
to avoid going through CGI at all.
Ttl is set to the number of seconds that the static pages are deemed to
be live for, the default is 10 minutes.
If set to 0, the page is live forever.
To enable save_to, an info argument must also be given,
and a lingua argument should be given if the output depends on the language.
It works best when cache is also given.
The directory must be inside the document root,
otherwise the static pages can't be linked to.
Only use where output is guaranteed to be the same with a given set of arguments
(the same criteria for enabling generate_304).
Pages generated for clients that send cookies (other than Google Analytics
cookies), or whose output depends on a Vary header, are not saved,
since the static page would be given to everyone.
You can turn it off on a case by case basis thus:

    my $params = CGI::Info->new()->params();
    if($params->{'send_private_email'}) {
        $buffer->init('save_to' => undef);
    }

Info is an optional argument to give information about the FCGI environment, e.g.
a L<CGI::Info> object.

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

If you give a cache to init() then later give cache => undef,
the server-side cache is no longer used.
This is useful when you find an error condition when creating your HTML
and decide that you no longer wish to store the output in the cache.

=cut

sub init {
	my $self = shift;
	my %params = (ref($_[0]) eq 'HASH') ? %{$_[0]} : @_;

	# Safe options - can be called at any time
	foreach my $option(@SAFE_OPTIONS) {
		if(defined($params{$option})) {
			$self->{$option} = $params{$option};
		}
	}

	if(defined($params{save_to}) && $self->can_cache()) {
		if(my $dir = $params{'save_to'}->{'directory'}) {
			if(! -d $dir) {
				mkdir $dir;
				if(! -d $dir) {
					Carp::carp("$dir isn't a directory");
					return;
				}
			}
			if(! -w $dir) {
				Carp::carp("$dir isn't writeable");
				return;
			}
		}
		$self->{save_to} = $params{save_to};
		if(!exists($params{save_to}->{'ttl'})) {
			$self->{save_to}->{'ttl'} = $DEFAULT_SAVE_TO_TTL;
		}
	} elsif(exists($params{'save_to'}) && !defined($params{'save_to'})) {
		delete $self->{'save_to'};
	}
	if(defined($params{info}) && (!defined($self->{info}))) {
		$self->{info} = $params{info};
	}

	# Unsafe options - must be called before output has been started
	my $pos = $self->{buf}->getpos;
	if($pos > 0) {
		if(defined($self->{logger})) {
			my @call_details = caller(0);
			$self->{logger}->warn("Too late to call init, $pos characters have been printed, caller line $call_details[2] of $call_details[1]");
		} else {
			# Must do Carp::carp instead of carp for Test::Carp
			Carp::carp "Too late to call init, $pos characters have been printed";
		}
	}
	if(exists($params{cache}) && $self->can_cache()) {
		# There is an argument not to do this since one client will
		# affect others
		if(defined(my $max_age = _cache_control()->{'max-age'})) {
			$self->{cache_duration} = "$max_age seconds";
			if(defined($self->{logger})) {
				$self->{logger}->debug("cache_duration = $self->{cache_duration}");
			}
		}
		$self->{cache_duration} ||= $params{cache_duration};
		if(defined($params{cache})) {
			$self->{cache} = $params{cache};
		} else {
			if(defined($self->{logger}) && defined($self->{cache})) {
				$self->{logger}->debug('disabling cache', ($self->{cache_key} ? " $self->{cache_key}" : ''));
			}
			delete $self->{cache};
		}
		if(defined($params{cache_key})) {
			$self->{cache_key} = $params{cache_key};
		}
	}

	return $self;
}

sub import {
	# my $class = shift;
	shift;

	return unless scalar(@_);

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
This is the value of X-Cache in the returned header.

The cache isn't used if the NO_CACHE or NO_STORE environment variables are set,
or if the client's Cache-Control header includes any of no-store, no-cache,
private or max-age=0.
The answer is decided on the first call, and doesn't change for the rest of the
request.

=head2 How the output is sent

=over 4

=item * Compression

The first encoding listed by the client (in Accept-Encoding, or TE) that
FCGI::Buffer can produce is used.
Encodings with q=0 are skipped.

Premise 1: the client is happy with any of the encodings that it lists.
Premise 2: an encoding can only be produced if its module is installed.
Conclusion: an encoding whose module isn't installed is passed over for the
next one, rather than failing the request.
If none can be used, the output is sent uncompressed.

=item * Range

A single range of bytes, such as C<bytes=0-99> or C<bytes=100->, is honoured
with a 206 status.
Anything else, such as several ranges or a backwards range, is ignored and the
whole page is sent.
Note that C<bytes=-n> gives the first n bytes, although RFC 7233 says that it
should be the last n.

=item * Conditional requests

If-None-Match may be a list of ETags, weak ETags or "*".
If it is given and doesn't match, If-Modified-Since is not used to send a 304.

=back

=cut

sub can_cache {
	my $self = shift;

	if(defined($self->{x_cache})) {
		return ($self->{x_cache} eq 'HIT');
	}
	if(defined($self->{logger}) && defined($ENV{'HTTP_CACHE_CONTROL'})) {
		$self->{logger}->debug("cache_control = $ENV{HTTP_CACHE_CONTROL}");
	}

	# TODO: check Authorization header not present
	# A request may give several directives, e.g. "no-cache, max-age=0",
	# and any one of them forbids the cache
	my $control = _cache_control();
	my $forbidden = defined($ENV{'NO_CACHE'}) || defined($ENV{'NO_STORE'}) ||
		(grep { $NO_CACHE_DIRECTIVES{$_} } keys %{$control}) ||
		(defined($control->{'max-age'}) && ($control->{'max-age'} == 0));

	$self->{x_cache} = $forbidden ? 'MISS' : 'HIT';
	return $forbidden ? 0 : 1;
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

    # To use server-side caching you must give the cache argument, however
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
			my $i = 0;
                        while((my @call_details = (caller($i++)))) {
                                $self->{logger}->debug($call_details[1], ':', $call_details[2], ' calling function ', $call_details[3]);
                        }
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
		delete $self->{cobject};
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
		delete $self->{cobject};
		return 0;
	}
	if($age > $self->{cobject}->created_at()) {
		# Script has been updated so it may produce different output
		if($self->{logger}) {
			$self->{logger}->debug('Script has been updated');
		}
		delete $self->{cobject};
		# Nothing will be in date and all new searches would miss
		# anyway, so may as well clear it all
		# FIXME: RT104471
		# $self->{cache}->clear();
		return 0;
	}
	if($self->{logger}) {
		$self->{logger}->debug('Script is in the cache');
	}
	return 1;
}

# Determine the last modification time of the script and cache it for subsequent calls
sub _my_age {
	my $self = shift;

	return $self->{script_mtime} if(defined($self->{script_mtime}));

	# croak() never returns, so nothing is needed after it
	my $path = $self->_info()->script_path();
	croak 'Failed to retrieve script path' unless(defined($path));

	my @statb = stat($path);
	$self->{'script_mtime'} = $statb[9];	# Set script_mtime to the modification time of the script
	return $self->{script_mtime};
}

# Return the content encoding to use, or '' for none.
# Premise 1: _compress() fails the request with a 406 if it can't load the
#	module for the encoding
# Premise 2: the client is happy with any of the encodings it lists
# Conclusion: choose the first listed encoding that can be loaded, then the 406
#	can't happen
sub _should_gzip
{
	my $self = shift;

	return '' unless($self->{compress_content});
	my $accept = $ENV{'HTTP_ACCEPT_ENCODING'} || $ENV{'HTTP_TE'};
	return '' unless($accept);
	return '' if(defined($self->{content_type}) && (lc($self->{content_type}->[0]) ne 'text'));

	foreach my $method(split(/\s*,\s*/, lc($accept))) {
		# e.g. "gzip;q=0.8", where q=0 means "not acceptable"
		my ($name, @params) = split(/\s*;\s*/, $method);
		next if(grep { /^q=0(?:\.0*)?$/ } @params);
		return $name if($ENCODING_MODULE{$name} && _can_load($ENCODING_MODULE{$name}));
	}

	return '';
}

# Can the given module be loaded?  The answer is remembered
{
	my %loadable;

	sub _can_load
	{
		my $module = shift;

		if(!exists($loadable{$module})) {
			$loadable{$module} = eval "require $module; 1" ? 1 : 0;
		}
		return $loadable{$module};
	}
}

sub _set_content_type
{
	my $self = shift;
	my $headers = shift;

	foreach my $header (split(/\r?\n/, $headers)) {
		my ($header_name, $header_value) = split /\:\s*/, $header, 2;
		if(lc($header_name) eq 'content-type') {
			my @content_type = split /\//, $header_value, 2;
			$self->{content_type} = \@content_type;
			return;
		}
	}
}

# Compress the body with the given encoding, from _should_gzip()
sub _compress
{
	my $self = shift;
	my %params = (ref($_[0]) eq 'HASH') ? %{$_[0]} : @_;

	my $encoding = $params{encoding};

	return unless(defined($self->{'body'}) && defined($encoding) && length($encoding));
	return if(length($self->{body}) < $MIN_GZIP_LEN);

	# Premise: _should_gzip() only returns encodings whose module loads
	# Conclusion: if one can't be loaded here, the request can't be met
	my $module = $ENCODING_MODULE{$encoding};
	if((!defined($module)) || !_can_load($module)) {
		$self->_set_status(406);
		return;
	}

	# Avoid 'Wide character in memGzip'
	require Encode;
	my $bytes = Encode::encode_utf8($self->{body});
	my $compressed;
	if($module eq 'Compress::Zlib') {
		$compressed = Compress::Zlib::memGzip(\$bytes);
	} elsif($module eq 'Compress::Zstd') {
		# Facebook
		$compressed = Compress::Zstd::compress(\$bytes);
	} else {
		$compressed = IO::Compress::Brotli::bro($bytes);
	}

	# Don't send it compressed if that makes it larger
	return unless(defined($compressed) && (length($compressed) < length($self->{body})));

	$self->{body} = $compressed;
	$encoding = 'gzip' if($encoding eq 'x-gzip');
	foreach my $header("Content-Encoding: $encoding", 'Vary: Accept-Encoding') {
		push @{$self->{o}}, $header unless(grep { $_ eq $header } @{$self->{o}});
	}
}

sub _check_if_none_match {
	my $self = shift;

	if($ENV{'HTTP_IF_NONE_MATCH'} && defined($self->{etag})) {
		if($self->{logger}) {
			$self->{logger}->debug("Compare $ENV{HTTP_IF_NONE_MATCH} with $self->{etag}");
		}
		# The header is "*" or a list of entity tags, any of which may be weak
		my @etags = map { (my $e = $_) =~ s/^W\///; $e } split(/\s*,\s*/, $ENV{'HTTP_IF_NONE_MATCH'});
		if(grep { ($_ eq '*') || ($_ eq $self->{etag}) } @etags) {
			push @{$self->{o}}, 'Status: 304 Not Modified';
			$self->{send_body} = 0;
			$self->_set_status(304);
			if($self->{logger}) {
				$self->{logger}->debug('Set status to 304');
			}
			return 1;
		}
	}
	if($self->{cache} && $self->{logger} && $self->{logger}->is_debug()) {
		my $cached_copy = $self->{cache}->get($self->_generate_key());

		if($cached_copy && $self->{body}) {
			require Text::Diff;
			Text::Diff->import();

			$cached_copy = Storable::thaw($cached_copy)->{body};
			my $diffs = diff(\$self->{body}, \$cached_copy);
			$self->{logger}->debug('diffs: ', $diffs);
		} else {
			$self->{logger}->debug('Nothing to compare');
		}
	}
	return 0;
}

# The CGI::Info object, which is created if it wasn't given
sub _info {
	my $self = shift;

	if(!defined($self->{info})) {
		$self->{info} = CGI::Info->new($self->{cache} ? { cache => $self->{cache} } : ())
			or croak(__PACKAGE__, ': Failed to create CGI::Info object');
	}
	return $self->{info};
}

# Set the HTTP status, and tell CGI::Info if we have one
sub _set_status {
	my ($self, $status) = @_;

	$self->{status} = $status;
	if($self->{info}) {
		$self->{info}->status($status);
	}
}

# Does the protocol support conditional requests (ETag etc.)?
sub _is_conditional_protocol {
	return defined($ENV{'SERVER_PROTOCOL'}) && ($ENV{'SERVER_PROTOCOL'} =~ $CONDITIONAL_PROTOCOL);
}

# The directives in the request's Cache-Control header, as a hashref of
# lower case name to value (undef when there is no value)
sub _cache_control {
	my %directives;

	if(defined(my $control = $ENV{'HTTP_CACHE_CONTROL'})) {
		foreach my $directive(split(/\s*,\s*/, lc($control))) {
			my ($name, $value) = split(/\s*=\s*/, $directive, 2);
			next unless(defined($name) && length($name));
			$value =~ s/^"(.*)"$/$1/ if(defined($value));
			$directives{$name} = $value;
		}
	}
	return \%directives;
}

# The X-Cache and X-Cache-Lookup headers, as an arrayref
sub _x_cache_headers {
	my ($self, $cache, $lookup) = @_;

	my $from = $self->{info} ? ' from ' . $self->{info}->host_name() : '';
	return [ "X-Cache: $cache$from", "X-Cache-Lookup: $lookup$from" ];
}

# Return the part of the body asked for by a Range header, or undef if the
# range isn't one that we support, in which case the whole body is sent.
# Only a single range of bytes is supported.
# Note that "bytes=-n" is treated as the first n bytes, though RFC 7233 says
# that it is the last n
sub _apply_range {
	my ($body, $range) = @_;

	return unless($range =~ /^bytes=(\d*)-(\d*)$/);
	my ($first, $last) = ($1, $2);

	# "bytes=-" says nothing
	return if(($first eq '') && ($last eq ''));
	return substr($body, 0, $last) if($first eq '');
	return substr($body, $first) if($last eq '');

	# A backwards range is invalid
	return if($first > $last);

	# The range includes both ends
	return substr($body, $first, $last - $first + 1);
}

# replace dynamic links with static links
sub _save_to {
	my ($self, $unzipped_body, $dbh) = @_;

	return 0 unless($dbh && $self->{info} && (my $request_uri = $ENV{'REQUEST_URI'}));
	return 0 if(!defined($unzipped_body));

	my $query;
	my $copy = $unzipped_body;
	my $changes = 0;
	my $creation;
	my %seen_links;
	my $language = $self->_save_to_language();
	my $browser_type = $self->{info}->browser_type();
	while($unzipped_body =~ /<a\s+href="([^"]+)"/gi) {
		my $link = $1;
		next if($seen_links{$link});	# Already updated in the copy
		$seen_links{$link} = 1;

		# The link is as it appears in the HTML, the database holds
		# the REQUEST_URI
		my $search_uri = $link;
		$search_uri =~ s/&amp;/&/g;
		if($search_uri =~ /^\?/) {
			# CGI script has links to itself
			# $search_uri = "${request_uri}${link}";
			my $r = $request_uri;
			$r =~ s/\?.*$//;
			$search_uri = "${r}$search_uri";
		} else {
			next if($link =~ /^https?:\/\//);	# FIXME: skips full URLs to ourself
								#	Though optimise_content fixes that
			next if($link =~ /\.(?:html?|jpg|gif)$/i);
		}
		if($self->{save_to}->{ttl}) {
			$query = "SELECT DISTINCT path, creation FROM fcgi_buffer WHERE uri = ? AND language = ? AND browser_type = ? AND creation >= strftime('\%s','now') - ?";
		} else {
			$query = 'SELECT DISTINCT path, creation FROM fcgi_buffer WHERE uri = ? AND language = ? AND browser_type = ?';
		}
		if($self->{logger}) {
			$self->{logger}->debug("$query: $search_uri, $language, $browser_type");
		}
		if(defined(my $sth = $dbh->prepare($query))) {
			if($self->{save_to}->{ttl}) {
				$sth->execute($search_uri, $language, $browser_type, $self->{save_to}->{ttl});
			} else {
				$sth->execute($search_uri, $language, $browser_type);
			}
			if(my $href = $sth->fetchrow_hashref()) {
				if(my $path = $href->{'path'}) {
					if(-r $path) {
						my $url = $self->_path_to_url($path);
						if(!defined($url)) {
							if($self->{logger}) {
								$self->{logger}->warn("$path is not under the document root, can't link to it");
							}
							next;
						}
						if($self->{logger}) {
							$self->{logger}->debug("Changing links from $link to $url");
						}
						$changes += ($copy =~ s/((?i:<a\s+href="))\Q$link\E"/$1$url"/g);
						# Find the first link that will expire and use that
						if((!defined($creation)) || ($href->{'creation'} < $creation)) {
							$creation = $href->{'creation'};
						}
					} else {
						$query = 'DELETE FROM fcgi_buffer WHERE path = ?';
						$dbh->prepare($query)->execute($path);
						if($self->{logger}) {
							$self->{logger}->warn("Remove entry for non-existant file $path");
						}
					}
				}
			}
		} elsif($self->{logger}) {
			$self->{logger}->warn("failed to prepare '$query'");
		}
	}
	my $expiration = 0;
	if(defined($creation) && (my $ttl = $self->{save_to}->{ttl})) {
		$expiration = $creation + $ttl;
	}
	if($changes && (($expiration == 0) || ($expiration >= time))) {
		if($self->{logger}) {
			# $self->{logger}->debug("$changes links now point to static pages");
			if($changes == 1) {
				if($self->{'save_to'}->{'ttl'}) {
					$self->{logger}->info('1 link now points to a static page for ', $expiration - time, 's');
				} else {
					$self->{logger}->info('1 link now points to a static page');
				}
			} else {
				$self->{logger}->info("$changes links now point to static pages");
			}
		}
		$unzipped_body = $copy;
		$self->{'body'} = $unzipped_body;
		if(my $ttl = $self->{save_to}->{ttl}) {
			push @{$self->{o}}, 'Expires: ' . HTTP::Date::time2str($creation + $ttl);
		}
	} elsif($expiration && ($expiration < time)) {
		# Delete the save_to files
		if($self->{save_to}->{ttl}) {
			$query = "SELECT path FROM fcgi_buffer WHERE creation < strftime('\%s','now') - ?";
		} else {
			$query = 'SELECT path FROM fcgi_buffer';	# Hmm, I suspect this is overkill
		}
		my $sth = $dbh->prepare($query);
		$sth->execute($self->{save_to}->{ttl} ? ($self->{save_to}->{ttl}) : ());
		while(my $href = $sth->fetchrow_hashref()) {
			if(my $path = $href->{'path'}) {
				if($self->{logger}) {
					$self->{logger}->debug("unlink $path");
				}
				unlink $path;
			}
		}
		if($self->{save_to}->{ttl}) {
			$query = "DELETE FROM fcgi_buffer WHERE creation < strftime('\%s','now') - ?";
		} else {
			$query = 'DELETE FROM fcgi_buffer';	# Hmm, I suspect this is overkill
		}
		if($self->{logger}) {
			$self->{logger}->debug($query);
		}
		$dbh->prepare($query)->execute($self->{save_to}->{ttl} ? ($self->{save_to}->{ttl}) : ());
	# } else {
		# Old code
		# if($self->{save_to}->{ttl}) {
			# $query = "SELECT DISTINCT path, creation FROM fcgi_buffer WHERE key = '$key' AND creation >= strftime('\%s','now') - " . $self->{save_to}->{ttl};
		# } else {
			# $query = "SELECT DISTINCT path, creation FROM fcgi_buffer WHERE key = '$key'";
		# }
		# my $sth = $dbh->prepare($query);
		# $sth->execute();
		# my $href = $sth->fetchrow_hashref();
		# if(my $path = $href->{'path'}) {
			# # FIXME: don't do this if we've passed the TTL, and if we are clean
			# #	up the database and remove the static page
			# $request_uri =~ s/\?/\\?/g;
			# if(($unzipped_body =~ s/<a href="$request_uri"/<a href="$path"/gi) > 0) {
				# $self->{'body'} = $unzipped_body;
				# if(my $ttl = $self->{save_to}->{ttl}) {
					# push @{$self->{o}}, 'Expires: ' . HTTP::Date::time2str($href->{creation} + $ttl);
				# }
			# }
		# }
	}
	return $changes;
}

# The language as stored in the save_to database
sub _save_to_language {
	my $self = shift;

	if($self->{'lingua'}) {
		my $language = $self->{'lingua'}->language();
		return $language if(defined($language) && length($language));
	}
	return 'default';
}

# Make a string safe to use as a file or directory name, and in a URL.
# If anything had to be changed, a digest of the original is appended so that
# different strings don't map onto the same file
sub _safe_filename {
	my $name = shift;

	require Encode;

	my $safe = $name;
	$safe =~ s/[^A-Za-z0-9=_.,+-]/_/g;
	$safe =~ s/^\./_/;
	if(($safe ne $name) || (length($safe) > 200)) {
		$safe = substr($safe, 0, 200) . '-' . substr(Digest::MD5::md5_hex(Encode::encode_utf8($name)), 0, 8);
	}
	if($safe =~ /^(.+)$/) {
		$safe = $1;	# Untaint
	}
	return $safe;
}

# The basename of the static page for this request
sub _save_to_filename {
	my $self = shift;

	my $name = $self->{'info'}->as_string();
	if(defined($name) && length($name)) {
		# Keep the historical "arg1=a_arg2=b" naming
		$name =~ s/;\s*/_/g;
	} else {
		# An empty name would give a hidden file
		$name = 'index';
	}
	if(defined($ENV{'PATH_INFO'}) && length($ENV{'PATH_INFO'})) {
		$name = "$ENV{PATH_INFO}_$name";
	}
	return _safe_filename($name);
}

# Convert the filename of a static page into the URL used to reach it, or undef
# if it isn't under the document root
sub _path_to_url {
	my ($self, $path) = @_;

	my $rootdir = $self->{'info'}->rootdir();
	return unless(defined($rootdir) && length($rootdir));

	require Cwd;
	foreach my $p(\$rootdir, \$path) {
		my $real = Cwd::realpath(${$p});
		${$p} = File::Spec->canonpath(defined($real) ? $real : ${$p});
	}

	my @root = File::Spec->splitdir($rootdir);
	my @dirs = File::Spec->splitdir($path);
	pop @root if(@root && ($root[-1] eq ''));

	return if(scalar(@dirs) <= scalar(@root));
	foreach my $d(@root) {
		my $p = shift @dirs;
		return if(($^O eq 'MSWin32') ? (lc($d) ne lc($p)) : ($d ne $p));
	}

	require Encode;
	return join('/', '', map {
		my $s = Encode::encode_utf8($_);
		$s =~ s/([^A-Za-z0-9\-._~=,+])/sprintf('%%%02X', ord($1))/ge;
		$s
	} @dirs);
}

=head1 AUTHOR

Nigel Horne, C<< <njh at nigelhorne.com> >>

=head1 BUGS

FCGI::Buffer should be safe even in scripts that produce lots of different
output, e.g. e-commerce situations.
On such pages, however, I strongly urge setting generate_304 to 0 and
sending the HTTP header "Cache-Control: no-cache".

When using L<Template>, ensure that you don't use it to output to STDOUT,
instead,
you will need to capture into a variable and print that.
For example:

    my $output;
    $template->process($input, $vars, \$output) || ($output = $template->error());
    print $output;

Can produce buggy JavaScript if you use the <!-- HIDING technique.
This is a bug in L<JavaScript::Packer>, not FCGI::Buffer.

Mod_deflate can confuse this when compressing output.
Ensure that deflation is off for .pl files:

    SetEnvIfNoCase Request_URI \.(?:gif|jpe?g|png|pl)$ no-gzip dont-vary

If you request compressed output then uncompressed output (or vice
versa) on input that produces the same output, the status will be 304.
The letter of the spec says that's wrong, so I'm noting it here, but
in practice, you should not see this happen or have any difficulties
because of it.

FCGI::Buffer has not been tested against FastCGI.

I advise adding FCGI::Buffer as the last use statement so that it is
cleared up first.  In particular, it should be loaded after
L<Log::Log4perl>, if you're using that, so that any messages it
produces are printed after the HTTP headers have been sent by
FCGI::Buffer;

Save_to doesn't understand links in JavaScript, which means that if you use self-calling
CGIs loaded as a static page,
they may point to the wrong place.
The workaround is to avoid self-calling CGIs in JavaScript

Please report any bugs or feature requests to C<bug-fcgi-buffer at rt.cpan.org>
or through the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=FCGI-Buffer>.
I will be notified, and then you'll automatically be notified of the progress on
your bug as I make changes.

The lint operation only works on HTML4, because of a restriction in L<HTML::Lint>.

=head1 SEE ALSO

L<CGI::Buffer>,
L<HTML::Packer>,
L<HTML::Lint>

=head1 SUPPORT

This module is provided as-is without any warranty.

You can find documentation for this module with the perldoc command.

    perldoc FCGI::Buffer

You can also look for information at:

=over 4

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=FCGI-Buffer>

=item * Search CPAN

L<http://search.cpan.org/dist/FCGI-Buffer/>

=back

=head1 ACKNOWLEDGEMENTS

The inspiration and code for some of this is cgi_buffer by Mark
Nottingham: L<https://www.mnot.net/blog/2003/04/24/etags>.

=head1 LICENSE AND COPYRIGHT

The licence for cgi_buffer is:

    "(c) 2000 Copyright Mark Nottingham <mnot@pobox.com>

    This software may be freely distributed, modified and used,
    provided that this copyright notice remain intact.

    This software is provided 'as is' without warranty of any kind."

The rest of the program is Copyright 2015-2026 Nigel Horne,
and is released under the following licence: GPL2

=cut

1; # End of FCGI::Buffer
