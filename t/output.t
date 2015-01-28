#!perl -w

# Test if FCGI::Buffer adds Content-Length and Etag headers, also simple
# check that optimise_content does something.

# TODO: check optimise_content and gzips do the *right* thing
# TODO: check ETags are correct
# TODO: Write a test to check that 304 is sent when a cached object
#	is newer than the IF_MODIFIED_SINCE date

use strict;
use warnings;

use Test::Most tests => 73;
use Test::TempDir;
use Compress::Zlib;
use DateTime;
use Capture::Tiny ':all';
# use Test::NoWarnings;	# HTML::Clean has them

BEGIN {
	use_ok('FCGI::Buffer');
}

OUTPUT: {
	delete $ENV{'HTTP_ACCEPT_ENCODING'};
	delete $ENV{'HTTP_TE'};
	delete $ENV{'SERVER_PROTOCOL'};

	sub test1 {
		my $b = new_ok('FCGI::Buffer');

		ok($b->can_cache() == 1);
		ok($b->is_cached() == 0);

		print "Content-type: text/html; charset=ISO-8859-1\n\n";
		print "<HTML><BODY>   Hello, world</BODY></HTML>\n";

		ok($b->is_cached() == 0);
	}

	my ($stdout, $stderr) = capture { test1() };

	ok($stderr eq '');
	ok($stdout !~ /^ETag: "/m);
	ok($stdout !~ /^Content-Encoding: gzip/m);

	my ($headers, $body) = split /\r?\n\r?\n/, $stdout, 2;

	ok($headers =~ /^Content-Length:\s+(\d+)/m);
	my $length = $1;
	ok(defined($length));

	ok($body eq "<HTML><BODY>   Hello, world</BODY></HTML>\n");
	ok(length($body) eq $length);

	sub test2 {
		my $b = new_ok('FCGI::Buffer');

		ok($b->can_cache() == 1);
		ok($b->is_cached() == 0);

		$b->init(optimise_content => 1);

		print "Content-type: text/html; charset=ISO-8859-1\n\n";
		print "<HTML>\n<BODY>\n\t    Hello, world\n  </BODY>\n</HTML>\n";
	}

	($stdout, $stderr) = capture { test2() };

	ok($stderr eq '');
	ok($stdout =~ /^Content-Length:\s+(\d+)/m);
	$length = $1;
	ok(defined($length));
	# Extra spaces should have been removed
	ok($stdout =~ /<HTML><BODY>Hello, world<\/BODY><\/HTML>/mi);
	ok($stdout !~ /^Content-Encoding: gzip/m);
	ok($stdout !~ /^ETag: "/m);

	($headers, $body) = split /\r?\n\r?\n/, $stdout, 2;
	ok(defined($headers));
	ok(defined($body));
	ok(length($body) eq $length);

	$ENV{'HTTP_ACCEPT_ENCODING'} = 'gzip';

	sub test3 {
		my $b = new_ok('FCGI::Buffer');

		ok($b->can_cache() == 1);
		ok($b->is_cached() == 0);

		print "Content-type: text/html; charset=ISO-8859-1\n\n";
		print "<HTML><HEAD>Test</HEAD><BODY><P>Hello, world></BODY></HTML>\n";
	}

	($stdout, $stderr) = capture { test3() };

	ok($stderr eq '');
	ok($stdout =~ /^Content-Length:\s+(\d+)/m);
	$length = $1;
	ok(defined($length));
	# It's not gzipped, because it's so small the gzip version would be
	# bigger
	ok($stdout =~ /<HTML><HEAD>Test<\/HEAD><BODY><P>Hello, world><\/BODY><\/HTML>/m);
	ok($stdout !~ /^Content-Encoding: gzip/m);
	ok($stdout !~ /^ETag: "/m);

	($headers, $body) = split /\r?\n\r?\n/, $stdout, 2;
	ok(length($body) eq $length);

	$ENV{'SERVER_PROTOCOL'} = 'HTTP/1.1';
	delete($ENV{'HTTP_ACCEPT_ENCODING'});
	$ENV{'HTTP_TE'} = 'gzip';

	sub test4 {
		my $b = new_ok('FCGI::Buffer');

		$b->init(optimise_content => 0);

		print "Content-type: text/html; charset=ISO-8859-1\n\n";
		# Put in a large body so that it gzips - small bodies won't
		print "<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 4.01 Transitional//EN\n";
		print "<HTML><HEAD><TITLE>Hello, world</TITLE></HEAD><BODY><P>The quick brown fox jumped over the lazy dog.</P></BODY></HTML>\n";
	}

	($stdout, $stderr) = capture { test4() };

	ok($stderr eq '');
	ok($stdout =~ /^Content-Length:\s+(\d+)/m);
	$length = $1;
	ok(defined($length));
	ok($stdout =~ /^Content-Encoding: gzip/m);
	ok($stdout =~ /ETag: "[A-Za-z0-F0-f]{32}"/m);

	($headers, $body) = split /\r?\n\r?\n/, $stdout, 2;
	ok(length($body) eq $length);
	$body = Compress::Zlib::memGunzip($body);
	ok(defined($body));
	ok($body =~ /<HTML><HEAD><TITLE>Hello, world<\/TITLE><\/HEAD><BODY><P>The quick brown fox jumped over the lazy dog.<\/P><\/BODY><\/HTML>\n$/);

	#..........................................
	delete $ENV{'SERVER_PROTOCOL'};
	delete $ENV{'HTTP_ACCEPT_ENCODING'};

	$ENV{'SERVER_NAME'} = 'www.example.com';

	sub test5 {
		my $b = new_ok('FCGI::Buffer');

		$b->init(optimise_content => 1);

		print "Content-type: text/html; charset=ISO-8859-1\n\n";
		print "<HTML><BODY><A HREF=\"http://www.example.com\">Click</A>\n<script>\nalert(foo);\n</script></BODY></HTML>\n";
	}

	($stdout, $stderr) = capture { test5() };

	ok($stderr eq '');
	ok($stdout !~ /www.example.com/m);
	ok($stdout =~ /href="\/"/m);
	ok($stdout !~ /<script>\s/m);
	ok($stdout =~ /^Content-Length:\s+(\d+)/m);
	$length = $1;
	ok(defined($length));

	($headers, $body) = split /\r?\n\r?\n/, $stdout, 2;
	ok(length($body) eq $length);

	#..........................................
	sub test6 {
		my $b = new_ok('FCGI::Buffer');

		$b->init(optimise_content => 1);

		print "Content-type: text/html; charset=ISO-8859-1\n\n";
		print "<HTML><BODY><A HREF= \"http://www.example.com/foo.htm\">Click</A></BODY></HTML>\n";
	}

	($stdout, $stderr) = capture { test6() };

	ok($stderr eq '');
	ok($stdout !~ /www.example.com/m);
	ok($stdout =~ /href="\/foo.htm"/m);
	ok($stdout =~ /^Content-Length:\s+(\d+)/m);
	$length = $1;
	ok(defined($length));

	($headers, $body) = split /\r?\n\r?\n/, $stdout, 2;
	ok(length($body) eq $length);

	#..........................................
	sub test7 {
		my $b = new_ok('FCGI::Buffer');

		$b->init(optimise_content => 1, lint_content => 1);

		print "Content-type: text/html; charset=ISO-8859-1\n\n";
		print "<HTML><BODY><A HREF= \n\"http://www.example.com/foo.htm\">Click</A></BODY></HTML>\n";
	}

	# Server is www.example.com (set in a previous test), so the href
	# should be optimised, therefore www.example.com shouldn't appear
	# anywhere at all
	($stdout, $stderr) = capture { test7() };

	ok($stderr eq '');
	ok($stdout !~ /www\.example\.com/m);

	($headers, $body) = split /\r?\n\r?\n/, $stdout, 2;

	ok($headers =~ /^Content-Length:\s+(\d+)/m);
	$length = $1;
	ok(defined($length));
	ok(length($body) eq $length);
	ok($body =~ /href="\/foo.htm"/mi);

	#..........................................
	# Check for removal of consecutive white space between links
	sub test8 {
		my $b = new_ok('FCGI::Buffer');

		$b->init(optimise_content => 1, lint_content => 1);

		print "Content-type: text/html; charset=ISO-8859-1\n\n";
		print "<HTML><BODY><A HREF= \n\"http://www.example.com/foo.htm\">Click </A> \n\t<a href=\"http://www.example.com/bar.htm\">Or here</a> </BODY></HTML>\n";
	}

	($stdout, $stderr) = capture { test8() };

	ok($stderr eq '');

	# Server is www.example.com (set in a previous test), so the href
	# should be optimised, therefore www.example.com shouldn't appear
	# anywhere at all
	ok($stdout !~ /www\.example\.com/m);
	ok($stdout =~ /<a href="\/foo\.htm">Click<\/A> <a href="\/bar\.htm">Or here<\/a>/mi);

	($headers, $body) = split /\r?\n\r?\n/, $stdout, 2;

	ok($headers =~ /^Content-Length:\s+(\d+)/m);
	$length = $1;
	ok(defined($length));
	ok(length($body) eq $length);
	ok($body =~ /href="\/foo.htm"/mi);

#	#..........................................
#
#	($tmp, $filename) = tempfile();
#	if($ENV{'PERL5LIB'}) {
#		foreach (split(':', $ENV{'PERL5LIB'})) {
#			print $tmp "use lib '$_';\n";
#		}
#	}
#	print $tmp "use CGI::Buffer;\n";
#	print $tmp "CGI::Buffer::set_options(optimise_content => 1);\n";
#	print $tmp "print \"Content-type: text/html; charset=ISO-8859-1\";\n";
#	print $tmp "print \"\\n\\n\";\n";
#	print $tmp "print \"<HTML><BODY><A HREF=\\\"http://www.example.com/foo.htm\\\">Click</a> <hr> A Line \n<HR>\r\n Foo</BODY></HTML>\\n\";\n";
#
#	open($fout, '-|', "$^X -Iblib/lib " . $filename);
#
#	$keep = $_;
#	undef $/;
#	$stdout = <$fout>;
#	$/ = $keep;
#
#	close $tmp;
#
#	($headers, $body) = split /\r?\n\r?\n/, $stdout, 2;
#	ok($headers =~ /^Content-Length:\s+(\d+)/m);
#	$length = $1;
#	ok(defined($length));
#	ok(length($body) eq $length);
#	ok($headers !~ /^Status: 500/m);
#	ok($body =~ /<hr>A Line<hr>Foo/);
#
#	#..........................................
#	# Space left in tact after </em>
#	($tmp, $filename) = tempfile();
#	if($ENV{'PERL5LIB'}) {
#		foreach (split(':', $ENV{'PERL5LIB'})) {
#			print $tmp "use lib '$_';\n";
#		}
#	}
#	print $tmp "use CGI::Buffer { optimise_content => 1, lint_content => 0 };\n";
#	print $tmp "print \"Content-type: text/html; charset=ISO-8859-1\";\n";
#	print $tmp "print \"\\n\\n\";\n";
#	print $tmp "print \"<HTML><BODY>\n<p><em>The Brass Band Portal</em> is visited some 500 times</BODY></HTML>\\n\";\n";
#
#	open($fout, '-|', "$^X -Iblib/lib " . $filename);
#
#	$keep = $_;
#	undef $/;
#	$stdout = <$fout>;
#	$/ = $keep;
#
#	close $tmp;
#
#	($headers, $body) = split /\r?\n\r?\n/, $stdout, 2;
#	ok($headers =~ /^Content-Length:\s+(\d+)/m);
#	$length = $1;
#	ok(defined($length));
#	ok(length($body) eq $length);
#	ok($headers !~ /^Status: 500/m);
#	ok($body eq "<HTML><BODY><p><em>The Brass Band Portal</em> is visited some 500 times</BODY></HTML>");
#
#	#..........................................
#	diag('Ignore warning about <a> is never closed');
#	delete $ENV{'SERVER_NAME'};
#	($tmp, $filename) = tempfile();
#	if($ENV{'PERL5LIB'}) {
#		foreach (split(':', $ENV{'PERL5LIB'})) {
#			print $tmp "use lib '$_';\n";
#		}
#	}
#	print $tmp "use CGI::Buffer;\n";
#	print $tmp "CGI::Buffer::set_options(optimise_content => 1, lint_content=> 1);\n";
#	print $tmp "print \"Content-type: text/html; charset=ISO-8859-1\";\n";
#	print $tmp "print \"\\n\\n\";\n";
#	print $tmp "print \"<HTML><BODY><A HREF=\\\"http://www.example.com/foo.htm\\\">Click</BODY></HTML>\\n\";\n";
#
#	open($fout, '-|', "$^X -Iblib/lib " . $filename);
#
#	$keep = $_;
#	undef $/;
#	$stdout = <$fout>;
#	$/ = $keep;
#
#	close $tmp;
#
#	($headers, $body) = split /\r?\n\r?\n/, $stdout, 2;
#	ok($headers =~ /^Content-Length:\s+(\d+)/m);
#	$length = $1;
#	ok(defined($length));
#	ok(length($body) eq $length);
#	ok($headers =~ /^Status: 500/m);
#	ok($body =~ /<a>.+is never closed/);
#
#	#..........................................
#	$ENV{'SERVER_PROTOCOL'} = 'HTTP/1.1';
#	delete $ENV{'HTTP_ACCEPT_ENCODING'};
#
#	($tmp, $filename) = tempfile();
#	if($ENV{'PERL5LIB'}) {
#		foreach (split(':', $ENV{'PERL5LIB'})) {
#			print $tmp "use lib '$_';\n";
#		}
#	}
#	print $tmp "use CGI::Buffer;\n";
#	print $tmp "CGI::Buffer::set_options(optimise_content => 1);\n";
#	print $tmp "print \"Content-type: text/html; charset=ISO-8859-1\";\n";
#	print $tmp "print \"\\n\\n\";\n";
#	print $tmp "print \"<HTML><BODY><TABLE><TR><TD>foo</TD>  <TD>bar</TD></TR></TABLE></BODY></HTML>\\n\";\n";
#
#	open($fout, '-|', "$^X -Iblib/lib " . $filename);
#
#	$keep = $_;
#	undef $/;
#	$stdout = <$fout>;
#	$/ = $keep;
#
#	ok($stdout =~ /<TD>foo<\/TD><TD>bar<\/TD>/mi);
#	ok($stdout =~ /^Content-Length:\s+(\d+)/m);
#	$length = $1;
#	ok(defined($length));
#
#	ok($stdout =~ /ETag: "([A-Za-z0-F0-f]{32})"/m);
#	my $etag = $1;
#	ok(defined($etag));
#
#	($headers, $body) = split /\r?\n\r?\n/, $stdout, 2;
#	ok(length($body) eq $length);
#	ok(length($body) > 0);
#
#	#..........................................
#	$ENV{'HTTP_IF_NONE_MATCH'} = $etag;
#
#	open($fout, '-|', "$^X -Iblib/lib " . $filename);
#
#	$keep = $_;
#	undef $/;
#	$stdout = <$fout>;
#	$/ = $keep;
#
#	ok($stdout =~ /^Status: 304 Not Modified/mi);
#	($headers, $body) = split /\r?\n\r?\n/, $stdout, 2;
#	ok(length($body) == 0);
#
#	$ENV{'REQUEST_METHOD'} = 'HEAD';
#
#	open($fout, '-|', "$^X -Iblib/lib " . $filename);
#
#	$keep = $_;
#	undef $/;
#	$stdout = <$fout>;
#	$/ = $keep;
#
#	close $tmp;
#
#	ok($stdout =~ /^Status: 304 Not Modified/mi);
#	($headers, $body) = split /\r?\n\r?\n/, $stdout, 2;
#	ok(length($body) == 0);
#
#	#..........................................
#	$ENV{'SERVER_PROTOCOL'} = 'HTTP/1.1';
#	delete $ENV{'HTTP_ACCEPT_ENCODING'};
#	$ENV{'REQUEST_METHOD'} = 'GET';
#
#	($tmp, $filename) = tempfile();
#	print $tmp "use CGI::Buffer;\n";
#	if($ENV{'PERL5LIB'}) {
#		foreach (split(':', $ENV{'PERL5LIB'})) {
#			print $tmp "use lib '$_';\n";
#		}
#	}
#	print $tmp "CGI::Buffer::set_options(optimise_content => 1, generate_304 => 0);\n";
#	print $tmp "print \"Content-type: text/html; charset=ISO-8859-1\";\n";
#	print $tmp "print \"\\n\\n\";\n";
#	print $tmp "print \"<HTML><BODY><TABLE><TR><TD>foo</TD>\\t  <TD>bar</TD></TR></TABLE></BODY></HTML>\\n\";\n";
#
#	open($fout, '-|', "$^X -Iblib/lib " . $filename);
#
#	$keep = $_;
#	undef $/;
#	$stdout = <$fout>;
#	$/ = $keep;
#
#	close $tmp;
#
#	ok(defined($stdout));
#	ok($stdout =~ /<TD>foo<\/TD><TD>bar<\/TD>/mi);
#	ok($stdout !~ /^Status: 304 Not Modified/mi);
#	ok($stdout =~ /^Content-Length:\s+(\d+)/m);
#	$length = $1;
#	ok(defined($length));
#
#	ok($stdout =~ /ETag: "([A-Za-z0-F0-f]{32})"/m);
#	$etag = $1;
#	ok(defined($etag));
#
#	($headers, $body) = split /\r?\n\r?\n/, $stdout, 2;
#	ok(defined($length));
#	ok(length($body) eq $length);
#	ok(length($body) > 0);
#
#	#..........................................
#	$ENV{'HTTP_IF_NONE_MATCH'} = $etag;
#
#	open($fout, '-|', "$^X -Iblib/lib " . $filename);
#
#	$keep = $_;
#	undef $/;
#	$stdout = <$fout>;
#	$/ = $keep;
#
#	ok($stdout !~ /^Status: 304 Not Modified/mi);
#	($headers, $body) = split /\r?\n\r?\n/, $stdout, 2;
#	ok(length($body) > 0);
#
#	#..........................................
#	delete $ENV{'HTTP_IF_NONE_MATCH'};
#	$ENV{'HTTP_IF_MODIFIED_SINCE'} = DateTime->now();
#
#	($tmp, $filename) = tempfile();
#	if($ENV{'PERL5LIB'}) {
#		foreach (split(':', $ENV{'PERL5LIB'})) {
#			print $tmp "use lib '$_';\n";
#		}
#	}
#	print $tmp "use CGI::Buffer { optimise_content => 1, generate_etag => 0 };\n";
#	print $tmp "print \"Content-type: text/html; charset=ISO-8859-1\";\n";
#	print $tmp "print \"\\n\\n\";\n";
#	print $tmp "print \"<HTML><BODY><TABLE><TR><TD>foo</TD>  <TD>bar</TD></TR></TABLE></BODY></HTML>\\n\";\n";
#
#	open($fout, '-|', "$^X -Iblib/lib " . $filename);
#
#	$keep = $_;
#	undef $/;
#	$stdout = <$fout>;
#	$/ = $keep;
#
#	close $tmp;
#
#	ok($stderr eq '');
#	ok($stdout !~ /ETag: "([A-Za-z0-F0-f]{32})"/m);
#	ok($stdout !~ /^Status: 304 Not Modified/mi);
#
#	($headers, $body) = split /\r?\n\r?\n/, $stdout, 2;
#
#	ok($headers =~ /^Content-Length:\s+(\d+)/m);
#	$length = $1;
#
#	ok(length($body) != 0);
#	ok(defined($length));
#	ok(length($body) == $length);
#
#	#......................................
#	$ENV{'HTTP_IF_MODIFIED_SINCE'} = 'This is an invalid date';
#
#	($tmp, $filename) = tempfile();
#	if($ENV{'PERL5LIB'}) {
#		foreach (split(':', $ENV{'PERL5LIB'})) {
#			print $tmp "use lib '$_';\n";
#		}
#	}
#	print $tmp "use CGI::Buffer { optimise_content => 1, generate_etag => 0 };\n";
#	print $tmp "print \"Content-type: text/html; charset=ISO-8859-1\";\n";
#	print $tmp "print \"\\n\\n\";\n";
#	print $tmp "print \"<HTML><BODY><TABLE><TR><TD>foo</TD>   <TD>bar</TD></TR></TABLE></BODY></HTML>\\n\";\n";
#
#	open($fout, '-|', "$^X -Iblib/lib " . $filename);
#
#	$keep = $_;
#	undef $/;
#	$stdout = <$fout>;
#	$/ = $keep;
#
#	close $tmp;
#
#	ok($stdout !~ /ETag: "([A-Za-z0-F0-f]{32})"/m);
#	ok($stdout !~ /^Status: 304 Not Modified/mi);
#
#	($headers, $body) = split /\r?\n\r?\n/, $stdout, 2;
#
#	ok($headers =~ /^Content-Length:\s+(\d+)/m);
#	$length = $1;
#
#	ok(length($body) != 0);
#	ok(defined($length));
#	ok(length($body) == $length);
#
#	#......................................
#	# Check no output does nothing strange
#	($tmp, $filename) = tempfile();
#	if($ENV{'PERL5LIB'}) {
#		foreach (split(':', $ENV{'PERL5LIB'})) {
#			print $tmp "use lib '$_';\n";
#		}
#	}
#	print $tmp "use strict;\n";
#	print $tmp "use CGI::Buffer;\n";
#
#	open($fout, '-|', "$^X -Iblib/lib " . $filename);
#
#	$keep = $_;
#	undef $/;
#	$stdout = <$fout>;
#	$/ = $keep;
#
#	close $tmp;
#
#	ok($stdout eq '');
}
