package Mojolicious::Plugin::StaticCompressor;
use Mojo::Base 'Mojolicious::Plugin';
use utf8;

our $VERSION = '1.0.0';

use Encode qw//;
use File::Find qw//;
use FindBin;
use Mojo::IOLoop;

use Mojolicious::Plugin::StaticCompressor::Container;

our $static;			# Instance of Mojo::Asset
our %containers;		# Hash of Containers
our $config;			# Hash-ref (Configuration items)

sub register {
	my ($self, $app, $conf) = @_;
	
	# Initilaize
	%containers = ();
	$static = $app->static;
	$config = load_options( $app, $conf );

	# Add "js" helper
	$app->helper(js => sub {
		my $self = shift;
		my @file_paths = generate_list( (@_) );;
		return generate_import('js', 1, \@file_paths);
	});

	# Add "css" helper
	$app->helper(css => sub {
		my $self = shift;
		my @file_paths = generate_list( (@_) );;
		return generate_import('css', 1, \@file_paths);
	});

	# Add "js_nominify" helper
	$app->helper(js_nominify => sub {
		my $self = shift;
		my @file_paths = generate_list( (@_) );;
		return generate_import('js', 0, \@file_paths);
	});

	# Add "css_nominify" helper
	$app->helper(css_nominify => sub {
		my $self = shift;
		my @file_paths = generate_list( (@_) );;
		return generate_import('css', 0, \@file_paths);
	});

	unless($config->{is_disable}){ # Enable

		# Check the cache directory
		if(!-d $config->{path_cache_dir}){
			mkdir $config->{path_cache_dir};
		}
		
		# Add hook
		$app->hook(
			before_dispatch => sub {
				my $self = shift;
				if($self->req->url->path->contains('/'.$config->{url_path_prefix})
					&& $self->req->url->path =~ /\/$config->{url_path_prefix}\/(.+)$/){
					my $container_key = $1;
					
					eval {
						my $cont = Mojolicious::Plugin::StaticCompressor::Container->new(
							key => $container_key,
							config => $config,
						);

						if(!defined $containers{$cont->get_key()}){
							$containers{$cont->get_key()} = $cont;
						}
						
						$self->render( text => $cont->get_content(), format => $cont->get_extension() );
					};

					if($@){
						$self->render( text => $@, status => 400 );
					}
				}
			}
		);

		# Automatic cleanup
		cleanup_old_files();

		# Start background loop
		if($config->{is_background}){
			start_background_loop();
		}
	}
}

# Load the options
sub load_options {
	my ($app, $option) = @_;
	my $config = {};

	# Disable
	my $disable = $option->{disable} || 0;
	my $disable_on_devmode = $option->{disable_on_devmode} || 0;
	$config->{is_disable} = ($disable eq 1 || ($disable_on_devmode eq 1 && $app->mode eq 'development')) ? 1 : 0;

	# Debug
	$config->{is_debug} = $option->{is_debug} || 0;

	# Prefix
	my $prefix = $option->{url_path_prefix} || 'auto_compressed';
	$config->{url_path_prefix} = $prefix;

	# Path of cache directory
	$config->{path_cache_dir} = $option->{file_cache_path} || $FindBin::Bin.'/'.$prefix.'/';
	$config->{path_single_cache_dir} = $config->{path_cache_dir}.'single/';

	# Background processing
	$config->{is_background} = $option->{background} || 0;
	$config->{background_interval_sec} = $option->{background_interval_sec} || 5;

	# Automatic cleanup
	$config->{is_auto_cleanup} = $option->{auto_cleanup} || 1;

	# Expires seconds for automatic cleanup
	$config->{auto_cleanup_expires_sec} = $option->{auto_cleanup_expires_sec} || 60 * 60 * 24 * 7; # 7days

	# Others
	$config->{mojo_static} = $static;

	return $config;
}

sub generate_import {
	my ($extension, $is_minify, $path_files_ref) = @_;

	my $cont = Mojolicious::Plugin::StaticCompressor::Container->new(
		extension => $extension,
		is_minify => $is_minify,
		path_files_ref => $path_files_ref,
		config => $config,
	);

	if(defined $containers{$cont->get_key()}){
		$containers{$cont->get_key()}->update();
	} else {
		$containers{$cont->get_key()} = $cont;
	}

	if($config->{is_disable}){
		return Mojo::ByteStream->new( generate_import_raw_tag( $extension, $path_files_ref ) );
	}

	return Mojo::ByteStream->new( generate_import_processed_tag( $extension, "/".$config->{url_path_prefix}."/".$cont->get_key() ) );
}

# Generate of import HTML-tag for processed
sub generate_import_processed_tag {
	my ($extension, $url) = @_;
	if ($extension eq 'js'){
		return "<script src=\"$url\"></script>\n";
	} elsif ($extension eq 'css'){
		return "<link rel=\"stylesheet\" href=\"$url\">\n";
	}
}

# Generate of import HTML-tag for raw
sub generate_import_raw_tag {
	my ($extension, $urls_ref) = @_;
	my $tag = "";
	if ($extension eq 'js'){
		foreach(@{$urls_ref}){
			$tag .= "<script src=\"$_\"></script>\n";
		}
	} elsif ($extension eq 'css'){
		foreach(@{$urls_ref}){
			$tag .= "<link rel=\"stylesheet\" href=\"$_\">\n";
		}
	}
	return $tag;
}

# Start background process loop
sub start_background_loop {
	my $id = Mojo::IOLoop->recurring( $config->{background_interval_sec} => sub {
		foreach my $key (keys %containers){
			if( $containers{$key}->update() ){
				warn "[StaticCompressor] Cache updated in background - $key";
			}
		}
	});
}

# Cleanup
sub cleanup_old_files {
	File::Find::find(sub {
		my $path = $File::Find::name;
		my $now = time();
		if( -f $path && $path =~ /^(.*)\.(js|css)$/ ){
			my $updated_at = (stat($path))[9];
			if($config->{auto_cleanup_expires_sec} < ($now - $updated_at)){
				warn "DELETE: $path";
				#unlink($config->{path_cache_dir}) || die("Can't delete old file: $path");
			}
		}
	}, $config->{path_cache_dir});
}

#Generate one dimensional array 
sub generate_list{
	my @temp = @_;
	my @file_paths;
	while (@temp) {
		my $next = shift @temp;
		if (ref($next) eq 'ARRAY') {
			unshift @file_paths, @$next;
		}
		else {
		    push @file_paths, $next;
		}
	}
	return @file_paths;
}

1;