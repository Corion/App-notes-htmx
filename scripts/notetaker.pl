#!perl
use 5.020;
use Mojolicious::Lite '-signatures';
use experimental 'try';
use Text::FrontMatter::YAML;
use Mojo::File;
use File::Temp;
use File::Basename 'basename';
use Text::CleanFragment;
use POSIX 'strftime';
use PerlX::Maybe;
use charnames ':full';
use YAML::PP::LibYAML 'LoadFile', 'DumpFile';
use Text::ParseWords 'shellwords';
use List::Util 'first';

use Crypt::Passphrase;
use Crypt::Passphrase::Argon2;

use App::Notetaker::Document;
use App::Notetaker::Session;
use App::Notetaker::Utils 'timestamp';

use Markdown::Perl;
use Text::HTML::Turndown;
use Date::Period::Human;

use File::Find;
use Archive::Zip;

app->static->with_roles('+Compressed');
plugin 'DefaultHelpers';
plugin 'HTMX';

my %sessions;

my $user_directory = 'users';

sub get_session( $c ) {
    my $user = $c->current_user;
    return $sessions{ $user->{user} }
        if $sessions{ $user->{user} };
    my $s = App::Notetaker::Session->new(
        username => $user->{user},
        document_directory => $user->{notes},
    );
    return $sessions{ $user->{user} } = $s;
}

sub date_range_visual( $range ) {
    my $d = Date::Period::Human->new({ lang => 'en' });
    my $s = $d->human_readable( $range->{start} =~ s/\A(..........)T(........)Z\z/$1 $2/gr );
    my $e = $d->human_readable( $range->{end}   =~ s/\A(..........)T(........)Z\z/$1 $2/gr );
    return qq{between $s and $e};
}

sub fetch_filter( $c ) {
    my $filter = {
        maybe text  => $c->param('q'),
        maybe label => $c->param('label'),
        maybe color => $c->param('color'),
        maybe created_start => $c->param('created.start'),
        maybe created_end   => $c->param('created.end'),
    };
    if( $filter->{color} ) {
        $filter->{color} =~ /#[0-9a-f]{6}/
            or delete $filter->{color};
    }

    if( my $v = delete $filter->{created_start} ) {
        $filter->{created} //= {};
        $filter->{created}->{start} = $v;
    }
    if( my $v = delete $filter->{created_end} ) {
        $filter->{created} //= {};
        $filter->{created}->{end} = $v;
    }

    return $filter
}

sub filter_moniker( $filter ) {
    my ($attr, $location, $created);
    if( $filter->{label} ) {
        $location = "in '$filter->{label}'"
    }
    if( $filter->{color} ) {
        #$location = qq{<span class="color-circle" style="background-color:$filter->{color};">&nbsp;</span> notes};
        $attr = qq{color notes};
    }
    if( $filter->{created} ) {
        $created = date_range_visual( $filter->{created} );
    }
    return join " ", grep { defined $_ and length $_ } ($attr, $location, $created);
}

sub render_notes($c) {
    my $filter = fetch_filter($c);
    my $sidebar = $c->param('sidebar');
    my $session = get_session( $c );
    my @documents = get_documents($session, $filter);

    my @templates = get_templates($session);

    for my $note ( @documents ) {
        my $repr;
        if( length $note->body ) {
            $repr = as_html( $c, $note, strip_links => 0, search => $filter->{text} );
        } else {
            $repr = '&nbsp;'; # so even an empty note becomes clickable
        };
        $note->{html} = $repr;
    }

    $c->stash( documents => \@documents );
    $c->stash( show_filter => !!$c->param('show-filter') );

    # How do we sort the templates? By name?!
    $c->stash( templates => \@templates );
    stash_filter( $c, $filter );
    $c->stash( sidebar => $sidebar );
    $c->stash( moniker => filter_moniker( $filter ));
}

sub render_index($c) {
    return login_detour($c) unless $c->is_user_authenticated;
    $c->session(expiration => 86400);
    render_notes( $c );
    $c->render('index');
}

sub render_filter($c) {
    return login_detour($c) unless $c->is_user_authenticated;
    render_notes( $c );
    $c->render('documents');
}

sub render_setup($c) {
    return login_detour($c) unless $c->is_user_authenticated;
    $c->session(expiration => 86400);

my $url = $c->url_for('/new')->to_abs;
    # Consider using the fetch API
    # opening a fresh window/tab
    # and window.location as the fallback
    # Maybe blindly return to the website using ".back()" ?!
my $js = <<'JS' =~ s/\s+/ /gr;
 javascript:(
   function(){
       const title = document.title;
       const selection = window.getSelection();
       let selectedText;
       if (selection.rangeCount > 0) {
         range = selection.getRangeAt(0);
         const clonedSelection = range.cloneContents();
         const div = document.createElement('div');
         div.appendChild(clonedSelection);
         selectedText = div.innerHTML;
       } else {
         selectedText = '';
       };

    const url = document.location.href;
    const label = '#saved_from_browser';
    const content = `${selectedText}<p id="attribution">from <a href="${url}">${title}</a></p>`;
    document.location.href = "%s?"
                              + ([
                                 `title=${encodeURIComponent(title)}`,
                                 `body-html=${encodeURIComponent(content)}`,
                                 `label=${encodeURIComponent(label)}`,
                                ].join("&"));
   })();
JS
    my $bookmarklet = sprintf $js, $url;

    my $filter = fetch_filter( $c );
    stash_filter( $c, $filter );
    $c->stash( show_filter => !!$c->param('show-filter') );
    $c->stash( bookmarklet => $bookmarklet);
    $c->stash( moniker => filter_moniker( $filter ));
    my $sidebar = $c->param('sidebar');
    $c->stash( sidebar => $sidebar );
    $c->render('setup');
}

sub match_text( $filter, $note ) {
       ( $note->body // '' ) =~ /\Q$filter\E/i
    || ( $note->frontmatter->{title} // '' ) =~ /\Q$filter\E/i
}

# Does an AND match
sub match_terms( $text, $note ) {
    my $terms = [shellwords( $text )];
    return ! defined ( first { ! match_text( $_, $note ) } $terms->@* );
}

sub match_color( $filter, $note ) {
    ($note->frontmatter->{color} // '') eq $filter
}

sub match_label( $filter, $note ) {
    grep { $_ eq $filter } ($note->frontmatter->{labels} // [])->@*
}

sub match_field_range( $filter, $field, $note ) {
    my $val = $note->frontmatter->{ $field } // '';
        (!$filter->{ start } || $filter->{ start } le $val)
    and (!$filter->{ end }   || $filter->{ end } ge $val)
}

sub match_range( $filter, $field, $note ) {
    match_field_range( $filter->{$field}, $field, $note )
}

# If we had a real database, this would be the interface ...
sub get_documents($session, $filter={}) {
    my %stat;
    my $labels = $session->labels;
    my $colors = $session->colors;
    #my $created_buckets = $session->created_buckets;
    #%$labels = ();
    #%$colors = ();
    return
        grep {
               ($filter->{text}  ? match_terms( $filter->{text}, $_ )   : 1)
            && ($filter->{color} ? match_color( $filter->{color}, $_ ) : 1)
            && ($filter->{label} ? match_label( $filter->{label}, $_ ) : 1)
            && ($filter->{created} ? match_range( $filter, 'created', $_ ) : 1)
            && ($filter->{updated} ? match_range( $filter, 'updated', $_ ) : 1)
        }
        map {
            my $n = $_;

            # While we're at it, also read in all labels
            if( $n->frontmatter->{labels}) {
                $labels->{ $_ } = 1 for $n->frontmatter->{labels}->@*;
            }

            # While we're at it, also read in all used colors
            $colors->{ $n->frontmatter->{color} } = 1
                if $n->frontmatter->{color};

            # While we're at it, sort the items in buckets
            #$created_buckets->{ $n->frontmatter->{created} }++
            #    if $n->frontmatter->{created};

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

our %field_properties = (
    title => { reload => 1 },
);

sub display_note( $c, $note ) {
    return login_detour($c) unless $c->is_user_authenticated;

    $c->stash( note => $note );
    my $session = get_session( $c );
    my $filter = fetch_filter( $c );

    my $html = as_html( $c, $note );
    $c->stash( note_html => $html );
    $c->stash( all_labels => $session->labels );
    $c->stash( filter => $filter );
    $c->stash( moniker => filter_moniker( $filter ));
    $c->stash( show_filter => !!$c->param('show-filter') );

    # Meh - we only want to set this to true if a request is coming from
    # this page during a field edit, not during generic page navigation
    $c->stash( htmx_update => $c->is_htmx_request() );

    my $editor = $c->param('editor') // $session->editor // 'markdown';
    $session->editor( $editor );
    # Sanitize
    $c->stash( editor => $editor );

    stash_filter( $c, $filter );

    $c->stash( edit_field => undef);
    $c->stash( field_properties => \%field_properties);

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

    # We'll create a file here, no matter whether there is content or not
    my $note;
    my $fn;
    if( my $title = $c->param('title')) {
        # Save note to new title
        $fn =    clean_fragment( $title ) # derive a filename from the title
              || 'untitled'; # we can't title a note "0", but such is life

        $fn = $session->document_directory . '/' . $fn . ".markdown";
        $fn = basename( find_name( $fn )); # find a filename that is not yet used

        $note //= find_or_create_note( $session, $fn );
        $note->frontmatter->{title} = $title;

    } else {
        $fn = $session->tempnote();
    }

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
        $note->add_label( $c );
    }
    if( my $body = $c->param('body-markdown')) {
        $note //= find_note( $session, $fn );
        $note->body( $body );
    }
    if( my $body_html = $c->param('body-html')) {
        $note //= find_note( $session, $fn );
        my $turndown = Text::HTML::Turndown->new();
        $turndown->use('Text::HTML::Turndown::GFM');
        my $body = $turndown->turndown($body_html);
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
    my $filter = fetch_filter($c);

    my $session = get_session( $c );
    $c->stash( filter => $filter );
    my $note = find_note( $session, $c->param('fn'));
    display_note( $c, $note );
};

sub save_note( $session, $note, $fn ) {
    my $ts = time;
    warn "Setting creation timestamp to " . timestamp( $ts )
        if ! $note->frontmatter->{created};
    $note->frontmatter->{created} //= timestamp( $ts );
    $note->frontmatter->{updated} = timestamp( $ts );
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

    my $p = $c->req->params()->to_hash;
    my $body;
    if( exists $p->{'body-markdown'}) {
        $body = $p->{'body-markdown'};

    } elsif( exists $p->{'body-html'}) {
        my $turndown = Text::HTML::Turndown->new();
        $turndown->use('Text::HTML::Turndown::GFM');
        $body = $turndown->turndown($c->param('body-html'));
    }

    $body =~ s/\A\s+//sm;
    $body =~ s/\s+\z//sm;

    $note->body($body);
    save_note( $session, $note, $fn );

    $c->redirect_to($c->url_for( '/note/'. $fn ));
};

sub delete_note( $c ) {
    return login_detour($c) unless $c->is_user_authenticated;

    my $session = get_session( $c );
    my $fn = $c->param('fn');
    my $note = find_note( $session, $fn );

    if( $note ) {
        # Save undo data?!
        $c->stash( undo => '/undelete/' . $note->filename );
        $note->frontmatter->{deleted} = timestamp(time);
        save_note( $session, $note, $fn );
        move_note( $session->document_directory . "/" . $note->filename  => $session->document_directory . "/deleted/" . $note->filename );
    }

    # Can we keep track of current filters and restore them here?

    $c->redirect_to($c->url_for('/'));
}

sub archive_note( $c ) {
    return login_detour($c) unless $c->is_user_authenticated;

    my $session = get_session( $c );
    my $fn = $c->param('fn');
    my $note = find_note( $session, $fn );

    if( $note ) {
        # Save undo data?!
        $c->stash( undo => '/unarchive/' . $note->filename );
        $note->frontmatter->{archived} = timestamp(time);
        save_note( $session, $note, $fn );
        move_note( $session->document_directory . "/" . $note->filename  => $session->document_directory . "/archived/" . $note->filename );
    }

    # Can we keep track of current filters and restore them here?

    $c->redirect_to($c->url_for('/'));
}

sub move_note( $source_name, $target_name ) {
    $target_name = find_name( $target_name );
    warn "We want to rename from '$source_name' to '$target_name'";
    rename $source_name => $target_name;

    return $target_name
}

=head2 C<< find_name $target_name >>

  my $new_name = find_name( $target_name );

Using the base name of C<$target_name>, finds a suitable filename that does
not exist for that user.

C<$target_name> must include the directory.

Returns the full (free) name of the file

This subroutine would be subject to race conditions.

=cut

sub find_name( $target_name ) {
    my $count = 0;
    my $tn = Mojo::File->new( $target_name );
    my $target_directory = $tn->dirname;
    my $base_name = $tn->basename;
    $base_name =~ s/\.markdown\z//;

    if( $base_name =~ s! \(\d+\)\z!! ) {
        $count = $1;
    };

    # Yes, this has the potential for race conditions, but we don't
    # To reduce the amount of race conditions, either create the filename here
    # or don't even return the filename but also an open filehandle to
    # directly write to that file, much like tempfile()
    while( -f $target_name ) {
        # maybe add todays date or something to prevent endless collisions?!
        $target_name = sprintf "%s/%s (%d).markdown", $target_directory, $base_name, $count++;
        #warn "Checking if '$target_name' exists (inner)";
    }

    #warn "New name: '$target_name'";
    return $target_name
}

=head2 copy_note( $source_name )

Creates a copy of a note with a new name and redirects to it

=cut

sub copy_note( $c ) {
    return login_detour($c) unless $c->is_user_authenticated;

    my $session = get_session( $c );
    my $fn = $c->param('fn');
    my $note = find_note( $session, $fn );

    if( $note ) {
        # Save undo data?!
        $c->stash( undo => '/uncopy/' . $note->filename );
        my $filename = $session->clean_filename( $fn );
        my $new_name = basename( find_name( $filename ));
        $note->frontmatter->{created} = timestamp(time);
        warn "Saving to '$new_name'";
        save_note( $session, $note, $new_name );
        return $c->redirect_to($c->url_with('/note/' . $new_name ));
    } else {
        $c->redirect_to($c->url_for('/'));
    }
}

post '/note/*fn' => \&save_note_body;
post '/note/' => \&save_note_body; # we make up a filename then
post '/delete/*fn' => \&delete_note;
post '/archive/*fn' => \&archive_note;
post '/copy/*fn' => \&copy_note;

sub edit_field( $c, $note, $field_name ) {
    return login_detour($c) unless $c->is_user_authenticated;

    my $session = get_session( $c );
    $c->stash( note => $note );
    $c->stash( field_name => $field_name );

    $c->stash( field_properties => $field_properties{ $field_name } // {} );
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

sub edit_note_title( $c, $inline = 0 ) {
    return login_detour($c) unless $c->is_user_authenticated;

    my $session = get_session( $c );
    my $fn = $c->param('fn');
    if( ! $fn) {
        $fn = tempnote();
        $c->htmx->res->replace_url($c->url_for("/note/$fn"));
    }

    my $note = find_or_create_note( $session, $fn );

    if( $inline ) {
        return edit_field( $c, $note, 'title' );
    } else {
        $c->stash( edit_field => 'title' );
        $c->stash( note => $note );
        $c->render('note');
    }
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
    $c->stash( field_properties => $field_properties{ $field_name } // {} );
    $c->render('display-text');
}

sub display_note_title( $c ) {
    return login_detour($c) unless $c->is_user_authenticated;

    my $session = get_session( $c );
    my $fn = $c->param('fn');
    my $note = find_note( $session, $fn );
    display_field( $c, $fn, $note, 'title', 'title', 0 );
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

    #if( $autosave ) {
    #    warn "Redirecting to editor with (new?) name '$fn'";
    #    $c->redirect_to($c->url_for('/edit-title/') . $fn );
    #
    #} else {
        warn "Redirecting to (new?) name '$fn'";
        $c->redirect_to($c->url_for('/note/'. $fn ));
    #}
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
    $c->redirect_to($c->url_for('/note/' . $note->filename ));
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
    $c->redirect_to($c->url_for('/note/' . $note->filename ));
}

sub edit_labels( $c, $inline ) {
    return login_detour($c) unless $c->is_user_authenticated;

    my $session = get_session( $c );
    my $note = find_note( $session, $c->param('fn') );
    my $filter = $c->param('label-filter');

    my %labels;
    @labels{ keys $session->labels->%* } = (undef) x keys $session->labels->%*;
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
        $c->redirect_to($c->url_for('/note/' . $fn ));
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

    my $status;
    if ( defined $v ) {
        $status = $v;
    } else {
        $status = 1;
    };

    $note->update_labels( $status, [$label] );
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

    $note->remove_label( $remove );
    $note->save_to( $session->clean_filename( $fn ));

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

sub stash_filter( $c, $filter ) {
    my $session = get_session( $c );
    $c->stash( filter => $filter );
    $c->stash( labels => [sort { fc($a) cmp fc($b) } keys $session->labels->%*] );
    $c->stash( types  => [] );
    $c->stash( colors => [sort { fc($a) cmp fc($b) } keys $session->colors->%*] );
    $c->stash( created_buckets => $session->created_buckets );
}

sub select_filter( $c ) {
    return login_detour($c) unless $c->is_user_authenticated;

    my $session = get_session( $c );

    my $filter = fetch_filter($c);
    stash_filter( $c, $filter );
    $c->stash( moniker => filter_moniker( $filter ));
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

sub export_archive( $c ) {
    return login_detour($c) unless $c->is_user_authenticated;

    my $session = get_session( $c );

    my $base = Mojo::File->new( $session->document_directory());
    my $zip = Archive::Zip->new();
    warn "Archiving $base";
    File::Find::find( {
        wanted => sub {
                if( -f $File::Find::name ) {
                    my $ar_name = Mojo::File->new( $File::Find::name )->abs2rel($base);
                    warn "Adding $File::Find::name as $ar_name";
                    $zip->addFile( $File::Find::name => "$ar_name" );
                    }
            },
        follow_skip => 1, # no symlinks or anything
        no_chdir => 1,
    }, "$base" );
    open my $fh, '>', \my $memory;
    $zip->writeToFileHandle( $fh );
    my $fn = strftime "notekeeper-export-%Y-%m-%d-%H-%M-%S.zip", gmtime;
    $c->res->headers->content_disposition(qq{attachment; filename="$fn"});
    $c->res->headers->content_type('application/zip');
    $c->render( data => $memory );
}

# User authentification

{
    sub plaintext($password, $hash) {
        return $password eq $hash;
    }
    my $passphrase = Crypt::Passphrase->new(
        encoder    => 'Argon2',
        validators => [ \&plaintext ],
    );
    sub load_account ($u) {
        $u =~ s![\\/]!!g;
        my $fn = "$user_directory/$u.yaml";
        try {
            if( -f $fn and -r $fn ) {
                # libyaml still calls exit() in random situations
                return LoadFile( $fn );
            }
        } catch ($e) {
            warn "Got exception: $e";
            return undef
        }
    };
    sub validate ($u, $p) {
        my $account = load_account($u) or return;
        if( !$passphrase->verify_password( $p, $account->{pass} )) {
            return undef;

        } elsif( $passphrase->needs_rehash($account->{pass})) {
            say "Upgrading password hash for <$u>";
            my $new_hash = $passphrase->hash_password( $p );
            $account->{pass} = $new_hash;
            DumpFile( "$user_directory/$u.yaml", $account )
        };

        return 1
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
    my $path_uri = Mojo::URL->new($path);
    my @path_parts = grep /\S/, split m{/}, $path_uri->path;
    app->hook( before_dispatch => sub( $c ) {
        my $url = $c->req->url;
        warn "URL  is     <$url>";
        my $base = $url->base;
        unshift @{ $base->path }, @path_parts;
        $base->path->trailing_slash(1);
        $url->path->leading_slash(0);
        #$url->scheme($path_uri->protocol);
        $base->scheme($path_uri->protocol);

        if( my $f = $c->req->headers->header('X-Forwarded-Host')
            and not $path_uri->host ) {
            # We could guess the host here if it wasn't set in MOJO_REVERSE_PROXY
            # This requires that the outside-facing server resets
            # X-Forwarded-Host , so that header is not allowed to be user-controllable
            (my $host) = split /,/, $f;
            #$url->host( $host );
            $base->host( $host );
        } else {
            #$url->host($path_uri->host);
            $base->host($path_uri->host);
        }

        warn "Base is     <$base>";
        warn "URL  is now <$url>";
        $url->base( $base );
    });
}

sub login_detour( $c ) {
    # Somehow save the request parameters in the session
    # This once more means we really need a local (in-memory if need be) session module
    # for Mojolicious
    # XXX we should also preserve form uploads here?!
    if( ! $c->session( 'return_to' )) {
        # Only set a new return_to path if we don't have one already
        $c->session( return_to => $c->req->url->to_abs );
    }

    # Make the redirect URL relative

    my $login = $c->url_for('/login');
    warn "Detouring for login to <$login>";
    return $c->redirect_to($login);
}

get '/login' => sub ($c) { $c->render(template => 'login') };
post '/login' => sub ($c) {
    my $username = $c->param('username');
    my $password = $c->param('password');
    if ($c->authenticate($username, $password)) {
        #warn $c->is_user_authenticated ? 'YES' : 'NOT YET';

        my $next = $c->url_for('/');
        if( $c->is_user_authenticated ) {
            #$c->session( user => get_session($username) );
            $next = $c->session('return_to') // $c->url_for( '/' );
            $c->session('return_to' => undef);
        };
        $next = Mojo::URL->new($next)->to_abs();
        $c->redirect_to($next);
    }
    else {
        # XXX also here, we should preserve form uploads etc.
        $c->redirect_to($c->url_for('/login'));
    }
    return;
};

post '/logout' => sub ($c) {
    $c->logout if $c->is_user_authenticated;
    return $c->redirect_to('/');
};


get  '/edit-title' => \&edit_note_title; # empty note
get  '/edit-title/*fn' => \&edit_note_title;
get  '/htmx-edit-title' => sub( $c ) { edit_note_title( $c, 1 ) }; # empty note
get  '/htmx-edit-title/*fn' => sub( $c ) { edit_note_title( $c, 1 ) };
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

get  '/export-archive' => \&export_archive;
get '/setup' => \&render_setup;

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
    if( my $w = $options{ search } ) {
        my @t = shellwords($w);
        my $t = join "|", map { quotemeta $_ } shellwords( $w );
        $body =~ s!($t)!<mark>$1</mark>!gi;
    };

    my $html = $renderer->convert( $body );
    if( $options{ strip_links } ) {
        $html =~ s/<a\s+href=[^>]*?>//gsi;
        $html =~ s!</a>!!gsi;
    }

    my $base = $c->url_for('/note/');
    $html =~ s!<img src="\K(?=attachments/[^"]+\.(?:png|jpg|jpeg|gif)")!$base!gi;
    $html =~ s!<img src="(attachments/[^"]+\.(?:ogg|mp3|aac))"!<audio src="$base$1" controls>!g;

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
%=include('navbar', type => 'documents', colors => $colors, labels => $labels, show_filter => $show_filter);
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
          <a class="dropdown-item" href="<%= url_for("/new ")->query({ label => 'Template', 'body-markdown' => "Alternatively just add the 'Template' tag to a note" }) %>">+ Create a new template</a>
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
    <a href="<%= url_for( "/note/" . $doc->filename ) %>" class="title">
    <div class="title-text"><%= $doc->frontmatter->{title} %></div>
    </a>
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

@@ setup.html.ep
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
%=include 'htmx-header'

<title>Notekeeper - Setup</title>
</head>
<body
    hx-boost="true"
    id="body"
    hx-ext="morphdom-swap"
    hx-swap="morphdom"
>
%=include('navbar', type => 'documents', colors => $colors, labels => $labels, show_filter => $show_filter);
<div class="container-fluid" id="container">
<div class="row flex-nowrap">
    <div class="col-auto px-0">
%=include 'sidebar', labels => $labels, filter => $filter,
    </div>
    <main class="col">
    <h1>Clip anything on the web</h1>
    <p>Drag <a href="<%= $bookmarklet %>">this link</a> to your bookmarks to clip the current selection
    as a new note</p>
    </main>
</div>
</body>
</html>

@@navbar.html.ep
<nav class="navbar navbar-expand-lg sticky-top bd-navbar bg-light">
<div class="container-fluid">
% if( $type eq 'documents' ) {
    <ul class="navbar-nav me-auto">
    <li class="nav-item">
        <a href="#" data-bs-target="#sidebar" data-bs-toggle="collapse"
               class="border rounded-3 p-1 text-decoration-none"><i class="bi bi-list bi-lg py-2 p-1"></i> Labels</a>
    </li>
    <li class="nav-item"><a href="<%= url_for( "/" )%>">index</a></li>
    <li class="nav-item">
      <div id="form-filter-2">
      <form id="form-filter-instant" method="GET" action="<%= url_with( "/" )->query({ "show-filter" => 1 }) %>">
% if( $show_filter ) {
%=include('select-filter', types => [], colors => $colors, labels => $labels, moniker => $moniker, created_buckets => $created_buckets)
% } else {
%# We already have a selection
        <input id="text-filter" name="q" value="<%= $filter->{text}//'' %>"
            placeholder="Search"
            hx-get="<%= url_with( "/" )->query( 'show-filter'=>1 ) %>"
            hx-trigger="focus"
            hx-target="#body"
        />
% }
      </form>
      </div>
    </li>
    </ul>
% } elsif( $type eq 'note' ) {
    <ul>
    <li><a href="<%= url_with( "/" ) %>"
            hx-trigger="click, keyup[key=='Escape'] from:body"
        ><span class="rounded-circle fs-3">&#x2715;</span></a></li>
    <!-- delete note -->
    </ul>
% }
    <ul class="navbar-nav ms-auto" >
    <li class="nav-item">
    <a href="https://github.com/Corion/App-notes-htmx" target="_blank">Github</a>
    </li>

% if( $user ) {
    <li class="nav-item dropdown">
    <div class="btn btn-secondary dropdown-toggle"
        data-bs-toggle="dropdown"><%= "\N{BUST IN SILHOUETTE}" %></div>

    <div class="dropdown-menu dropdown-menu-end dropdown-menu-right">
    <div class="dropdown-item">
      <a href="<%= url_for('/setup') %>"
          class="btn btn-secondary" id="setup">⚙</a>
    </div>
    <div class="dropdown-item">
      <a id="btn-export"
        hx-boost="false"
        href="<%= url_for('/export-archive')%>"
        class="btn btn-secondary" id="export">Export notes</a>
    </div>
    <div class="dropdown-item">
      <form id="form-logout" method="POST" action="<%= url_for( "/logout" ) %>">
      <button name="logout"
          class="btn btn-secondary" id="logout">Log '<%= $user->{user} %>' out</button>
      </form>
    </div>
    </div>
    </li>
% }
    </ul>
</div>
</nav>

@@sidebar.html.ep
<div id="sidebar" class="collapse collapse-horizontal border-end <%= $sidebar ? 'show' : '' %> sticky-top">
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
%=include('navbar', type => 'note', show_filter => $show_filter );

<div id="note-container" class="container-flex">
% my $bgcolor = $note->frontmatter->{color}
%               ? sprintf q{ style="background-color: %s;"}, $note->frontmatter->{color}
%               : '';
%=include 'display-labels', labels => $note->frontmatter->{labels}, note => $note
<div class="single-note"<%== $bgcolor %>>
<div>Filename: <%= $note->filename %></div>
<div id="editor-switch" class="nav nav-tabs">
% my $active = $editor eq 'html' ? ' active' : '';
    <div class="nav-item"><a class="nav-link<%= $active %>" href="<%= url_with()->query({ editor => 'html' }) %>">HTML</a></div>
%    $active = $editor eq 'markdown' ? ' active' : '';
    <div class="nav-item"><a class="nav-link<%= $active %>" href="<%= url_with()->query({ editor => 'markdown' }) %>">Markdown</a></div>
</div>
% my $doc_url = '/note/' . $note->filename;
<form action="<%= url_for( $doc_url ) %>" method="POST">
<button class="nojs" name="save" type="submit">Save</button>
% if( $edit_field and $edit_field eq 'title' ) {
%=include "edit-text", field_name => 'title', value => $note->frontmatter->{title}, class => 'title', reload => 1, field_properties => $field_properties->{title},
% } else {
%=include "display-text", field_name => 'title', value => $note->frontmatter->{title}, class => 'title', reload => 1
% }
<div class="xcontainer" style="height:400px">
% if( $editor eq 'markdown' ) {
<textarea name="body-markdown" id="note-textarea" autofocus
    hx-post="<%= url_for( $doc_url ) %>"
    hx-trigger="#note-textarea, keyup delay:200ms changed"
    hx-swap="none"
><%= $note->body %></textarea>
% } elsif( $editor eq 'html' ) {
%# This can only work with JS enabled; well, the saving
<div id="note_html"
    hx-post="<%= url_for( $doc_url ) %>"
    hx-vals='js:{"body-html":htmx.find("#usercontent").innerHTML}'
    hx-trigger="input"
    hx-swap="none"
    >
    <!-- This is untrusted content, so tell HTMX that -->
    <div id="usercontent"
        hx-disable="true"
        contentEditable="true"><%== $note_html %></div>
</div>
% }
</div>
</form>
    <div class="edited-date"><%= $note->frontmatter->{updated} %></div>
</div>
</div>
<div id="actionbar" class="navbar mt-auto fixed-bottom bg-light">
    <div id="action-attach">
        <a href="<%= url_for( "/attach-image/" . $note->filename ) %>"
            class="btn btn-secondary"
            hx-get="<%= url_for( "/attach-image/" . $note->filename ) %>"
            hx-swap="outerHTML"
        >Add Image</a>
    </div>
    <div id="action-attach-audio">
%=include('attach-audio', note => $note, field_name => 'audio' );
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
    <div id="action-copy">
        <form action="<%= url_for('/copy/' . $note->filename ) %>" method="POST"
        ><button class="btn btn-secondary" type="submit">&#xFE0E;⎘</button>
        </form>
    </div>
    <div id="action-archive">
        <form action="<%= url_for('/archive/' . $note->filename ) %>" method="POST"
        ><button class="btn btn-secondary" type="submit">&#xFE0E;&#x1f5c3;</button>
        </form>
    </div>
    <div id="action-delete">
        <form action="<%= url_for('/delete/' . $note->filename ) %>" method="POST"
        ><button class="btn btn-secondary" type="submit">&#xFE0E;&#x1F5D1;</button>
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
<h1>Log into notekeeper</h1>
  <div id="container" class="grid-container" hx-history-elt>
      <form action="<%= url_for( '/login' )%>" method="POST">
          <input type="text" autofocus name="username" value="" text="Username" />
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
    hx-get="<%= url_for( "/htmx-edit-$field_name/" . $note->filename ) %>"
    hx-target="closest div"
    hx-swap="innerHTML"
    >&#x270E;</a>
% } else {
    <a class="editable"
       href="<%= url_for( "/edit-$field_name/" . $note->filename ) %>"
%#     if( !$reload ) {
       hx-get="<%= url_for( "/htmx-edit-$field_name/" . $note->filename ) %>"
       hx-target="closest div"
       hx-swap="innerHTML"
%#     }
    ><%= $field_name %></a>
% }
</div>

@@edit-text.html.ep
<form action="<%= url_for( "/edit-$field_name/" . $note->filename ) %>" method="POST"
% if( $field_properties->{ reload } ) {
    hx-trigger="blur from:#note-input-text-<%= $field_name %>"
% } else {
    hx-swap="outerHTML"
% }
>
    <input type="text" name="<%= $field_name %>" id="note-input-text-<%= $field_name %>" value="<%= $value %>"
        autofocus
    />
    <button type="submit" class="nojs">Save</button>
<!--
    <a href="<%= url_for( "/note/" . $note->filename ) %>"
% if( $field_properties->{ reload } ) {
       hx-post="<%= url_for( "/edit-display" )%>-<%= $field_name %>/<%= $note->filename %>"
% } else {
       hx-get="<%= url_for( "/display" )%>-<%= $field_name %>/<%= $note->filename %>"
       hx-target="#note-<%= $field_name %>"
       hx-swap="innerHTML"
% }
    >x</a>
-->
</form>

@@attach-image.html.ep
<form action="<%= url_for( "/upload-$field_name/" . $note->filename ) %>" method="POST"
    enctype='multipart/form-data'
    hx-trigger="input from: find #upload-<%=$field_name%>"
>
    <label for="upload-<%=$field_name%>">Upload image</label>
    <input id="upload-<%=$field_name%>" type="file" accept="image/*"
           name="<%= $field_name %>" id="capture-image-<%= $field_name %>"
           capture="environment"
    />
    <button type="submit" class="nojs">Upload</button>
    <a href="<%= url_for( "/note/" . $note->filename ) %>"
       hx-get="xxx-display-actions"
       hx-target="xxx"
       hx-swap="innerHTML"
       hx-trigger="blur from:#note-input-text-<%= $field_name %>"
    >x</a>
</form>

@@attach-audio.html.ep
<div id="audio-recorder" >
    <button class="btn btn-primary" id="button-record" onclick="startRecording()">&#x1F399;</button>
    <form action="<%= url_with( "/upload-audio/" . $note->filename ) %>"
          style="display: none;"
          method="POST"
          enctype="multipart/form-data"
          id="form-audio-upload"
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
        hx-target="this"
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
  hx-disinherit="hx-target"
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
      <form id="form-filter-instant" method="GET" action="<%= url_for( "/" ) %>">
        <div class="input-group">
        <input id="text-filter" name="q" value="<%= $filter->{text}//'' %>"
            placeholder="<%== $moniker %>"
            hx-get="<%= url_with( "/filter" ) %>"
            hx-trigger="input delay:200ms changed, keyup[key=='Enter'], load"
            hx-target="#documents"
            hx-swap="outerHTML"
            autofocus
        />
        <span class="input-group-append">
% if ( keys $filter->%* ) {
            <a class="btn btn-white border-start-0 border" type="button"
            href="<%= url_for('/')->query('show-filter'=>1) %>"
            >x</a>
% }
        </span>
        </div>
      </form>
<!-- (note) types (images, lists, ...) -->
% if( $types->@* ) {
<div>
<h2>Types</h2>
%    for my $t ($types->@*) {
    <a href="<%= url_with('/')->query({ type => $t }) %>"><%= $t %></a>
%    }
</div>
%}
% if( $labels->@* ) {
<div>
<h2>Labels</h2>
%    for my $l ($labels->@*) {
    <a href="<%= url_with('/')->query({ label => $l }) %>"><%= $l %></a>
%    }
</div>
%}
<!-- things -->
% if( $colors->@* ) {
<div>
<h2>Colors</h2>
%    for my $l ($colors->@*) {
    <a href="<%= url_with('/')->query({ color => $l }) %>"><span class="color-circle" style="background-color:<%== $l %>;">&nbsp;</span></a>
%    }
</div>
%}
<!-- date created -->
% if( $created_buckets->@* ) {
<div>
<h2>Created</h2>
%    for my $t ($created_buckets->@*) {
    <a href="<%= url_with('/')->query({ 'created.start' => $t->{start}, 'created.end' => $t->{end} }) %>"><%= $t->{vis} %></a>
%    }
</div>
%}
</div>
