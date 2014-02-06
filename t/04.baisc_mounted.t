# Test for basic use of StaticCompressor
use strict;
use warnings;

use Mojolicious::Lite;
use Test::More;
use Test::Mojo;
use FindBin;
use File::Slurp;
use JavaScript::Minifier qw();

plugin Mount => {'/prefix' => "$FindBin::Bin/foo.pl"};

# Test for HTML-tag (script tag, single compressed-file)
my $t = Test::Mojo->new;
$t->get_ok('/prefix/foo')->status_is(200)->content_like(qr/<script src="(.+)"><\/script>/);
$t->tx->res->body =~ /<script src="(\/prefix\/auto_compressed\/.+)"><\/script>/;
my $script_path = $1;
# Test for script (single compressed js)
$t->get_ok($script_path)->status_is(200)->content_type_like(qr/application\/javascript\.*/)
	->content_is( JavaScript::Minifier::minify(input => File::Slurp::read_file("$FindBin::Bin/public/js/foo.js") ."") );

done_testing();

=cut
