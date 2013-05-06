package Mojolicious::Plugin::StaticCompressor;
use Mojo::Base 'Mojolicious::Plugin';
use utf8;

our $VERSION = '0.0.3';

use Encode qw();
use CSS::Minifier qw();
use JavaScript::Minifier qw();
use Mojo::Util qw();
use Mojo::IOLoop;

our $static;			# Instance of Mojo::Asset
our $importInfos;	# Hash-ref (Imports information)	- import-key <-> {file-infos, file-type}
our $config;			# Hash-ref (Configuration items)
our $cache;			# Instance of Mojo::Cache (single files)

sub register {
	my ($self, $app, $conf) = @_;
	
	# Initilaize
	$importInfos = {};
	$config = {};
	$static = $app->static;

	# Initialize file cache (cache each a single file)
	$cache = Mojo::Cache->new(max_keys => 100);

	# Load options
	my $disable = $conf->{disable} || 0;
	my $disable_on_devmode = $conf->{disable_on_devmode} || 0;
	$config->{is_disable} = ($disable eq 1 || ($disable_on_devmode eq 1 && $app->mode eq 'development')) ? 1 : 0;

	$config->{is_background} = $conf->{background} || 1;

	$config->{is_only_background} = $conf->{only_background_processed} || 1;

	my $prefix = $conf->{url_path_prefix} || 'auto_compressed';
	$config->{url_path_prefix} = $prefix;
	
	# Add hook
	$app->hook(
		before_dispatch => sub {
			my $self = shift;
			if($self->req->url->path->contains('/'.$config->{url_path_prefix})
				&& $self->req->url->path =~ /\/$config->{url_path_prefix}\/((nomin\-|)\w+)$/){

				my $import_key = $1;
				my $is_enable_minify = $2 eq 'nomin-' ? 0 : 1;
				
				if (exists $importInfos->{$import_key}) {
					# Found the file-type and file-paths, from importInfos
					my $file_type = $importInfos->{$import_key}->{type};
					my @file_infos = @{$importInfos->{$import_key}->{infos}};

					my $output = "";
					my $is_cached_flg = 0; # 0 = cached, 1 = processed just in time.

					foreach my $file_info (@file_infos){
						# Get processed file
						my ($content, $is_cached) = get_processed_file($file_info, $is_enable_minify);

						$is_cached_flg = 1 if ($is_cached);
						
						# Combine
						$output .= $content;
					}

					if($is_cached_flg){
						$self->res->headers->header('X-Asset-Compressed' => 'Cached by Mojolicious::Plugin::StaticCompressor');
					} else {
						$self->res->headers->header('X-Asset-Compressed' => 'JIT by Mojolicious::Plugin::StaticCompressor');
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

	# Background process loop
	if($config->{is_background}){
		Mojo::IOLoop->recurring(1 => sub {
    			my $loop = shift;
    			foreach my $import_key (keys %{$importInfos}){

    				my $is_enable_minify = 1;
    				if($import_key =~ /nomin\-\w+/){
				 	$is_enable_minify = 0;
    				}

				my $file_type = $importInfos->{$import_key}->{type};
				my @file_infos = @{$importInfos->{$import_key}->{infos}};

				my $is_processed = 0;
				foreach my $file_info (@file_infos){

					my $cache_key  = generate_cache_key($file_info->{path}, $is_enable_minify);

					unless (get_cached_file($cache_key)){ # If NOT found a file on cache...

						# Proccess and cache this file.
						generate_processed_file($file_info->{path}, $file_type, $is_enable_minify);

						# Exit from loop
						$is_processed = 1;
						last;
					}
				}

				if($is_processed){
					last;
				}
    			}
  		});
	}
}

# Get to processed file (from cache or just generated) - Return: ($content, $is_cached)
sub get_processed_file {
	my ($file_info, $is_enable_minify) = @_;

	my $path = $file_info->{path};
	my $f;

	# Check file date
	my $file_updated_at;
	eval {
		$f = $static->file($path);
		$file_updated_at = (stat($f->path()))[9];
	}; if($@){ die ("Can't read static file: $path\n$@");}

	# Generate of file cache-key
	my $cache_key  = generate_cache_key($path, $is_enable_minify);

	# Find a file on cache
	my $content = get_cached_file($cache_key);
	if(defined $content){
		if ($file_updated_at eq $file_info->{updated_at}){ # cache is latest
			return ($content, 1);
		}
	}

	# If not found a file on cache, or cache were old...

	# Process the file, and cache it.
	$content = generate_processed_file($path, $is_enable_minify);

	# Update the updated_at
	$file_info->{updated_at} = $file_updated_at;

	return ($content, 0);
}

# Check exists the cached file
sub is_exists_cached_file {
	my ($cache_key) = @_;
	if ($cache->get($cache_key)){ # If found a file on cache...
		return 1;
	}
	return undef;
}

# Get the cached file
sub get_cached_file {
	my ($cache_key) = @_;
	if (my $content = $cache->get($cache_key)){ # If found a file on cache...
		return $content;
	}
	return undef;
}

# Process and cache the file
sub generate_processed_file {
	my ($path, $file_type, $is_enable_minify) = @_;

	# Read a file from static dir
	my $file;
	eval {
		$file = $static->file($path);
	};
	if($@){
		die ("Can't read static file: $path\n$@");
	}
	my $content = $file->slurp();

	# Decoding
	$content = Encode::decode_utf8($content);

	# Minify
	if($is_enable_minify){
		$content = minify($file_type, $content);
	}

	# Generate of cache-key
	my $cache_key = generate_cache_key($path, $is_enable_minify);

	# Save to cache
	$cache->set($cache_key, $content);

	return $content;
}

# Generarte of cache-key
sub generate_cache_key {
	my ($path, $is_enable_minify) = @_;
	my $cache_key  = ($is_enable_minify) ? $path : 'nomin-'.$path;
	return $cache_key;
}

# Generate of import-key & return import HTML-tag
sub generate_import {
	my ($file_type, $is_enable_minify, $paths_ref) = @_;
	if($config->{is_disable}){ # If disable mode...
		# Return the RAW import HTML-tag
		return Mojo::ByteStream->new(generate_import_tag_raw($file_type, $paths_ref));
	}

	# Generate of import-key from file-paths
	my $import_key = generate_import_key($is_enable_minify, $paths_ref);
	
	# Add (Upsert) import-key to importInfos hash
	add_import_info($import_key, $file_type, $paths_ref);
	
	# Return import HTML-tag
	if($config->{is_only_background}){ # Background-only mode
		my $processed_flg = 1;
		foreach my $file_path (@{$paths_ref}){
			my $cache_key = generate_cache_key($file_path, $is_enable_minify);
			unless (is_exists_cached_file($cache_key)){ # Found the file is not yet processed
				# Return the RAW import HTML-tag, currently.
				return Mojo::ByteStream->new(generate_import_tag_raw($file_type, $paths_ref));
			}
		}
		# Return the compressed import HTML-tag
		return Mojo::ByteStream->new(generate_import_tag_compress($file_type, $import_key));
	} else { # Normal mode (Background or just-in-time)
		# Return the compressed import HTML-tag
		return Mojo::ByteStream->new(generate_import_tag_compress($file_type, $import_key));
	}
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
		my @file_infos;
		foreach my $file_path(@{$file_paths_ref}){
			push(@file_infos, {
				path => $file_path,
				updated_at => 0,
			});
		}

		$importInfos->{$import_key} = {
			infos => \@file_infos,
			type => $file_type,
		};
	}
}

# Generate of import HTML-tag - minify / compressed url
sub generate_import_tag_compress {
	my ($file_type, $import_key) = @_;
	return return generate_import_tag_html_code($file_type, "/$config->{url_path_prefix}/$import_key");
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
__END__
=head1 NAME

Mojolicious::Plugin::StaticCompressor - Automatic JS/CSS minifier & compressor for Mojolicious

=head1 SYNOPSIS

Into the your Mojolicious application:

  sub startup {
    my $self = shift;

    $self->plugin('StaticCompressor');
    ~~~

(Also, you can read the examples using the Mojolicious::Lite, in a later section.)

Then, into the template in your application:

  <html>
  <head>
    ~~~~
    <%= js '/foo.js', '/bar.js' %> <!-- minified and combined, automatically -->
    <%= css '/baz.css' %> <!-- minified, automatically -->
    ~~~~
  </head>

However, this module has just launched development yet. please give me your feedback.

=head1 DISCRIPTION

This Mojolicious plugin is minifier and compressor for static JavaScript file (.js) and CSS file (.css).

=head1 INSTALLATION (from GitHub)

  $ git clone git://github.com/mugifly/p5-Mojolicious-Plugin-StaticCompressor.git
  $ cpanm ./p5-Mojolicious-Plugin-StaticCompressor

=head1 HELPERS

You can use these helpers on templates and others.

=head2 js $file_path [, ...]

Example of use on template file:

  <%= js '/js/foo.js' %>

This is just available as substitution for the 'javascript' helper (built-in helper of Mojolicious).

However, this helper will output a HTML-tag including the URL which is a compressed files. 

  <script src="/auto_compressed/124015dca008ef1f18be80d7af4a314afec6f6dc"></script>

When this script file has output (just received a request), it is minified automatically.

Then, minified file are cached in the memory.

=head3 Support for multiple files

In addition, You can also use this helper with multiple js-files:

  <%= js '/js/foo.js', '/js/bar.js' %>

In this case, this helper will output a single HTML-tag.

but, when these file has output, these are combined (and minified) automatically.

=head2 css $file_path [, ...]

This is just available as substitution for the 'stylesheet' helper (built-in helper of Mojolicious).

=head2 js_nominify $file_path [, ...]

If you don't want Minify, please use this.

This helper is available for purposes that only combine with multiple js-files.

=head2 css_nominify $file_path [, ...]

If you don't want Minify, please use this.

This helper is available for purposes that only combine with multiple css-files.

=head1 CONFIGURATION

=head2 disable_on_devmode

You can disable a combine (and minify) when running your Mojolicious application as 'development' mode (such as a running on  the 'morbo'), by using this option:

  $self->plugin('StaticCompressor', disable_on_devmode => 1);

(default: 0)

=head1 KNOWN ISSUES

=over 4

=item * Implement the disk cache. (Currently is memory cache only.)

=item * Improvement of the load latency in the first.

=item * Support for LESS and Sass.

=back

Your feedback is highly appreciated!

https://github.com/mugifly/p5-Mojolicious-Plugin-StaticCompressor/issues

=head1 EXAMPLE OF USE

Prepared a brief sample app for you, with using Mojolicious::Lite:

example/example.pl

  $ morbo example.pl

Let's access to http://localhost:3000/ with your browser.

=head1 REQUIREMENTS

=over 4

=item * Mojolicious v3.8x or later (Operability Confirmed: v3.88)

=item * Other dependencies (cpan modules).

=back

=head1 SEE ALSO

L<https://github.com/mugifly/p5-Mojolicious-Plugin-StaticCompressor>

L<Mojolicious>

L<CSS::Minifier>

L<JavaScript::Minifier>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2013, Masanori Ohgita (http://ohgita.info/).

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

Thanks, Perl Mongers & CPAN authors. 
