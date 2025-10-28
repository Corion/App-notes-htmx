#!perl
use 5.020;
use Mojolicious::Lite;
use Mojo::UserAgent::Paranoid;
use Mojo::UserAgent;
use Carp 'croak';
use experimental 'signatures';

use App::Notetaker::PreviewFetcher;

# Maybe move that to Module::Pluggable instead
use Link::Preview::SiteInfo::YouTube;
use Link::Preview::SiteInfo::OpenGraph;

my $ua = Mojo::UserAgent::Paranoid->new();


my @previewers = (qw(
    Link::Preview::SiteInfo::YouTube
    Link::Preview::SiteInfo::OpenGraph
));

my $fetcher;
sub update_page( $c ) {
    my %info;

    $fetcher //= App::Notetaker::PreviewFetcher->new(
        ua => $ua,
        previewers => \@previewers
    );

    $info{ links } = [ grep { /\S/ } map { s/\s*\z//; $_ } split /\ *\r?\n/, ($c->req->param('links') // 'https://example.com') ];
    $info{ "link_preview" } = $fetcher->fetch_previews( $info{ links } );

    # Also, async-fetch the page and retry with the page content if needed
    my $pending = $fetcher->pending;
    for (sort keys $pending->%*) {
        warn sprintf "% 10s - %s", $pending->{$_}->{status}, $_;
    }

    for my $k (sort keys %info) {
        $c->stash( $k => $info{$k} );
    }
}

sub render_index($c) {
    update_page( $c );
    $c->render('index');
}

sub render_preview( $c ) {
    my $id  = $c->param('id');
    (my $req) = grep { $id eq $_->{id} } values $fetcher->pending->%*, values $fetcher->done->%*;
    if( $req) {
        $c->stash( info => $req );
        return $c->render('link-preview-card');
    } else {
        $c->res->code(286); # stop polling
        $c->render( text => 'HTMX Stop polling' );
    }
}

sub render_preview_data( $c ) {
    my $id  = $c->param('id') // 'no-such-id';
    (my $req) = grep { $id eq $_->{id} } values $fetcher->pending->%*, values $fetcher->done->%*;
    if( $req) {
        $c->stash( info => $req );
        return $c->render('link-preview-data');
    } else {
        $c->res->code(286); # stop polling
        $c->render( text => 'HTMX Stop polling' );
    }
}

app->ua( Mojo::UserAgent::Paranoid->new());

get '/' => \&render_index;
post '/' => \&render_index;
get  '/preview' => \&render_preview;
get  '/preview-data' => \&render_preview_data;

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
  max-height: 400px;
  color: inherit;
  background-color: inherit;
}

.preview-card img {
    max-height: 200px;
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
<form action="/" method="POST"
    hx-post="/"
    hx-trigger="input from:#note-textarea delay:200ms changed, keyup delay:200ms changed"
    hx-swap="none"
    id="user-input-form"
>
<textarea name="links" id="note-textarea" autofocus>
% for my $l ($links->@*) {
<%= $l %>
% }
</textarea>
</form>
</div>
<h1>Link data</h1>
<table id="link-data" hx-swap-oob="true">
% for my $i (0..$link_preview->@*-1) {
    <tr><td>
%= include "link-preview-data", info => $link_preview->[$i];
</td>
<td>
%= include "link-preview-card", info => $link_preview->[$i];
</td></tr>
% }
</table>
</body>
</html>

@@ link-preview-data.html.ep
% my $poll = (!$info->{preview} and (($info->{status} // 'pending') eq 'pending' )) ? 'every 500ms' : '';
<div class="preview-data" id="preview-data-<%= $info->{id} %>"
% if( $poll ) {
    hx-trigger="<%= $poll %>"
    hx-get="<%= $c->url_with("/preview-data")->query( id => $info->{id} ) %>"
    hx-swap="outerHTML"
% }
>
% use Data::Dumper;
<pre>
% local $Data::Dumper::Sortkeys=1;
% my $p = $info->{data} // {};
<%= Dumper $info %>
</pre>
</div>

@@ link-preview-card.html.ep
% my $poll = (($info->{status} // '') eq 'pending' ) ? 'every 500ms' : '';

%# hx-trigger every XXX does not work without hx-post or hx-get
<div class="preview-card" id="preview-<%= $info->{id} %>"
% if( $poll ) {
    hx-trigger="<%= $poll %>"
    hx-get="<%= $c->url_with("/preview")->query( id => $info->{id} ) %>"
    hx-swap="outerHTML"
% } else {
% warn "$info->{id} done";
% }
>
% if ( $info->{preview} ) {
%     my $fetch = $info->{preview}->assets_for_fetch;
%     for my $asset (values $fetch->%*) {
    <img src="<%= $asset->[0] %>" />
%     }
<div id="description"><%== $info->{preview}->markdown %></div>
% } elsif ($info->{status} eq 'pending') {
    - pending - (polling)
% } else {
    - none - <%= $info->{status} %>
% }
</div>
