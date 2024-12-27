#!perl
use 5.020;
use Mojolicious::Lite '-signatures';
use Text::FrontMatter::YAML;
use Mojo::File;
use File::Temp;
use File::Basename 'basename';
use Text::CleanFragment;

use App::Notetaker::Document;
use Markdown::Perl;

app->static->with_roles('+Compressed');
plugin 'DefaultHelpers';
plugin 'HTMX';

my $document_directory = './notes';

sub render_index($c) {
    my @documents = get_documents();

    $_->{html} //= as_html( $_ ) for @documents;

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

sub clean_filename( $fn ) {
    # Sanitize filename; maybe we want Text::CleanFragment?!
    $fn =~ s![\x00-\x1f]! !g;
    $fn =~ s!\\/!!g;
    return "$document_directory/$fn"
}

sub find_note( $fn ) {
    my $filename = clean_filename( $fn );

    if( -f $filename ) {
        return App::Notetaker::Document->from_file( $filename );
    };
    return;
}

sub find_or_create_note( $fn ) {
    my $filename = clean_filename( $fn );

    if( -f $filename ) {
        return App::Notetaker::Document->from_file( $filename );
    } else {
        return App::Notetaker::Document->new(
            filename => basename($filename),
        );
    }
}

sub display_note( $c, $note ) {
    $c->stash( note => $note );
    my $html = as_html( $note );
    $c->stash( note_html => $html );

    $c->stash( htmx_update => $c->is_htmx_request() );

    $c->render('note');
};

get '/index.html' => \&render_index;
get '/' => \&render_index;

get  '/new' => sub( $c ) {
    my $note = App::Notetaker::Document->new(
        filename => undef,
        body => undef,
    );
    display_note( $c, $note );
};

get '/note/*fn' => sub($c) {
    my $note = find_note( $c->param('fn'));
    display_note( $c, $note );
};

post '/note/*fn' => sub($c) {
    my $fn = $c->param('fn');

    $fn //= basename( File::Temp::tempnam( $document_directory, 'unnamed-XXXXXXXX.markdown' ));

    my $note = find_or_create_note( $fn );

    my $body = $c->param('body');
    $body =~ s/\s+\z//sm;

    $note->body($body);
    $note->save_to( clean_filename( $fn ));

    $c->redirect_to('/note/' . $fn );
};

sub edit_field( $c, $note, $field_name ) {
    $c->stash( note => $note );
    $c->stash( field_name => $field_name );
    $c->stash( value => $note->frontmatter->{ $field_name } );
    $c->render('edit-text');
}

sub edit_note_title( $c ) {
    my $fn = $c->param('fn');
    $fn //= basename(File::Temp::tempnam( $document_directory, 'unnamed-XXXXXXXX.markdown' ));

    my $note = find_or_create_note( $fn );
    edit_field( $c, $note, 'title' );
}

sub display_field( $c, $fn, $note, $field_name, $class ) {
    $c->stash( note => $note );
    $c->stash( field_name => $field_name );
    $c->stash( value => $note->frontmatter->{ $field_name } );
    $c->stash( class => $class );
    $c->render('display-text');
}

sub display_note_title( $c ) {
    my $fn = $c->param('fn');
    my $note = find_note( $fn );
    display_field( $c, $fn, $note, 'title', 'title' );
}

sub update_note_title( $c, $autosave=0 ) {
    my $fn = $c->param('fn');
    my $title = $c->param('title');

    my $new_fn = clean_fragment( $title ) # derive a filename from the title
                 || 'untitled'; # we can't title a note "0", but such is life

    # First, save the new information to the old, existing file
    $fn //= $new_fn // basename( File::Temp::tempnam( $document_directory, 'unnamed-XXXXXXXX.markdown' ));

    my $note = find_or_create_note( $fn );
    my $rename = ($note->frontmatter->{title} ne $title);
    $note->frontmatter->{title} = $title;
    $note->save_to( clean_filename( $fn ));

    # Now, check if the title changed and we want to rename the file:
    if( $rename ) {
        # This approach of renaming easily conflicts with the remaining parts
        # of the page, if we don't carefully redirect to the new main page
        # after renaming. Maybe we should have a toggle to indicate to the
        # main page that the edit field should be the title editor (instead of
        # the text area) ?!
        # Also, this has horrible latency implications
        # We need to find a way to later rename the files according to
        # their title
        my $newname = "$document_directory/$new_fn.markdown";
        my $count = 0;
        while( -f $newname ) {
            # maybe add todays date?!
            $newname = sprintf "%s/%s (%d).markdown", $document_directory, $new_fn, $count++;
        }
        if( $new_fn . ".markdown" ne $fn ) { # after counting upwards, we still are different
            warn "We want to rename from '$fn' to '$new_fn.markdown'";
            my $target = "$document_directory/$new_fn.markdown";
            rename "$document_directory/$fn" => $target;

            $fn = basename($target);
            $note->filename( $fn );
        }
    }

    if( $autosave ) {
        warn "Redirecting to editor with (new?) name '$fn'";
        $c->redirect_to('/edit-title/' . $fn );

    } else {
        warn "Redirecting to (new?) name '$fn'";
        $c->redirect_to('/note/' . $fn );
    }
}

get  '/edit-title' => \&edit_note_title; # empty note
get  '/edit-title/*fn' => \&edit_note_title;
post '/auto-edit-title' => sub( $c ) { update_note_title( $c, 1 ) }; # empty note
post '/auto-edit-title/*fn' => sub( $c ) { update_note_title( $c, 1 ) };
post '/edit-title/*fn' => \&update_note_title;
post '/edit-title' => \&update_note_title; # empty note
get  '/display-title/*fn' => \&display_note_title;

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
<link rel="stylesheet" href="/notes.css" />

@@ index.html.ep
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
%=include 'htmx-header'

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
<div class="single-note">
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
<div id="preview" hx-swap-oob="<%= $htmx_update ? 'true':'false' %>">
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
