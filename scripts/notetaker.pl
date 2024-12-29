#!perl
use 5.020;
use Mojolicious::Lite '-signatures';
use Text::FrontMatter::YAML;
use Mojo::File;
use File::Temp;
use File::Basename 'basename';
use Text::CleanFragment;
use POSIX 'strftime';

use App::Notetaker::Document;
use Markdown::Perl;

app->static->with_roles('+Compressed');
plugin 'DefaultHelpers';
plugin 'HTMX';

my $document_directory = Mojo::File->new( './notes' )->to_abs();

sub render_index($c) {
    my $filter = $c->param('q');
    my @documents = get_documents($filter);

    $_->{html} //= as_html( $_ ) for @documents;

    $c->stash( documents => \@documents );
    $c->stash( filter => $filter );
    $c->render('index');
}

sub render_filter($c) {
    my $filter = $c->param('q');
    my @documents = get_documents($filter);

    $_->{html} //= as_html( $_ ) for @documents;

    $c->stash( documents => \@documents );
    $c->stash( filter => $filter );
    $c->render('documents');
}

sub get_documents($filter="") {
    my %stat;
    return
        grep {
            $filter
                ?    $_->body =~ /\Q$filter\E/i
                  || $_->frontmatter->{title} =~ /\Q$filter\E/i
                : 1
        }
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
        glob "$document_directory/*.markdown";
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

sub serve_attachment( $c ) {
    my $fn = $c->param('fn');
    $fn =~ s![\x00-\x1f\\/]!!g;
    $c->reply->file( "$document_directory/attachments/$fn" );
}

get '/index.html' => \&render_index;
get '/' => \&render_index;
get '/filter' => \&render_filter;

get  '/new' => sub( $c ) {
    my $note = App::Notetaker::Document->new(
        filename => undef,
        body => undef,
    );
    display_note( $c, $note );
};

get  '/note/attachments/*fn' => \&serve_attachment;

get '/note/*fn' => sub($c) {
    my $note = find_note( $c->param('fn'));
    display_note( $c, $note );
};

sub save_note( $note, $fn ) {
    $note->frontmatter->{created} //= strftime '%Y-%m-%dT%H:%M:%SZ', gmtime(time);
    $note->frontmatter->{updated} = strftime '%Y-%m-%dT%H:%M:%SZ', gmtime(time);
    $note->save_to( clean_filename( $fn ));
}

post '/note/*fn' => sub($c) {
    my $fn = $c->param('fn');

    $fn //= basename( File::Temp::tempnam( $document_directory, 'unnamed-XXXXXXXX.markdown' ));

    my $note = find_or_create_note( $fn );

    my $body = $c->param('body');
    $body =~ s/\A\s+//sm;
    $body =~ s/\s+\z//sm;

    $note->body($body);
    save_note( $note, $fn );

    $c->redirect_to('/note/' . $fn );
};

sub edit_field( $c, $note, $field_name ) {
    $c->stash( note => $note );
    $c->stash( field_name => $field_name );
    $c->stash( value => $note->frontmatter->{ $field_name } );
    $c->render('edit-text');
}

sub edit_color_field( $c, $note, $field_name ) {
    $c->stash( note => $note );
    $c->stash( field_name => $field_name );
    $c->stash( value => $note->frontmatter->{ $field_name } );
    $c->render('edit-color');
}

sub edit_note_title( $c ) {
    my $fn = $c->param('fn');
    $fn //= basename(File::Temp::tempnam( $document_directory, 'unnamed-XXXXXXXX.markdown' ));

    my $note = find_or_create_note( $fn );
    edit_field( $c, $note, 'title' );
}

sub edit_note_color( $c ) {
    my $fn = $c->param('fn');
    $fn //= basename(File::Temp::tempnam( $document_directory, 'unnamed-XXXXXXXX.markdown' ));

    my $note = find_or_create_note( $fn );
    edit_color_field( $c, $note, 'color' );
}

sub update_note_color( $c, $autosave=0 ) {
    my $fn = $c->param('fn');
    my $color = $c->param('color');

    my $note = find_or_create_note( $fn );
    $note->frontmatter->{color} = $color;
    $note->save_to( clean_filename( $fn ));

    if( $autosave ) {
        $c->redirect_to('/edit-color/' . $fn );

    } else {
        $c->redirect_to('/note/' . $fn );
    }
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

sub capture_image( $c ) {
    my $note = find_note( $c->param('fn') );
    $c->stash( field_name => 'image' );
    $c->stash( note => $note );
    $c->render('attach-image');
}

# XXX create note subdirectory
# XXX save image to attachments/ subdirectory
# XXX create thumbnail for image / reduce resolution/quality
# XXX convert image to jpeg in the process, or webp or whatever
sub attach_image( $c ) {
    my $note = find_note( $c->param('fn') );
    my $image = $c->param('image');
    my $filename = "attachments/" . clean_fragment( $image->filename );
    # Check that we have some kind of image file according to the name
    return if $filename !~ /\.(jpg|jpeg|png|webp|dng|heic)\z/i;
    $image->move_to("$document_directory/$filename");
    $note->body( $note->body . "\n![$filename]($filename)\n" );
    $note->save_to( "$document_directory/" . $note->filename );
    $c->redirect_to('/note/' . $note->filename );
}

get  '/edit-title' => \&edit_note_title; # empty note
get  '/edit-title/*fn' => \&edit_note_title;
post '/edit-title/*fn' => \&update_note_title;
post '/edit-title' => \&update_note_title; # empty note
get  '/display-title/*fn' => \&display_note_title;
get  '/attach-image/*fn' => \&capture_image;
post '/upload-image/*fn' => \&attach_image;
get  '/edit-color/*fn' => \&edit_note_color;
post '/edit-color/*fn' => \&update_note_color;

app->start;

# Make relative links actually relative to /note/ so that we can also
# properly serve attachments
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
<link rel="stylesheet" href="/bootstrap.5.3.3.min.css" integrity="sha384-QWTKZyjpPEjISv5WaRU9OFeRpok6YctnYmDr5pNlyT2bRjXh0JMhjY6hW+ALEwIH" crossorigin="anonymous">
<link rel="stylesheet" href="/notes.css" />
<script src="/bootstrap.5.3.3.min.js"></script>
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

<title>Notes</title>
</head>
<body
    hx-boost="true"
    id="body"
    hx-ext="morphdom-swap"
    hx-swap="morphdom"
>
<div class="navbar navbar-expand-lg sticky-top navbar-light bg-light">
  <nav>
    <ul>
    <li><a href="/">index</a></li>
    <li>
      <form id="form-filter" method="GET" action="/">
        <input id="text-filter" name="q" value="<%= $filter %>"
            placeholder="Filter"
            hx-get="<%= url_for( "/filter" ) %>"
            hx-trigger="input delay:200ms changed, keyup[key=='Enter'], load"
            hx-target="#documents"
            hx-swap="outerHTML"
        />
      </form>
    </li>
    </ul>
  </nav>
</div>
%=include "documents", documents => $documents

<div class="dropup position-fixed bottom-0 end-0 rounded-circle m-5">
  <div class="btn-group">
    <button type="button" class="btn btn-success btn-lg"
      ><i class="fa-solid fa-plus">
       <a href="/new">+</a>
       </i>
    </button>
    <button type="button" class="btn btn-secondary btn-lg dropdown-toggle dropdown-toggle-split hide-toggle"
            data-bs-toggle="dropdown"
            aria-expanded="false"
            aria-haspopup="true"
      ><span class="visually-hidden">Add Category</span>
    </button>
    <ul class="dropdown-menu">
      <li>
        <a class="dropdown-item" href="#">template 1</a>
        <a class="dropdown-item" href="#">template 2</a>
      </li>
    </ul>
  </div>
</div>

</body>
</html>

@@documents.html.ep
<div id="documents" class="documents grid-layout">
% for my $doc ($documents->@*) {
    % my $bgcolor = $doc->frontmatter->{color}
    %               ? sprintf q{ style="background-color: %s;"}, $doc->frontmatter->{color}
    %               : '';
    <a href="/note/<%= $doc->filename %>" class="grid-item note"<%== $bgcolor %>>
    <div class="title"><%= $doc->frontmatter->{title} %></div>
    <!-- list (some) tags -->
    <div class="content"><%== $doc->{html} %></div>
    </a>
% }
</div>

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
<div class="navbar navbar-expand-lg fixed-top bg-light">
  <nav>
    <ul>
    <li><a href="/">index</a></li>
    <!-- delete note -->
    </ul>
  </nav>
</div>
% my $bgcolor = $note->frontmatter->{color}
%               ? sprintf q{ style="background-color: %s;"}, $note->frontmatter->{color}
%               : '';
<div class="single-note"<%== $bgcolor %>>
<div>Tags: ...</div><!-- tags editor ?! -->
<div>Filename: <%= $note->filename %></div>
% my $doc_url = '/note/' . $note->filename;
<form action="<%= url_for( $doc_url ) %>" method="POST">
<button name="save" type="submit">Save</button>
%=include "display-text", field_name => 'title', value => $note->frontmatter->{title}, class => 'title';
<div class="xcontainer" style="height:400px">
<textarea name="body" id="note-textarea"
    hx-post="<%= url_for( $doc_url ) %>"
    hx-trigger="note-textarea, keyup delay:200ms changed"
    hx-swap="none"
><%= $note->body %></textarea>
</div>
<div id="preview" hx-swap-oob="<%= $htmx_update ? 'true':'false' %>">
<%== $note_html %>
</div>
</form>
</div>
<div id="actionbar" class="footer mt-auto fixed-bottom navbar-light bg-light">
    <div id="action-attach">
        <a href="<%= url_for( "/attach-image/" . $note->filename ) %>"
            hx-get="<%= url_for( "/attach-image/" . $note->filename ) %>"
            hx-swap="outerHTML"
        >Add Image</a>
    </div>
    <div id="action-color">
        <a href="<%= url_for( "/edit-color/" . $note->filename ) %>"
            hx-get="<%= url_for( "/edit-color/" . $note->filename ) %>"
            hx-swap="outerHTML"
        >Set color</a>
    </div>
    <div id="action-archive">
        <a href="#"
            hx-get="#"
            hx-swap="outerHTML"
        >Archive note</a>
    </div>
    <div id="action-delete">
        <a href="#"
            hx-get="#"
            hx-swap="outerHTML"
        >Delete note</a>
    </div>
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
    hx-swap="outerHTML"
>
    <input type="text" name="<%= $field_name %>" id="note-input-text-<%= $field_name %>" value="<%= $value %>" />
    <button type="submit">Save</button>
    <a href="<%= url_for( "/note/" . $note->filename ) %>"
       hx-get="/display-<%= $field_name %>/<%= $note->filename %>"
       hx-target="#note-<%= $field_name %>"
       hx-swap="innerHTML"
       --hx-trigger="blur from:#note-input-text-<%= $field_name %>"
    >x</a>
</form>

@@attach-image.html.ep
<form action="<%= url_for( "/upload-$field_name/" . $note->filename ) %>" method="POST"
    enctype='multipart/form-data'
    hx-encoding='multipart/form-data'
    hx-post="<%= url_for( "/upload-$field_name/" . $note->filename ) %>"
    hx-swap="outerHTML"
>
    <label for="upload-<%=$field_name%>">Upload image</label>
    <input id="upload-<%=$field_name%>" type="file" accept="image/*" name="<%= $field_name %>" id="capture-image-<%= $field_name %>" capture="environment" />
    <button type="submit">Upload</button>
    <a href="<%= url_for( "/note/" . $note->filename ) %>"
       hx-get="xxx-display-actions"
       hx-target="xxx"
       hx-swap="innerHTML"
       hx-trigger="blur from:#note-input-text-<%= $field_name %>"
    >x</a>
</form>

@@edit-color.html.ep
<form action="<%= url_for( "/edit-color/" . $note->filename ) %>" method="POST"
    hx-post="<%= url_for( "/auto-edit-$field_name/" . $note->filename ) %>"
    hx-swap="outerHTML"
    hx-target="#body"
>
  <input type="color" list="presetColors" value="<%= $value %>" name="color" id="edit-<%= $field_name %>"
    hx-post="<%= url_for( "/edit-color/" . $note->filename ) %>"
    hx-swap="outerHTML"
    hx-target="#body"
  >
  <datalist id="presetColors">
    <option>#ff0000</option>
    <option>#00ff00</option>
    <option>#0000ff</option>
  </datalist>
  <button type="submit">Set</button>
</form>
