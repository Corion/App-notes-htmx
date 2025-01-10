#!perl
use 5.020;
use Mojolicious::Lite '-signatures';
use Text::FrontMatter::YAML;
use Mojo::File;
use File::Temp;
use File::Basename 'basename';
use Text::CleanFragment;
use POSIX 'strftime';
use PerlX::Maybe;
use charnames ':full';

use App::Notetaker::Document;
use App::Notetaker::Session;
use Markdown::Perl;

app->static->with_roles('+Compressed');
plugin 'DefaultHelpers';
plugin 'HTMX';

sub get_session( $c ) {
    # Validate cookie, send session cookie(?)
    return
        App::Notetaker::Session->new(
            username => 'demo',
            document_directory => './notes',
        );
}

sub fetch_filter( $c ) {
    my $filter = {
        maybe text  => $c->param('q'),
        maybe label => $c->param('label'),
        maybe color => $c->param('color'),
    };
    if( $filter->{color} ) {
        $filter->{color} =~ /#[0-9a-f]{6}/
            or delete $filter->{color};
    }
    return $filter
}

sub filter_moniker( $filter ) {
    my ($attr, $location);
    if( $filter->{label} ) {
        $location = "in '$filter->{label}'"
    }
    if( $filter->{color} ) {
        #$location = qq{<span class="color-circle" style="background-color:$filter->{color};">&nbsp;</span> notes};
        $attr = qq{color notes};
    }
    return join " ", grep { defined $_ and length $_ } ($attr, $location);
}

our %all_labels;
our %all_colors;

sub render_notes($c) {
    my $filter = fetch_filter($c);
    my $sidebar = $c->param('sidebar');
    my $session = get_session( $c );
    my @documents = get_documents($session, $filter);

    my @templates = get_templates($session);

    for my $note ( @documents ) {
        my $repr;
        if( length $note->body ) {
            $repr = as_html( $c, $note, strip_links => 1, search => $filter->{text} );
        } else {
            $repr = '&nbsp;'; # so even an empty note becomes clickable
        };
        $note->{html} = $repr;
    }

    $c->stash( documents => \@documents );

    # How do we sort the templates? By name?!
    $c->stash( templates => \@templates );
    $c->stash( labels => [sort { fc($a) cmp fc($b) } keys %all_labels] );
    $c->stash( filter => $filter );
    $c->stash( sidebar => $sidebar );
    $c->stash( moniker => filter_moniker( $filter ));
}

sub render_index($c) {
    return login_detour($c) unless $c->is_user_authenticated;
    render_notes( $c );
    $c->render('index');
}

sub render_filter($c) {
    return login_detour($c) unless $c->is_user_authenticated;
    render_notes( $c );
    $c->render('documents');
}

# Initialize all labels & colours
# This will crash if we move to more than one user ...
get_documents(get_session(undef));

sub match_text( $filter, $note ) {
       $note->body =~ /\Q$filter\E/i
    || $note->frontmatter->{title} =~ /\Q$filter\E/i
}

sub match_color( $filter, $note ) {
    ($note->frontmatter->{color} // '') eq $filter
}

sub match_label( $filter, $note ) {
    grep { $_ eq $filter } ($note->frontmatter->{labels} // [])->@*
}

# If we had a real database, this would be the interface ...
sub get_documents($session, $filter={}) {
    my %stat;
    return
        grep {
               ($filter->{text}  ? match_text( $filter->{text}, $_ )   : 1)
            && ($filter->{color} ? match_color( $filter->{color}, $_ ) : 1)
            && ($filter->{label} ? match_label( $filter->{label}, $_ ) : 1)
        }
        map {
            my $n = $_;

            # While we're at it, also read in all labels
            if( $n->frontmatter->{labels}) {
                $all_labels{ $_ } = 1 for $n->frontmatter->{labels}->@*;
            }

            # While we're at it, also read in all used colors
            $all_colors{ $n->frontmatter->{color} } = 1
                if $n->frontmatter->{color};

            $n ? $n : ()
        }
        sort {
            # we want to sort by pinned-first, and maybe even
            # other criteria
            (($b->frontmatter->{ pinned } // 0 ) - ($a->frontmatter->{ pinned } // 0))
            ||
            $stat{ $b } <=> $stat{ $a }
        }
        map {
            my $note = App::Notetaker::Document->from_file( $_ );
            $stat{ $note } = (stat($_))[9]; # most-recent changed;
            $note
        }
        $session->documents
}

# Ugh - we are conflating display and data...
sub get_templates( $session ) {
    get_documents(  $session, { label => 'Template' } )
}

sub find_note( $session, $fn ) {
    my $filename = $session->clean_filename( $fn );

    if( -f $filename ) {
        return App::Notetaker::Document->from_file( $filename );
    };
    return;
}

sub find_or_create_note( $session, $fn ) {
    my $filename = $session->clean_filename( $fn );

    if( -f $filename ) {
        return App::Notetaker::Document->from_file( $filename );
    } else {
        return App::Notetaker::Document->new(
            filename => basename($filename),
        );
    }
}

sub display_note( $c, $note ) {
    return login_detour($c) unless $c->is_user_authenticated;

    $c->stash( note => $note );
    my $session = get_session( $c );

    my $html = as_html( $c, $note );
    $c->stash( note_html => $html );
    $c->stash( all_labels => \%all_labels );

    # Meh - we only want to set this to true if a request is coming from
    # this page during a field edit, not during generic page navigation
    $c->stash( htmx_update => $c->is_htmx_request() );

    $c->render('note');
};

sub serve_attachment( $c ) {
    return login_detour($c) unless $c->is_user_authenticated;

    my $session = get_session( $c );
    my $fn = $c->param('fn');
    $fn =~ s![\x00-\x1f\\/]!!g;
    $c->reply->file( $session->document_directory . "/attachments/$fn" );
}

get '/index.html' => \&render_index;
get '/' => \&render_index;
get '/filter' => \&render_filter;

get  '/new' => sub( $c ) {
    return login_detour($c) unless $c->is_user_authenticated;

    my $session = get_session( $c );
    my $fn = $session->tempnote();

    # We'll create a file here, no matter whether there is content or not
    my $note;

    if( my $t = $c->param('template')) {
        my $template = find_note($session, $t);
        # Copy over the (relevant) attributes, or everything?!
        $note //= find_note( $session, $fn );
        $note->{body} = $template->{body};

        my $f = $template->{frontmatter};
        for my $k (keys $f->%*) {
            if( $k eq 'labels' ) {
                # Strip 'template' designation
                $note->frontmatter->{labels} = [ grep { $_ ne 'Template' } $f->{labels}->@* ];

            } elsif(     $k ne 'created'
                and $k ne 'updated') {
                $note->frontmatter->{$k} = $f->{$k};
            }
        }
    }

    if( my $c = $c->param('color')) {
        $note //= find_note( $session, $fn );
        $note->frontmatter->{color} = $c;
    }
    if( my $c = $c->param('label')) {
        $note //= find_note( $session, $fn );
        $note->frontmatter->{labels} //= [];
        push $note->frontmatter->{labels}->@*, $c;
    }
    if( my $body = $c->param('body')) {
        $note //= find_note( $session, $fn );
        $note->body( $body );
    }
    if( $note ) {
        save_note( $session, $note, $fn );
    }

    $c->redirect_to( $c->url_for("/note/$fn"));
};

get  '/note/attachments/*fn' => \&serve_attachment;

get '/note/*fn' => sub($c) {
    return login_detour($c) unless $c->is_user_authenticated;

    my $session = get_session( $c );
    my $note = find_note( $session, $c->param('fn'));
    display_note( $c, $note );
};

sub save_note( $session, $note, $fn ) {
    $note->frontmatter->{created} //= strftime '%Y-%m-%dT%H:%M:%SZ', gmtime(time);
    $note->frontmatter->{updated} = strftime '%Y-%m-%dT%H:%M:%SZ', gmtime(time);
    $note->save_to( $session->clean_filename( $fn ));
}

sub save_note_body( $c ) {
    return login_detour($c) unless $c->is_user_authenticated;

    my $fn = $c->param('fn');
    my $session = get_session( $c );

    if( ! $fn) {
        $fn = $session->tempnote();
        $c->htmx->res->replace_url($c->url_for("/note/$fn"));
    }

    my $note = find_or_create_note( $session, $fn );

    my $body = $c->param('body');
    $body =~ s/\A\s+//sm;
    $body =~ s/\s+\z//sm;

    $note->body($body);
    save_note( $session, $note, $fn );

    $c->redirect_to($c->url_for('/note/') . $fn );
};

sub delete_note( $c ) {
    return login_detour($c) unless $c->is_user_authenticated;

    my $session = get_session( $c );
    my $fn = $c->param('fn');
    my $note = find_note( $session, $fn );

    if( $note ) {
        # Save undo data?!
        $c->stash( undo => '/undelete/' . $note->filename );
        $note->frontmatter->{deleted} = strftime '%Y-%m-%dT%H:%M:%SZ', gmtime(time);
        save_note( $session, $note, $fn );
        move_note( $session->document_directory . "/" . $note->filename  => $session->document_directory . "/deleted/" . $note->filename );
    }

    # Can we keep track of current filters and restore them here?

    $c->redirect_to($c->url_for('/'));
}

sub move_note( $source_name, $target_name ) {
    my $count = 0;
    my $tn = Mojo::File->new( $target_name );
    my $target_directory = $tn->dirname;
    my $base_name = $tn->basename;
    $base_name =~ s/\.markdown\z//;

    while( -f $target_name ) {
        # maybe add todays date or something to prevent endless collisions?!
        $target_name = sprintf "%s/%s (%d).markdown", $target_directory, $target_name, $count++;
    }

    warn "We want to rename from '$source_name' to '$target_name'";
    rename $source_name => $target_name;

    return $target_name
}

post '/note/*fn' => \&save_note_body;
post '/note/' => \&save_note_body; # we make up a filename then
post '/delete/*fn' => \&delete_note;

sub edit_field( $c, $note, $field_name ) {
    return login_detour($c) unless $c->is_user_authenticated;

    my $session = get_session( $c );
    $c->stash( note => $note );
    $c->stash( field_name => $field_name );
    $c->stash( value => $note->frontmatter->{ $field_name } );
    $c->render('edit-text');
}

sub edit_color_field( $c, $note, $field_name ) {
    return login_detour($c) unless $c->is_user_authenticated;

    my $session = get_session( $c );
    $c->stash( note => $note );
    $c->stash( field_name => $field_name );
    $c->stash( value => $note->frontmatter->{ $field_name } );
    $c->render('edit-color');
}

sub edit_note_title( $c ) {
    return login_detour($c) unless $c->is_user_authenticated;

    my $session = get_session( $c );
    my $fn = $c->param('fn');
    if( ! $fn) {
        $fn = tempnote();
        $c->htmx->res->replace_url($c->url_for("/note/$fn"));
    }

    my $note = find_or_create_note( $session, $fn );
    edit_field( $c, $note, 'title' );
}

sub edit_note_color( $c ) {
    return login_detour($c) unless $c->is_user_authenticated;

    my $session = get_session( $c );
    my $fn = $c->param('fn');
    if( ! $fn) {
        my $session = get_session( $c );
        $fn = $session->tempnote();
        $c->htmx->res->replace_url($c->url_for("/note/$fn"));
    }

    my $note = find_or_create_note( $session, $fn );
    edit_color_field( $c, $note, 'color' );
}

sub update_note_color( $c, $autosave=0 ) {
    return login_detour($c) unless $c->is_user_authenticated;

    my $session = get_session( $c );
    my $fn = $c->param('fn');
    my $color = $c->param('color');

    my $note = find_or_create_note( $session, $fn );
    $note->frontmatter->{color} = $color;
    $note->save_to( $session->clean_filename( $fn ));

    if( $autosave ) {
        $c->redirect_to($c->url_for('/edit-color/') . $fn );

    } else {
        $c->redirect_to($c->url_for('/note/') . $fn );
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
    return login_detour($c) unless $c->is_user_authenticated;

    my $session = get_session( $c );
    my $fn = $c->param('fn');
    my $note = find_note( $session, $fn );
    display_field( $c, $fn, $note, 'title', 'title' );
}

sub update_note_title( $c, $autosave=0 ) {
    return login_detour($c) unless $c->is_user_authenticated;

    my $session = get_session( $c );
    my $fn = $c->param('fn');
    my $title = $c->param('title');

    my $new_fn = clean_fragment( $title ) # derive a filename from the title
                 || 'untitled'; # we can't title a note "0", but such is life

    # First, save the new information to the old, existing file
    $fn //= $new_fn;
    if( ! $fn) {
        $fn = $session->tempnote();
        $c->htmx->res->replace_url($c->url_for("/note/$fn"));
    }

    my $note = find_or_create_note( $session, $fn );
    my $rename = ($note->frontmatter->{title} ne $title);
    $note->frontmatter->{title} = $title;
    $note->save_to( $session->clean_filename( $fn ));

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

        my $final_name = move_note( $session->clean_filename( $fn ) => $session->document_directory . "/$new_fn.markdown");
        $fn = basename($final_name);
        $note->filename( $fn );
    }

    if( $autosave ) {
        warn "Redirecting to editor with (new?) name '$fn'";
        $c->redirect_to($c->url_for('/edit-title/') . $fn );

    } else {
        warn "Redirecting to (new?) name '$fn'";
        $c->redirect_to($c->url_for('/note/') . $fn );
    }
}

sub capture_image( $c ) {
    return login_detour($c) unless $c->is_user_authenticated;

    my $session = get_session( $c );
    my $note = find_note( $session, $c->param('fn') );
    $c->stash( field_name => 'image' );
    $c->stash( note => $note );
    $c->render('attach-image');
}

# XXX create note subdirectory
# XXX save image to attachments/ subdirectory
# XXX create thumbnail for image / reduce resolution/quality
# XXX convert image to jpeg in the process, or webp or whatever
sub attach_image( $c ) {
    return login_detour($c) unless $c->is_user_authenticated;

    my $session = get_session( $c );
    my $note = find_note( $session, $c->param('fn') );
    my $image = $c->param('image');
    my $filename = "attachments/" . clean_fragment( $image->filename );
    # Check that we have some kind of image file according to the name
    return if $filename !~ /\.(jpg|jpeg|png|webp|dng|heic)\z/i;
    $image->move_to($session->document_directory . "/$filename");
    $note->body( $note->body . "\n![$filename]($filename)\n" );
    $note->save_to( $session->document_directory . "/" . $note->filename );
    $c->redirect_to($c->url_for('/note/') . $note->filename );
}

# Maybe, capture media?!
sub capture_audio( $c ) {
    return login_detour($c) unless $c->is_user_authenticated;

    my $session = get_session( $c );
    my $note = find_note( $session, $c->param('fn') );
    $c->stash( field_name => 'audio' );
    $c->stash( note => $note );
    $c->render('attach-audio');
}

# "attach_media"?
sub attach_audio( $c ) {
    return login_detour($c) unless $c->is_user_authenticated;

    my $session = get_session( $c );
    my $note = find_note( $session, $c->param('fn') );
    my $media = $c->param('audio');

    my $fn = clean_fragment( $media->filename );
    # Check that we have some kind of image file according to the name
    return if $fn !~ /\.(ogg|mp3)\z/i;

    if( $fn eq 'audio-capture.ogg' ) {
        $fn = strftime 'audio-capture-%Y%m%d-%H%M%S.ogg', gmtime();
    }

    my $filename = "attachments/" . $fn;
    $media->move_to($session->document_directory . "/$filename");
    $note->body( $note->body . "\n![$filename]($filename)\n" );
    $note->save_to( $session->document_directory . "/" . $note->filename );
    $c->redirect_to($c->url_for('/note/') . $note->filename );
}

sub edit_labels( $c, $inline ) {
    return login_detour($c) unless $c->is_user_authenticated;

    my $session = get_session( $c );
    my $note = find_note( $session, $c->param('fn') );
    my $filter = $c->param('label-filter');

    my %labels;
    @labels{ keys %all_labels } = (undef) x keys %all_labels;
    $labels{ $_ } = 1 for ($note->frontmatter->{labels} // [])->@*;

    if( defined $filter and length $filter ) {
        for my $k (keys %labels) {
            delete $labels{ $k }
                unless $k =~ /\Q$filter\E/i
        }
    }

    $c->stash( labels => \%labels );
    $c->stash( note => $note );
    $c->stash( label_filter => $filter );

    if( $inline ) {
        $c->render('edit-labels');

    } else {
        $c->render('filter-edit-labels');
    }
}

sub update_labels( $c, $inline=0 ) {
    return login_detour($c) unless $c->is_user_authenticated;

    my $session = get_session( $c );
    my $fn = $c->param('fn');
    my %labels = $c->req->params->to_hash->%*;

    my @labels = sort { fc($a) cmp fc($b) } values %labels;

    my $note = find_or_create_note( $session, $fn );
    $note->frontmatter->{labels} = \@labels;
    $note->save_to( $session->clean_filename( $fn ));

    if( $inline ) {
        $c->stash( note => $note );
        $c->render('edit-labels');

    } else {
        $c->redirect_to($c->url_for('/note/') . $fn );
    }
}

sub create_label( $c ) {
    return login_detour($c) unless $c->is_user_authenticated;

    my $note = find_note( $c->param('fn') );
    $c->stash( note => $note );
    $c->render('create-label' );
}

sub add_label( $c, $inline ) {
    return login_detour($c) unless $c->is_user_authenticated;

    my $session = get_session( $c );
    my $fn = $c->param('fn');
    my %labels;
    my $label = $c->param('new-label');
    my $v = $c->param('status');

    my $note = find_or_create_note( $session, $fn );
    my $l = $note->frontmatter->{labels} // [];
    @labels{ $l->@* } = (1) x $l->@*;

    my $status;
    if ( defined $v ) {
        $status = $v;
    } else {
        $status = 1;
    };

    if( $status ) {
        $labels{ $label } = $status;
    } else {
        delete $labels{ $label }
    }

    $note->frontmatter->{labels} = [sort { fc($a) cmp fc($b) } keys %labels];
    $note->save_to( $session->clean_filename( $fn ));

    $c->stash(note => $note);
    if( $inline ) {
        $c->render('edit-labels');

    } else {
        $c->stash(prev_label => $label );
        $c->render('display-create-label');
    }
}

sub delete_label( $c, $inline ) {
    return login_detour($c) unless $c->is_user_authenticated;

    my $session = get_session( $c );
    my $fn = $c->param('fn');
    my $note = find_or_create_note( $session, $fn );
    my $remove = $c->param('delete');

    if( my $l = $note->frontmatter->{labels} ) {
        $l->@* = grep { $_ ne $remove } $l->@*;
        $note->save_to( $session->clean_filename( $fn ));
    }

    if( $inline ) {
        $c->stash( labels => $note->frontmatter->{labels} );
        $c->stash( note => $note );
        $c->render('display-labels');

    } else {
        # Simply reload the last URL ... except that we need this to be
        # passed in by the client ...
        warn $c->htmx->req->current_url;
        $c->redirect_to( $c->htmx->req->current_url );
    }
}

sub select_filter( $c ) {
    return login_detour($c) unless $c->is_user_authenticated;

    my $filter = fetch_filter($c);
    $c->stash( filter => $filter );
    $c->stash( labels => [sort { fc($a) cmp fc($b) } keys %all_labels] );
    $c->stash( types  => [] );
    $c->stash( colors => [sort { fc($a) cmp fc($b) } keys %all_colors] );
    $c->render('select-filter' );
}

sub update_pinned( $c, $pinned, $inline ) {
    return login_detour($c) unless $c->is_user_authenticated;

    my $session = get_session( $c );
    my $filter = fetch_filter($c);
    my $fn = $c->param('fn');
    my $note = find_or_create_note( $session, $fn );

    $note->frontmatter->{pinned} = $pinned;
    $note->save_to( $session->clean_filename( $fn ));

    if( $inline ) {
        render_notes( $c );
        $c->render('documents');

    } else {
        # Simply reload the last URL ... except that we need this to be
        # passed in by the client ...
        warn $c->htmx->req->current_url;
        $c->redirect_to( $c->htmx->req->current_url );
    }
}

# User authentification

{
   my %db = (
      foo => {pass => 'FOO', name => 'Foo De Pois'},
      bar => {pass => 'BAZ', name => 'Bar Auangle'},
      demo => {pass => 'demo', name => 'Demo User'},
   );
   sub load_account ($u) { return $db{$u} // undef }
   sub validate ($u, $p) {
      warn "user<$u> pass<$p>\n";
      my $account = load_account($u) or return;
      return $account->{pass} eq $p;
   }
}

app->plugin(
   Authentication => {
      load_user     => sub ($app, $uid) { load_account($uid) },
      validate_user => sub ($c, $u, $p, $e) { validate($u, $p) ? $u : () },
   }
);

my $session_store = Mojolicious::Sessions->new();
$session_store->default_expiration(0); # cookies are forever

app->hook(
    before_render => sub ($c, $args) {
        if( $c->is_user_authenticated ) {
# say "User is authenticated";
        } else {
# say "Need login";
        };
        my $user = $c->is_user_authenticated ? $c->current_user : undef;
        $c->stash(user => $user);
        return $c;
    }
);

# If we are behind a reverse proxy, prepend our path
if ( my $path = $ENV{MOJO_REVERSE_PROXY} ) {
    my @path_parts = grep /\S/, split m{/}, $path;
    app->hook( before_dispatch => sub( $c ) {
        my $url = $c->req->url;
        my $base = $url->base;
        push @{ $base->path }, @path_parts;
        $base->path->trailing_slash(1);
        $url->path->leading_slash(0);
    });
}

sub login_detour( $c ) {
    # Somehow save the request parameters in the session
    # This once more means we really need a local (in-memory if need be) session module
    # for Mojolicious
    # XXX we should also preserve form uploads here?!
    $c->session( return_to => $c->req->url->to_abs );
    my $login = $c->url_for('/login');
    warn "Detouring for login to <$login>";
    return $c->redirect_to($login);
}

get '/login' => sub ($c) { $c->render(template => 'login') };
post '/login' => sub ($c) {
    my $username = $c->param('username');
    my $password = $c->param('password');
    if ($c->authenticate($username, $password)) {
        warn $c->is_user_authenticated ? 'YES' : 'NOT YET';
        my $next = $c->session('return_to') // $c->url_for('/');
        $c->redirect_to($next);
    }
    else {
        $c->redirect_to($c->url_for('/'));
    }
    return;
};

post '/logout' => sub ($c) {
    $c->logout if $c->is_user_authenticated;
    return $c->redirect_to('/');
};


get  '/edit-title' => \&edit_note_title; # empty note
get  '/edit-title/*fn' => \&edit_note_title;
post '/edit-title/*fn' => \&update_note_title;
post '/edit-title' => \&update_note_title; # empty note
get  '/display-title/*fn' => \&display_note_title;
get  '/attach-image/*fn' => \&capture_image;
post '/upload-image/*fn' => \&attach_image;
get  '/attach-audio/*fn' => \&capture_audio;
post '/upload-audio/*fn' => \&attach_audio;
get  '/edit-color/*fn' => \&edit_note_color;
post '/edit-color/*fn' => \&update_note_color;

get  '/htmx-label-menu/*fn' => sub( $c ) { edit_labels( $c, 0 ) };
get  '/edit-labels/*fn' => sub( $c ) { edit_labels( $c, 0 ) };
post '/edit-labels/*fn' => sub( $c ) { edit_labels($c, 0 ) };
get  '/htmx-edit-labels/*fn' => sub( $c ) { edit_labels( $c, 1 ) };
post '/update-labels/*fn' => sub( $c ) { update_labels( $c, 0 ); };
post '/htmx-update-labels/*fn' => sub( $c ) { update_labels( $c, 1 ); };
get  '/create-label/*fn' => \&create_label;
get  '/add-label/*fn' => sub($c) { add_label($c, 0 ); };
post '/htmx-add-label/*fn' => sub($c) { add_label( $c, 1 ); };
get  '/delete-label/*fn' => sub( $c ) { delete_label( $c, 0 ); };
get  '/htmx-delete-label/*fn' => sub( $c ) { delete_label( $c, 1 ); };
get  '/select-filter' => \&select_filter;

post '/pin/*fn'   => sub($c) { \&update_pinned( $c, 1, 0 ) };
post '/unpin/*fn' => sub($c) { \&update_pinned( $c, 0, 0 ) };
post '/htmx-pin/*fn'   => sub($c) { \&update_pinned( $c, 1, 1 ) };
post '/htmx-unpin/*fn' => sub($c) { \&update_pinned( $c, 0, 1 ) };

# Session handling
get '/login' => sub ($c) { $c->render(template => 'login') };
post '/login' => sub ($c) {
    my $username = $c->param('username');
    my $password = $c->param('password');
    if ($c->authenticate($username, $password)) {
        warn $c->is_user_authenticated ? 'YES' : 'NOT YET';
        my $next = $c->session('return_to') // $c->url_for('/');
        $c->redirect_to($next);
    }
    else {
        $c->redirect_to($c->req->url->to_abs);
    }
    return;
};
post '/logout' => sub ($c) {
    $c->logout if $c->is_user_authenticated;
    return $c->redirect_to($c->url_for('/'));
};

app->start;

# Make relative links actually relative to /note/ so that we can also
# properly serve attachments
sub as_html( $c, $doc, %options ) {
    my $renderer = Markdown::Perl->new(
        mode => 'github',
        disallowed_html_tags => ['script','a','object'],
    );

    my $body = $doc->body;
    if( my $t = $options{ search } ) {
        $body =~ s!(\Q$t\E)!<mark>$1</mark>!gi;
    };

    my $html = $renderer->convert( $body );

    if( $options{ strip_links } ) {
        $html =~ s/<a\s+href=[^>]*?>//gsi;
        $html =~ s!</a>!!gsi;
    }

    my $base = $c->url_for('/note/');
    $html =~ s!<img src="\K(?=attachments/)!$base!g;

    return $html
}

__DATA__
@@ htmx-header.html.ep
<meta htmx.config.allowScriptTags="true">
<meta name="viewport" content="width=device-width, initial-scale=1">
<link rel="stylesheet" href="<%= url_for( "/bootstrap.5.3.3.min.css" ) %>" integrity="sha384-QWTKZyjpPEjISv5WaRU9OFeRpok6YctnYmDr5pNlyT2bRjXh0JMhjY6hW+ALEwIH" crossorigin="anonymous">
<link rel="stylesheet" href="<%= url_for( "/notes.css" )%>" />
<script src="<%= url_for( "/bootstrap.5.3.3.min.js")%>"></script>
<script src="<%= url_for( "/htmx.2.0.4.min.js")%>"></script>
<script src="<%= url_for( "/ws.2.0.1.js")%>"></script>
<script src="<%= url_for( "/debug.2.0.1.js")%>"></script>
<script src="<%= url_for( "/loading-states.2.0.1.js")%>"></script>
<script type="module" src="<%= url_for( "/morphdom-esm.2.7.4.js")%>"></script>
<script src="<%= url_for( "/app-notekeeper.js" )%>"></script>
<script>
htmx.onLoad(function(elt){
    elt.querySelectorAll('.nojs').forEach(e => e.remove());
})
</script>

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
    <li>
        <a href="#" data-bs-target="#sidebar" data-bs-toggle="collapse"
               class="border rounded-3 p-1 text-decoration-none"><i class="bi bi-list bi-lg py-2 p-1"></i> Labels</a>
    </li>
    <li><a href="/">index</a></li>
    <li>
      <div id="form-filter-2">
      <form id="form-filter-instant" method="GET" action="/">
        <input id="text-filter" name="q" value="<%= $filter->{text}//'' %>"
            placeholder="Search"
            hx-get="<%= url_with( "/select-filter" ) %>"
            hx-trigger="focus"
            hx-swap="outerHTML"
        />
      </form>
      </div>
    </li>
    <li>
      <form id="form-filter" method="GET" action="/">
        <input id="text-filter" name="q" value="<%= $filter->{text}//'' %>"
            placeholder="<%== $moniker %>"
            hx-get="<%= url_with( "/filter" ) %>"
            hx-trigger="input delay:200ms changed, keyup[key=='Enter'], load"
            hx-target="#documents"
            hx-swap="outerHTML"
            autofocus
        />
      </form>
    </li>
    </ul>
  </nav>
</div>
<div class="container-fluid" id="container">
<div class="row flex-nowrap">
    <div class="col-auto px-0">
%=include 'sidebar', labels => $labels, filter => $filter,
    </div>

    <main class="col">
%=include "documents", documents => $documents
    </main>
</div>
<div class="dropup position-fixed bottom-0 end-0 rounded-circle m-5">
  <div class="btn-group">
    <a class="btn btn-success btn-lg"
       href="<%= url_with('/new' ) %>"
    ><i class="fa-solid fa-plus">+</i>
    </a>
    <button type="button" class="btn btn-secondary btn-lg dropdown-toggle dropdown-toggle-split hide-toggle"
            data-bs-toggle="dropdown"
            aria-expanded="false"
            aria-haspopup="true"
      ><span class="visually-hidden">New from template</span>
    </button>
    <ul class="dropdown-menu">
      <li>
          <a class="dropdown-item" href="/new?label=Template&body=Alternatively+just+add+the+'Template+tag+to+a+note">+ Create a new template</a>
      </li>
% for my $template ($templates->@*) {
%     my $title = $template->frontmatter->{title} || '(untitled)';
      <li>
        <a class="dropdown-item"
            href="<%= url_with( '/new' )->query( template => $template->filename ) %>"
        ><%= $title %></a>
      </li>
% }
    </ul>
  </div>
</div>

</body>
</html>

@@documents.html.ep
<div id="documents" class="">
% my %sections;
% my %section_title = (qw(pinned Pinned default Notes));
% for my $note ($documents->@*) {
%     my $section = 'default';;
%     if( $note->frontmatter->{pinned} ) {
%         $section = 'pinned';
%     }
%     $sections{ $section } //= [];
%     push $sections{ $section }->@*, $note;
% };
% for my $section (qw(pinned default)) {
%     if( $sections{ $section }) {
    <h5><%= $section_title{ $section } %></h5>
    <div class="documents grid-layout">
%         for my $doc ($sections{$section}->@*) {
%             my $bgcolor = $doc->frontmatter->{color}
%                           ? sprintf q{ style="background-color: %s;"}, $doc->frontmatter->{color}
%                           : '';
<div class="grid-item note position-relative"<%== $bgcolor %>
       id="<%= $doc->filename %>">
%=include 'note-pinned', note => $doc
    <a href="<%= url_for( "/note/" .$doc->filename ) %>" class="note-content">
    <div class="title"><%= $doc->frontmatter->{title} %></div>
    <!-- list (some) tags -->
    <div class="content" hx-disable="true"><%== $doc->{html} %></div>
    </a>
%=include 'display-labels', labels => $doc->frontmatter->{labels}, note => $doc
</div>
%         }
</div>
%     }
% }
</div>

@@sidebar.html.ep
<div id="sidebar" class="collapse collapse-horizontal border-end <%= $sidebar ? 'show' : '' %>">
    <div id="sidebar-nav" class="list-group border-0 rounded-0 text-sm-start min-vh-100">
% my $current = $filter->{label} // '';
    <a href="<%= url_with()->query({ label => '', sidebar => 1 }) %>"
       class="list-group-item border-end-0 d-inline-block text-truncate"
       data-bs-parent="#sidebar"
    >Notes</a>
% for my $label ($labels->@*) {
%     my $current_class = $label eq $current ? 'sidebar-current' : '';
    <a href="<%= url_with()->query({ label => $label, sidebar => 1 }) %>"
       class="list-group-item border-end-0 d-inline-block text-truncate <%= $current_class %>"
       data-bs-parent="#sidebar"
    ><%= $label %> &#x1F3F7;</a>
% }
    </div>
</div>

@@note-pinned.html.ep
    <div class="pin-location position-absolute top-0 end-0">
% if( $note->frontmatter->{pinned} ) {
    <form method="POST" action="<%= url_with('/unpin/'.$note->filename) %>"
        hx-post="<%= url_with('/htmx-unpin/'.$note->filename) %>"
        --hx-swap="closest div"
        hx-target="#documents"
        hx-swap="outerHTML transition:true"
    ><button type="submit" class="pinned"><%= "\N{PUSHPIN}" %></bold></button></form>
% } else {
    <form method="POST" action="<%= url_with('/pin/'.$note->filename) %>"
        hx-post="<%= url_with('/htmx-pin/'.$note->filename) %>"
        --hx-swap="closest div"
        hx-target="#documents"
        hx-swap="outerHTML transition:true"
    ><button type="submit" class="unpinned"><%= "\N{PUSHPIN}" %>&#xfe0e;</button></form>
% }
    </div>

@@ note.html.ep
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
%=include 'htmx-header'

<title><%= $note->frontmatter->{title} %> - notekeeper</title>
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
    <li><a href="/"
            hx-trigger="click, keyup[key=='Escape'] from:body"
        >index</a></li>
    <!-- delete note -->
    </ul>
  </nav>
</div>

<div id="note-container" class="container-flex">
% my $bgcolor = $note->frontmatter->{color}
%               ? sprintf q{ style="background-color: %s;"}, $note->frontmatter->{color}
%               : '';
%=include 'display-labels', labels => $note->frontmatter->{labels}, note => $note
<div class="single-note"<%== $bgcolor %>>
<div>Filename: <%= $note->filename %></div>
% my $doc_url = '/note/' . $note->filename;
<form action="<%= url_for( $doc_url ) %>" method="POST">
<button name="save" type="submit">Close</button>
%=include "display-text", field_name => 'title', value => $note->frontmatter->{title}, class => 'title';
<div class="xcontainer" style="height:400px">
<textarea name="body" id="note-textarea" autofocus
    hx-post="<%= url_for( $doc_url ) %>"
    hx-trigger="#note-textarea, keyup delay:200ms changed"
    hx-swap="none"
><%= $note->body %></textarea>
</div>
<div id="preview" hx-swap-oob="<%= $htmx_update ? 'true':'false' %>" hx-disable="true">
<%== $note_html %>
</div>
</form>
    <div class="edited-date"><%= $note->frontmatter->{updated} %></div>
</div>
</div>
<div id="actionbar" class="navbar mt-auto fixed-bottom navbar-light bg-light">
    <div id="action-attach">
        <a href="<%= url_for( "/attach-image/" . $note->filename ) %>"
            class="btn btn-secondary"
            hx-get="<%= url_for( "/attach-image/" . $note->filename ) %>"
            hx-swap="outerHTML"
        >Add Image</a>
    </div>
    <div id="action-attach-audio">
        <a href="<%= url_for( "/attach-audio/" . $note->filename ) %>"
            class="btn btn-secondary"
            hx-get="<%= url_for( "/attach-audio/" . $note->filename ) %>"
            hx-swap="outerHTML"
        >Record</a>
    </div>
    <div id="action-labels">
% my %labels; $labels{ $_ } = 1 for ($note->frontmatter->{labels} // [])->@*;
%= include 'menu-edit-labels', note => $note, labels => \%labels, label_filter => ''
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
        <form action="<%= url_for('/delete/' . $note->filename ) %>" method="POST"
        ><button class="btn btn-secondary" type="submit">&#x1F5D1;</button>
        </form>
    </div>
</div>
</body>
</html>

@@login.html.ep
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
%=include 'htmx-header'

<title>Login - notekeeper</title>
</head>
<body
    hx-boost="true"
    id="body"
    hx-ext="morphdom-swap"
    hx-swap="morphdom"
>
  <div id="container" class="grid-container" hx-history-elt>
      <form action="<%= url_for( '/login' )%>" method="POST">
          <input type="text" name="username" value="" text="Username" />
          <input type="password" name="password" value="" text="Password" />
          <button type="submit">Log in</button>
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
    <a class="editable"
       href="<%= url_for( "/edit-$field_name/" . $note->filename ) %>"
       hx-get="<%= url_for( "/edit-$field_name/" . $note->filename ) %>"
       hx-target="#note-<%= $field_name %>"
       hx-swap="innerHTML"
    ><%= $field_name %></a>
% }
</div>

@@edit-text.html.ep
<form action="<%= url_for( "/edit-$field_name/" . $note->filename ) %>" method="POST"
    hx-swap="outerHTML"
>
    <input type="text" name="<%= $field_name %>" id="note-input-text-<%= $field_name %>" value="<%= $value %>"
        autofocus
    />
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

@@attach-audio.html.ep
<div id="audio-recorder" >
    <audio id="audio" width="640" height="480" autoplay></audio>
    <a href="#" onclick="startRecording()">Prepare</a>
    <button class="btn btn-primary" id="record">Record</button>
    <button class="btn" id="stop">Stop</button>
    <form action="<%= url_with( "/upload-audio/" . $note->filename ) %>"
          method="POST"
          enctype="multipart/form-data"
          id="form-audio-upload"
          --hx-encoding="multipart/form-data"
          --hx-post="<%= url_with( "/upload-audio/" . $note->filename ) %>"
    >
    <input id="upload-audio" type="file" accept="audio/*" name="<%= $field_name %>" />
    <button type="submit" id="do-upload">Upload</button>
     <progress id='progress' value='0' max='100'></progress>
    </form>
    <script>
        htmx.on('#form-audio-upload', 'htmx:xhr:progress', function(evt) {
          htmx.find('#progress').setAttribute('value', evt.detail.loaded/evt.detail.total * 100)
        });
    </script>
</div>

@@edit-color.html.ep
<form action="<%= url_for( "/edit-color/" . $note->filename ) %>" method="POST"
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

@@display-labels.html.ep
% $labels //= [];
% if( $labels->@* ) {
%     my $id = 'labels-'. $note->filename;
%     $id =~ s![.]!_!g;
    <div class="labels"
        id="<%= $id %>"
        hx-target="#<%= $id %>"
        hx-swap="outerHTML"
    >
%     for my $label ($labels->@*) {
    <div class="label badge rounded-pill bg-secondary" ><%= $label %>
%# Yeah, this should be a FORM, but I can't get it to play nice with Bootstrap
    <a class="delete-label"
        href="<%= url_with('/delete-label/' . $note->filename)->query(delete=> $label) %>"
        hx-get="<%= url_with('/htmx-delete-label/' . $note->filename)->query(delete=> $label) %>"
    >
        &#10006;
    </a>
    </div>
%     }
    </div>
% }

@@menu-edit-labels.html.ep
<div class="dropup" id="dropdown-labels" hx-trigger="show.bs.dropdown"
  hx-get="<%= url_with( '/htmx-label-menu/' . $note->filename ) %>"
  hx-target="find .dropdown-menu"
  >
    <button type="button" class="btn btn-secondary dropdown-toggle hide-toggle"
            data-bs-toggle="dropdown"
            aria-expanded="false"
            aria-haspopup="true"
            data-bs-auto-close="outside"
      ><span>Manage labels</span>
    </button>

    <div class="dropdown-menu">
%=include 'filter-edit-labels', note => $note, label_filter => $label_filter, labels => $labels
    </div>
</div>

@@filter-edit-labels.html.ep
% my $url = url_for( "/edit-labels/" . $note->filename );
% my $htmx_url = url_for( "/htmx-edit-labels/" . $note->filename );
<div class="dropdown-item">Label note</div>
<form action="<%= $url %>" method="GET" id="label-filter-form"
 class="form-inline dropdown-item"
 hx-target="#label-edit-list"
 hx-swap="outerHTML"
 hx-get="<%= $htmx_url %>"
>
    <div class="form-group">
        <div class="input-group input-group-unstyled has-feedback inner-addon right-addon">
        <i class="glyphicon glyphicon-search form-control-feedback input-group-addon">x</i>
        <input name="label-filter" type="text" class="form-control"
            style="width: 30%;"
            placeholder="Enter label name"
            autofocus="true"
            value="<%= $label_filter %>"
            id="label-filter"
            hx-get="<%= $htmx_url %>"
            hx-trigger="input delay:200ms changed, keyup[key=='Enter']"
        >
        </div>
        <button class="nojs btn btn-default">Filter</button>
    </div>
</form>
%=include 'edit-labels', note => $note, labels => $labels, new_name => $label_filter

@@edit-labels.html.ep
<div id="label-edit-list">
<form action="<%= url_for( "/update-labels/" . $note->filename ) %>" method="POST"
  id="label-set-list"
>
  <button class="nojs btn btn-default" type="submit">Set</button>
%=include 'display-create-label', prev_label => '', new_name => $label_filter
% my $idx=1;
% for my $label (sort { fc($a) cmp fc($b) } keys $labels->%*) {
%   my $name = "label-" . $idx++;
    <span class="edit-label dropdown-item">
    <input type="checkbox" name="<%= $name %>"
           id="<%= $name %>"
           value="<%= $label %>"
           hx-post="<%= url_with( '/htmx-update-labels/' . $note->filename ) %>"
           hx-trigger="change"
           hx-swap="none"
           hx-target="this"
           <%== $labels->{$label} ? 'checked' : ''%>
    />
    <label for="<%= $name %>" style="width: 100%"><%= $label %> &#x1F3F7;</label>
    </span>
%   $idx++;
% }
</form>
</div>

@@display-create-label.html.ep
%# This needs a rework with the above
  <!-- Here, we also need a non-JS solution ... -->
% if( defined $new_name and length($new_name)) {
%    my $url = url_for("/add-label/" . $note->filename )->query( "new-label" => $new_name );
<a id="create-label" href=" <%= $url %>"
   hx-get="<%= $url %>"
   hx-swap="outerHTML"
>+ Create '<%= $new_name %>'</a>
% }

@@create-label.html.ep
<form id="create-label" action="<%= url_for( "/add-label/" . $note->filename ) %>" method="POST"
    hx-post="<%= url_for( "/add-label/" . $note->filename ) %>"
    hx-swap="outerHTML"
>
  <button type="submit">Set</button>
    <span class="label">
    <input type="checkbox" name="really" id="really" checked />
    <input type="text" name="new-label" id="new-label" value="" placeholder="New label" autofocus />
    </span>
</form>

@@select-filter.html.ep
<div id="form-filter-2">
      <form id="form-filter-instant" method="GET" action="/">
        <input id="text-filter" name="q" value="<%= $filter->{text}//'' %>"
            placeholder="Search"
            hx-get="<%= url_with( "/select-filter" ) %>"
            hx-trigger="focus"
            hx-swap="#form-filter-2"
        />
      </form>
<!-- (note) types (images, lists, ...) -->
% if( $types->@* ) {
<div>
<h2>Types</h2>
%    for my $t ($types->@*) {
    <a href="<%= url_with('/')->query( type => $t ) %>"><%= $t %></a>
%    }
</div>
%}
% if( $labels->@* ) {
<div>
<h2>Labels</h2>
%    for my $l ($labels->@*) {
    <a href="<%= url_with('/')->query( label => $l ) %>"><%= $l %></a>
%    }
</div>
%}
<!-- things -->
% if( $labels->@* ) {
<div>
<h2>Colors</h2>
%    for my $l ($colors->@*) {
    <a href="<%= url_with('/')->query( color => $l ) %>"><span class="color-circle" style="background-color:<%== $l %>;">&nbsp;</span></a>
%    }
</div>
%}
</div>
