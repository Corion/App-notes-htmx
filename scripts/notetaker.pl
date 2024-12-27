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

sub get_documents {
    my %stat;
    return
        map {
            my $fn = $_;
            -f $fn && App::Notetaker::Document->from_file( $fn )
        }
        sort {
            $stat{ $b } <=> $stat{ $a }
        }
        map {
            $stat{ $_ } = (stat($_))[9]; # most-recent changed;
            $_
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
@@ htmx-header.html.ep
<meta htmx.config.allowScriptTags="true">
<meta name="viewport" content="width=device-width, initial-scale=1">
<link href="/bootstrap.5.3.3.min.css" rel="stylesheet" integrity="sha384-QWTKZyjpPEjISv5WaRU9OFeRpok6YctnYmDr5pNlyT2bRjXh0JMhjY6hW+ALEwIH" crossorigin="anonymous">
<script src="/htmx.2.0.4.min.js"></script>
<script src="/ws.2.0.1.js"></script>
<script src="/debug.2.0.1.js"></script>
<script src="/loading-states.2.0.1.js"></script>
<script type="module" src="/morphdom-esm.2.7.4.js"></script>

@@ index.html.ep
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
%=include 'htmx-header'

<style>
nav {
    display: flex;
    align-items: center;
}

nav ul {
    display: flex;
    justify-content: space-between;
}

nav ul li {
  list-style-type: none;
}

.grid-layout {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(180px, 1fr));
    grid-gap: 1px;
    grid-auto-rows: minmax(180px, auto);
    grid-auto-flow: dense;
    padding: 1px;

}

.grid-item {
    padding: 1rem;
    font-size: 14px;
    color: #000;
    background-color: #ccc;
    border-radius: 10px;
}

.span-2 {
    grid-column-end: span 2;
    grid-row-end: span 2;
}

.span-3 {
    grid-column-end: span 3;
    grid-row-end: span 4;
}

.note {
    border: solid 1px black;
    color: inherit; /* blue colors for links too */
    text-decoration: inherit; /* no underline */
}
</style>

<title>Notes</title>
</head>
<body
    hx-ext="morphdom-swap"
    hx-swap="morphdom"
>
<div class="navbar">
  <nav>
    <ul>
    <li><a href="/">index</a></li>
    <li>
      <form id="form-filter" method="GET" action="/filter">
        <input id="text-filter" />
      </form>
    </li>
    <li>
      <a href="/new">+</a>
    </li>
    </ul>
  </nav>
</div>
<div class="documents grid-layout">
% for my $doc ($documents->@*) {
    <a href="/note/<%= $doc->filename %>" class="grid-item note">
    <div class="title"><%= $doc->frontmatter->{title} %></div>
    <div class="content"><%== $doc->{html} %></div>
    </a>
% }
</div>
</body>
</html>

@@ note.html.ep
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
%=include 'htmx-header'

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
<form action="<%= url_for( $doc_url ) %>" method="POST">
<button name="save" type="submit">Save</button>
%=include "display-text", field_name => 'title', value => $note->frontmatter->{title}, class => 'title';
<div class="xcontainer" style="height:400px">
<textarea name="body" id="node-body"
    hx-post="<%= url_for( $doc_url ) %>"
    hx-trigger="search, keyup delay:200ms changed"
    hx-swap="none"
>
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

@@display-text.html.ep
<div id="note-<%= $field_name %>" class="<%= $class %>">
% if( defined $value && $value ne '' ) {
    <%= $value %>
    <a href="<%= url_for( "/edit-$field_name/" . $note->filename ) %>"
    hx-get="<%= url_for( "/edit-$field_name/" . $note->filename ) %>"
    hx-target="#note-<%= $field_name %>"
    hx-swap="innerHTML"
    >&#x270E;</a>
% } else {
    <div color="#777">
    <a href="<%= url_for( "/edit-$field_name/" . $note->filename ) %>"
    hx-get="<%= url_for( "/edit-$field_name/" . $note->filename ) %>"
    hx-target="#note-<%= $field_name %>"
    hx-swap="innerHTML"
    >Click to add <%= $field_name %></a>
    </div>
% }
</div>

@@edit-text.html.ep
<form action="<%= url_for( "/edit-$field_name/" . $note->filename ) %>" method="POST"
    hx-post="<%= url_for( "/auto-edit-$field_name/" . $note->filename ) %>"
    hx-trigger="search, keyup delay:200ms changed"
    hx-swap="outerHTML"
>
    <input type="text" name="<%= $field_name %>" id="note-input-text-<%= $field_name %>" value="<%= $value %>" />
    <button type="submit">Save</button>
    <a href="<%= url_for( "/note/" . $note->filename ) %>"
       hx-get="/display-<%= $field_name %>/<%= $note->filename %>"
       hx-target="#note-<%= $field_name %>"
       hx-swap="innerHTML"
       hx-trigger="blur from:#note-input-text-<%= $field_name %>"
    >x</a>
</form>
