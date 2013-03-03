package Mojolicious::Plugin::StaticCompressor;
use Mojo::Base 'Mojolicious::Plugin';
use utf8;

our $VERSION = 0.0.1;

use Encode qw();
use CSS::Minifier qw();
use JavaScript::Minifier qw();
use Mojo::Util qw();

our $importInfos; # Hash ref	- import-key <-> {file-paths, file-type}
our $IS_DISABLE;
our $URL_PATH_PREFIX;

sub register {
	my ($self, $app, $conf) = @_;

	# Load options	-	disable_on_devmode
	my $disable_on_devmode = $conf->{disable_on_devmode} || 0;

	# Load options	-	url_path_prefix
	$URL_PATH_PREFIX = $conf->{url_path_prefix} || 'auto_compressed';

	# Initilaize
	$importInfos = {};

	# Initialize file cache (cache each a single file)
	my $cache = Mojo::Cache->new(max_keys => 100);

	$IS_DISABLE = ($disable_on_devmode eq 1 && $app->mode eq 'development') ? 1 : 0;
	
	# Add hook
	$app->hook(
		before_dispatch => sub {
			my $self = shift;
			if($self->req->url->path->contains('/'.$URL_PATH_PREFIX . '/')
				&& $self->req->url->path =~ /\/$URL_PATH_PREFIX\/((nomin\-|)\w+)$/){

				my $import_key = $1;
				my $is_enable_minify = $2 eq 'nomin-' ? 0 : 1;
				
				if (exists $importInfos->{$import_key}) {
					# Found the file-type and file-paths, from importInfos
					my $file_type = $importInfos->{$import_key}->{type};
					my @paths = @{$importInfos->{$import_key}->{paths}};

					my $output = "";

					foreach my $path(@paths){
						# Generate of file cache-key
						my $cache_key  = ($is_enable_minify eq 1) ? $path : 'nomin-'.$path;
						
						if (my $content = $cache->get($cache_key)){ # If found a file on cache...
							# Combine
							$output .= $content;

						} else {# If not found a file on cache...
							# Read a file from static dir
							my $content;
							eval {
								$content = $self->app->static->file($path)->slurp;
							}; if($@){ die ("Can't load static file: $path\n$@");}
							# Decoding
							$content = Encode::decode_utf8($content);

							# Minify
							$content = minify($file_type, $content) if ($is_enable_minify);

							# Add to cache
							$cache->set($cache_key, $content);

							# Combine
							$output .= $content;
						}
					}

					$self->render(text => $output, format => $file_type);
				}
			}
		}
	);

	# Add "js" helper
	$app->helper(js => sub {
		my $self = shift;
		my @file_paths = @_;
		return generate_import('js', 1, \@file_paths);
	});

	# Add "css" helper
	$app->helper(css => sub {
		my $self = shift;
		my @file_paths = @_;
		return generate_import('css', 1, \@file_paths);
	});

	# Add "js_nominify" helper
	$app->helper(js_nominify => sub {
		my $self = shift;
		my @file_paths = @_;
		return generate_import('js', 0, \@file_paths);
	});

	# Add "css_nominify" helper
	$app->helper(css_nominify => sub {
		my $self = shift;
		my @file_paths = @_;
		return generate_import('css', 0, \@file_paths);
	});
}

# Generate of import-key & return import HTML-tag
sub generate_import {
	my ($file_type, $is_enable_minify, $paths_ref) = @_;
	if($IS_DISABLE){
		# If disable mode... Return RAW import HTML-tag
		return Mojo::ByteStream->new(generate_import_tag_raw($file_type, $paths_ref));
	}

	# Generate of import-key from file-paths
	my $import_key = generate_import_key($is_enable_minify, $paths_ref);
	
	# Add import-key to importInfos hash
	add_import_info($import_key, $file_type, $paths_ref);
	
	# Return import HTML-tag
	return Mojo::ByteStream->new(generate_import_tag_compress($file_type, $import_key));
}

# Generate of import-key
sub generate_import_key {
	my ($is_enable_minify, $file_paths_ref) = @_;

	my $key = "";
	{
		$, = "_";
		$key = "@$file_paths_ref";
	}
	$key = Mojo::Util::sha1_sum($key);

	if($is_enable_minify eq 0){
		$key = "nomin-".$key;
	}
	return $key;
}

# Add import-info into importInfos
sub add_import_info {
	my ($import_key, $file_type, $file_paths_ref) = @_;

	unless (exists($importInfos->{$import_key})){
		$importInfos->{$import_key} = {
			paths => $file_paths_ref,
			type => $file_type,
		};
	}
}

# Generate of import HTML-tag - minify / compressed url
sub generate_import_tag_compress {
	my ($file_type, $import_key) = @_;
	return return generate_import_tag_html_code($file_type, "/$URL_PATH_PREFIX/$import_key");
}

# Generate of import HTML-tag - RAW url (for DISABLE mode)
sub generate_import_tag_raw {
	my ($file_type, $files_paths_ref) = @_;
	my $output = "";
	foreach(@{$files_paths_ref}){
		$output .= generate_import_tag_html_code($file_type, $_);
	}
	return $output;
}

# Generate of import HTML-tag
sub generate_import_tag_html_code {
	my ($file_type, $url) = @_;
	if ($file_type eq 'js'){
		return "<script src=\"$url\"></script>\n";
	} elsif ($file_type eq 'css'){
		return "<link rel=\"stylesheet\" href=\"$url\">\n";
	}
}

# Minify a code
sub minify {
	my ($file_type, $content) = @_;
	if($file_type eq 'js'){
		return minify_js($content);
	} elsif ($file_type eq 'css'){
		return minify_css($content);
	}
}

# Minify a javascript code
sub minify_js {
	my $content = shift;
	return JavaScript::Minifier::minify(input => $content);
}

# Minify a css code
sub minify_css {
	my $content = shift;
	return CSS::Minifier::minify(input => $content);
}

1;