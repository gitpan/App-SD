package App::SD::CLI::Command::Publish;
use Any::Moose;
extends 'Prophet::CLI::Command::Publish';
use Prophet::Util;
use File::Path;
use File::Spec;
use HTML::TreeBuilder;
use URI::file;
use Try::Tiny;

sub export_html {
    my $self = shift;
    my $path = $self->arg('path');

    # if they specify both html and replica, then stick rendered templates
    # into a subdirectory. if they specify only html, assume they really
    # want to publish directly into the specified directory
    if ( $self->has_arg('replica') ) {
        $path = File::Spec->catdir( $path => 'html' );
        mkpath( [$path] );
    }

    $self->render_templates_into($path);
}

# helper methods for rendering templates
sub render_templates_into {
    my $self = shift;
    my $dir  = shift;

    require App::SD::Server;
    my $server = App::SD::Server::Static->new(
        read_only => 1, static => 1, app_handle => $self->app_handle );
    $server->static(1);
    $server->setup_template_roots();
    use CGI;
    my $file = "/";
    {

        local $ENV{'REMOTE_ADDR'}    = '127.0.0.1';
        local $ENV{'REQUEST_METHOD'} = 'GET';
        my $cgi = CGI->new();

        my @links = ('/');
        my $seen  = {};
        while ( my $file = shift @links ) {
            next if $seen->{$file};
	    local $ENV{'REQUEST_URI'} = $file;
            try {
                $cgi->path_info($file);
                my $content = $server->handle_request($cgi);

		if ( defined $content ) {
		    my $page_links = [];
		    ( $content, $page_links ) = $self->work_with_urls( $file, $content );

		    push @links, grep { !$seen->{$_} } @$page_links;

		    $self->write_file( $dir, $file, $content );

		    $seen->{$file}++;
		}
            } catch {
		if ( $_ =~ /^REDIRECT (.*)$/ ) {
		    my $new_file = $1;
		    chomp($new_file);
		    $self->handle_redirect( $dir, $file, $new_file );
		    unshift @links, $new_file;
		} elsif ($_) { # rethrow
		    die $_;
		}
	    };
        }
    }
}

sub work_with_urls {
    my $self     = shift;
    my $current_url = shift;
    my $content  = shift;

    my $current_depth = () = $current_url =~ m{.+?/}g;

    #Extract Links from the file
    my $h = HTML::TreeBuilder->new;
    $h->no_space_compacting(1);
    $h->ignore_ignorable_whitespace(0);
    $h->parse_content($content);

    my $link_elements = $h->extract_links(qw(img href script style a link ));
    return ($content, []) unless @$link_elements;

    my $all_links = {};

    #Grab each img src and re-write them so they are relative URL's
    foreach my $link_element (@$link_elements) {

        my $link    = shift @$link_element;    #URL value
        my $element = shift @$link_element;    #HTML::Element Object

        $all_links->{$link}++;
        
        my $url = $link;

        if ( $url =~ m|/$| ) {
            $url .= "index.html" 
        } elsif ($url !~ /\.\w{2,4}$/) {
            $url .= ".html";
        }

        # if $url is absolute, let's make it relative
        if ( $url =~ s{^/}{} && $current_depth ) {
            $url = ( '../' x $current_depth ) . $url;
        }

        my ($attr)
            = grep { defined $element->attr($_) and $link eq $element->attr($_) }
            @{ $HTML::Tagset::linkElements{ $element->tag } };

        $element->attr( $attr, $url );
    }

    my @links;

    # we nned to turn every link into absolute, here is to find out dir info
    # e.g. if $current_url is '/foo/bar/baz.html', @dirs will be qw/foo bar/
    my @dirs = grep { $_ } split m{/}, $current_url;
    # pop the page name like history.html
    pop @dirs;

    for my $link ( keys %$all_links ) {
        next unless $link;

        # we don't use ./ and file: link in pages, so they are bogus for us
        # more worse thing is './' will overwride some page with nothing
        next if $link eq './' || $link =~ /^file:/;

        # generally, if the link is not absolute, we need to find it.
        if ( $link !~ m{^/} ) {
            my $depth = $link =~ s{\.\./}{}g;
            my @tmp_dirs = @dirs;
            # remove trailing dirs according to $depth
            if ($depth) {
                pop @tmp_dirs while $depth--;
            }
            $link = '/' . join '/', @tmp_dirs, $link;
        }

        push @links, $link;
    }

    return $h->as_HTML, \@links;
}

sub handle_redirect {
    my $self            = shift;
    my $dir             = shift;
    my $file            = shift;
    my $new_file        = shift;
    my $redirected_from = File::Spec->catfile( $dir => $file );
    my $redirected_to   = File::Spec->catfile( $dir => $new_file );
    {
        my $parent = Prophet::Util->updir($redirected_from);
        # mkpath succeeds (but returns nothing) if a directory already exists
        eval { mkpath( [$parent] ) };
        if ( $@ ) {
            die "Failed to create directory " . $parent . " - for $redirected_to " . $@;
        }
    }
    if ( -d $redirected_from ) { $redirected_from .= "/index.html"; }
    link( $redirected_to, $redirected_from );
}

sub write_file {
    my $self    = shift;
    my $dir     = shift;
    my $file    = shift;
    my $content = shift;

    if ( $file =~ qr|/$| ) {
        $file .= "index.html" 
    } elsif ($file !~ /\.\w{2,4}$/) {
        $file .= ".html";
    }
    Prophet::Util->write_file( file => File::Spec->catfile( $dir => $file ), content => $content );

}

__PACKAGE__->meta->make_immutable;
no Any::Moose;

package App::SD::Server::Static;
use Any::Moose;
extends 'App::SD::Server';
use Params::Validate;
use JSON;

sub log_request { }

sub send_content {
    my $self = shift;
    my %args = validate( @_, { content => 1, content_type => 0, encode_as => 0, static => 0 } );

    if ( $args{'encode_as'} && $args{'encode_as'} eq 'json' ) {
        $args{'content'} = to_json( $args{'content'} );
    }

    return $args{'content'};
}

sub _send_redirect {
    my $self = shift;
    my %args = validate( @_, { to => 1 } );
    die "REDIRECT " . $args{to} . "\n";
}

sub _send_404 {}

__PACKAGE__->meta->make_immutable;
no Any::Moose;

1;

