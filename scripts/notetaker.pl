#!perl
use 5.020;
use Mojolicious::Lite '-signatures';
use Text::FrontMatter::YAML;
use Mojo::File;

use App::Notetaker::Document;
use Markdown::Perl;

app->static->with_roles('+Compressed');
plugin 'DefaultHelpers';
plugin 'HTMX';

my $document_directory = './notes';

sub render_index($c) {
    my @documents = get_documents();
    $c->stash( documents => \@documents );
    $c->render('index');
}

sub get_documents() {
    return
        map {
            my $fn = $_;
            -f $fn && App::Notetaker::Document->from_file( $fn )
        }
        glob "$document_directory/*";
}

get '/index.html' => \&render_index;
get '/' => \&render_index;
get '/note/*fn' => sub($c) {
    # Sanitize filename; maybe we want Text::CleanFragment?!
    my $fn = $c->param('fn');
    $fn =~ s![\x00-\x1f]! !g;
    $fn =~ s!\\/!!g;
    my $note = App::Notetaker::Document->from_file( "$document_directory/$fn" );
    $c->stash( note => $note );
    $c->stash( note_html => as_html( $note ));

    $c->render('note');
};

post '/note/*fn' => sub($c) {
    # Sanitize filename; maybe we want Text::CleanFragment?!
    my $fn = $c->param('fn');
    $fn =~ s![\x00-\x1f]! !g;
    $fn =~ s!\\/!!g;
    my $filename = "$document_directory/$fn";
    my $note = App::Notetaker::Document->from_file( $filename );

    $note->body($c->param('body'));
    $note->save_to( $filename );

    $c->redirect_to('/note/' . $fn );
};

app->start;

sub as_html( $doc ) {
    my $renderer = Markdown::Perl->new(
        mode => 'github',
        disallowed_html_tags => ['script','a','object']
    );
    $renderer->convert( $doc->body );
}

__DATA__
@@ index.html.ep
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta htmx.config.allowScriptTags="true">
<meta name="viewport" content="width=device-width, initial-scale=1">
<link href="/bootstrap.5.3.3.min.css" rel="stylesheet" integrity="sha384-QWTKZyjpPEjISv5WaRU9OFeRpok6YctnYmDr5pNlyT2bRjXh0JMhjY6hW+ALEwIH" crossorigin="anonymous">
<script src="/htmx.2.0.4.min.js"></script>
<script src="/ws.2.0.1.js"></script>
<script src="/debug.2.0.1.js"></script>
<script src="/loading-states.2.0.1.js"></script>
<script type="module" src="/morphdom-esm.2.7.4.js"></script>

<title>Notes</title>
</head>
<body
    hx-ext="morphdom-swap"
    hx-swap="morphdom"
>
<div class="documents">
% for my $doc ($documents->@*) {
    <div class="note">
    <a href="/note/<%= $doc->filename %>">
    <%= $doc->frontmatter->{title} %>
    </a>
    </div>
% }
</div>
</body>
</html>

@@ note.html.ep
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta htmx.config.allowScriptTags="true">
<meta name="viewport" content="width=device-width, initial-scale=1">
<link href="/bootstrap.5.3.3.min.css" rel="stylesheet" integrity="sha384-QWTKZyjpPEjISv5WaRU9OFeRpok6YctnYmDr5pNlyT2bRjXh0JMhjY6hW+ALEwIH" crossorigin="anonymous">
<script src="/htmx.2.0.4.min.js"></script>
<script src="/ws.2.0.1.js"></script>
<script src="/debug.2.0.1.js"></script>
<script src="/loading-states.2.0.1.js"></script>
<script type="module" src="/morphdom-esm.2.7.4.js"></script>

<style>
.note {
  display: flex;
  flex-direction: column;
  width: 100%;
 }

.xcontainer > textarea {
  /* box-sizing: border-box; /* fit parent width */
  flex: 1;
  height: 100%;
  width: 100%;
}
</style>

<title><%= $note->frontmatter->{title} %></title>
</head>
<body
    hx-boost="true"
    id="body"
    hx-ext="morphdom-swap"
    hx-swap="morphdom"
>
<nav>
<a href="/">index</a>
</nav>
<div>Filename: <%= $note->filename %></div>
<div class="note">
% my $doc_url = '/note/' . $note->filename;
<form action="<%= url_for( $doc_url ) %>" method="POST"
    hx-post="<%= url_for( $doc_url ) %>"
    hx-trigger="search, keyup delay:200ms changed"
    hx-swap="none"
>
<button name="save" type="submit">Save</button>
<input type="hidden" name="filename" value="<%= $note->filename %>" />
<div class="xcontainer">
<textarea name="body" id="node-body">
<%= $note->body %>
</textarea>
</div>
<div id="preview" hx-swap-oob="true">
<%== $note_html %>
</div>
</form>
</div>
</body>
</html>
