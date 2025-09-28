#!perl

package Link::Preview::SiteInfo 0.01;
use 5.020;
use Moo 2;
use experimental 'signatures';

has 'moniker' => (
    is => 'ro',
    required => 1,
);

has 'prerequisites' => (
    is => 'ro',
    required => 1,
);

sub applies( $self, $info ) {
    return undef
}

sub generate( $self, $info ) {
    return undef
}

package Link::Preview::SiteInfo::YouTube;
use 5.020;
use Moo 2;
use experimental 'signatures';
extends 'Link::Preview::SiteInfo';

use constant moniker => 'YouTube';
use constant prerequisites => { url => 1 };

around 'applies' => sub( $orig, $class, $info ) {
    my $url = $info->{url} // '';
       $url =~ m!\?v=([^;&]+)!
    || $url =~ m!/embed/([^?]+)!
    ;
};

around 'generate' => sub( $orig, $class, $info ) {
    my $res = {};
    my $url = ($info->{url} // '');
    my $id;
    if( $url =~ m!\=v=([^;&]+)! ) {
        $id = $1;
    } elsif( $url =~ m!/embed/([^/?]+)! ) {
        $id = $1;
    } else {
        return
    }

    # XXX also handle youtu.be , youtube-nocookie
    # XXX also fill "title", "type"

    return Link::Preview->new(
        markdown_template => <<'MARKDOWN',
[![Linktext]({image})]({url})
MARKDOWN
        assets => { image => ['https://img.youtube.com/vi/{id}/0.jpg', 'thumbnail_{id}.jpg'] },
        values => { id => $id, url => $url,
            type => 'video',
        },
    );
};

package Link::Preview::SiteInfo::OpenGraph;
use 5.020;
use experimental 'signatures';
use Moo 2;
extends 'Link::Preview::SiteInfo';
use Data::OpenGraph;

use constant moniker => 'OpenGraph';
use constant prerequisites => { url => 1, html => 1 }; # we want the URL so we can resolve relative attributes

around 'applies' => sub( $orig, $class, $info ) {
    my $og = Data::OpenGraph->parse_string( $info->{html} );
    return $og->property("type");
};

around 'generate' => sub( $orig, $class, $info ) {
    my $og = Data::OpenGraph->parse_string( $info->{html} );

    if( $og->property("type")) {
        # We found some (valid) OpenGraph entity

        my $url = $og->property( "url" );
        my $title = $og->property( "title" );
        my $type  = $og->property( "type" );
        my $image  = $og->property( "image" );
        my $description  = $og->property( "description" );

        # We need HTML escaping for everything here!
        return Link::Preview->new(
            assets => { image => $image },
            values => {
                title => $title,
                description => $description,
                url => $url,
                type => $type,
            },
            markdown_template => <<'MARKDOWN',
    <div class="opengraph">
        <a href="{url}">
            <div class="title">{title}</div>
            <img src="{image}" />
            <div class="description">{description}</div>
        </a>
    </div>
MARKDOWN
        );

    } else {
        return;
    }
};

package main;
use 5.020;
use Mojolicious::Lite -signatures;
use Mojo::UserAgent;
use Link::Preview;
use Carp 'croak';
use Future;

no experimental 'signatures';
sub first_defined( &;@ ) {
    my $cb = shift;
    map { my @res = $cb->(); scalar @res && defined $res[0] ? @res : () } @_
}
use experimental 'signatures';

#my $ua = LWP::UserAgent::Paranoid->new();
#$ua->protocols_allowed(["http", "https"]);

my @previewers = (qw(
    Link::Preview::SiteInfo::YouTube
    Link::Preview::SiteInfo::OpenGraph
));

sub fetch_preview_set( $prereq_set, $exclude = {} ) {
    my $have = join "\0", sort { $a cmp $b } grep { $prereq_set->{$_} } keys $prereq_set->%*;
    my @res;
    for my $p (grep { ! $exclude->{ $_ }} @previewers) {
        my $need = join "\0", sort { $a cmp $b } keys $p->prerequisites->%*;
        if( $need eq $have ) {
            push @res, $p;
        }
    }
    return @res
}

sub fetch_preview( $ua, $url, $html=undef ) {

    # First, check with URL only, then (optionally) fetch HTML and check with
    # that, if we have no candidate that works without fetching the HTML
    my %prereqs = (
        url => $url,
        html => $html,
    );

    my %already_checked;
    my @most_fitting = grep {
        $_->applies( \%prereqs ) or $already_checked{ $_ }++;
    } fetch_preview_set( \%prereqs, \%already_checked );

    # Maybe push fetching the HTML one level upwards instead?!
    # but that implies that the logic also has to live upwards?!
    # What is then the result/aim of this subroutine at all?
    if( ! @most_fitting and ! $html ) {
        warn "Fetching <$url> for preview";
        # For development, we should cache this a lot!
        $html = $ua->get( $url )->res->body;
        $prereqs{ html } = $html;
        @most_fitting = grep {
            $_->applies( \%prereqs );
        } fetch_preview_set( \%prereqs, \%already_checked );
    }
    if( @most_fitting ) {
        return $most_fitting[0]->generate( \%prereqs );
    } else {
        return undef
    }
}

sub update_page( $c ) {
    my %info;

    # XXX this should be Mojo::UserAgent::Paranoid, which we still have to write
    my $ua = Mojo::UserAgent->new();

    #warn $c->req->param('links');

    $info{ links } = [ grep { /\S/ } map { s/\s*\z//; $_ } split /\ *\r?\n/, ($c->req->param('links') // 'https://example.com') ];
    $info{ "link_data" } = [map { +{ url => $_, data => fetch_preview( $ua, $_ ) } } $info{ links }->@*];
    $info{ "link_preview" } = [map { +{ url => $_, preview => fetch_preview( $ua, $_ ) } } $info{ links }->@*];

    # Also, async-fetch the page and retry with the page content if needed

    for my $k (sort keys %info) {
        $c->stash( $k => $info{$k} );
    }
}

sub render_index($c) {
    update_page( $c );
    $c->render('index');
}

get '/' => \&render_index;
post '/' => \&render_index;

app->start;

__DATA__
@@ index.html.ep
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta htmx.config.allowScriptTags="true">
<meta name="viewport" content="width=device-width, initial-scale=1.0, interactive-widget=resizes-content" />
<link rel="stylesheet" href="<%= url_for( "/bootstrap.5.3.3.min.css" ) %>" integrity="sha384-QWTKZyjpPEjISv5WaRU9OFeRpok6YctnYmDr5pNlyT2bRjXh0JMhjY6hW+ALEwIH" crossorigin="anonymous">
<link rel="stylesheet" href="<%= url_for( "/notes.css" )%>" />
<script src="<%= url_for( "/bootstrap.5.3.3.min.js")%>"></script>
<script src="<%= url_for( "/htmx.2.0.7.min.js")%>"></script>
<script src="<%= url_for( "/ws.2.0.1.js")%>"></script>
<script src="<%= url_for( "/debug.2.0.1.js")%>"></script>
<script src="<%= url_for( "/loading-states.2.0.1.js")%>"></script>
<script type="module" src="<%= url_for( "/morphdom-esm.2.7.4.js")%>"></script>
<script>
//htmx.logAll();
</script>
<style>
textarea {
  /* box-sizing: border-box; /* fit parent width */
  flex: 1;
  height: 100%;
  width: 100%;
  min-height: 400px;
}
</style>
<title>Link Preview</title>
</head>
<body
    hx-boost="true"
    id="body"
    hx-ext="morphdom-swap"
    hx-swap="morphdom"
>
<h1>Link list</h1>
<div>
<textarea name="links" id="note-textarea" autofocus
    style="color: inherit; background-color: inherit;"
    hx-post="/"
    hx-target="#body"
    hx-trigger="#note-textarea, keyup delay:200ms changed"
    hx-swap="none"
>
% for my $l ($links->@*) {
<%= $l %>
% }
</textarea>
</div>
<h1>Link data</h1>
<table id="link-data" hx-swap-oob="true">
% for my $i (0..$link_data->@*-1) {
    <tr><td>
% use Data::Dumper;
<pre>
% local $Data::Dumper::Sortkeys=1;
<%= Dumper $link_data->[$i] %>
</pre>
</td>
<td>
% my $url = $link_preview->[$i];
% if ( $url->{preview} ) {
%     my $fetch = $url->{preview}->assets_for_fetch;
%     for my $asset (values $fetch->%*) {
    <img src="<%= $asset->[0] %>" />
%     }
<div id="description"><%== $url->{preview}->markdown %></div>
% } else {
    - none -
% }
</td></tr>
% }
</table>
</body>
</html>
