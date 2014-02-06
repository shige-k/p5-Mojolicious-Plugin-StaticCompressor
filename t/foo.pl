use strict;
use warnings;

# Prepare a test app with Plugin
use Mojolicious::Lite;
plugin('StaticCompressor');

get '/foo' => sub {
	# HTML page (include single js) - t/templates/foo.html.ep
	my $self = shift;
	$self->render;
};

app->start;