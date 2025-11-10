#!perl
use 5.020;
use Carp 'croak';
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
use List::Util 'first', 'reduce';

# For search
use Text::ParseWords 'shellwords';
use Text::Unidecode 'unidecode';

use Crypt::Passphrase;
use Crypt::Passphrase::Argon2;

use App::Notetaker::Document;
use App::Notetaker::Session;
use App::Notetaker::Label;
use App::Notetaker::LabelSet;
use App::Notetaker::Utils 'timestamp';
use App::Notetaker::PreviewFetcher;

use Markdown::Perl;
use Text::HTML::Turndown;
use Date::Period::Human;

use File::Find;
use Archive::Zip;

app->static->with_roles('+Compressed');
plugin 'DefaultHelpers';
plugin 'HTMX';
#plugin 'Gzip'; # fails since Mojolicious 9.23

my %sessions;

my $base_directory = $ENV{ TEST_NOTES_BASE } // '.';
my $user_directory = "$base_directory/users";

sub get_session( $c ) {
    my $user = $c->current_user;

    return $sessions{ $user->{user} }
        if $sessions{ $user->{user} };

    # Maybe we should simply read the notes and their labels here?
    # That way we have the full list of labels at the start, at the "price"
    # of touching all notes on user login, potentially twice

    my $s = App::Notetaker::Session->new(
        username => $user->{user},
        document_directory => $user->{notes},
        labels => App::Notetaker::LabelSet->new(),
    );
    return $sessions{ $user->{user} } = $s;
}

sub date_range_visual( $range ) {
    my $d = Date::Period::Human->new({ lang => 'en' });
    my $s = $d->human_readable( $range->{start} =~ s/\A(..........)T(........)Z\z/$1 $2/gr );
    my $e = $d->human_readable( $range->{end}   =~ s/\A(..........)T(........)Z\z/$1 $2/gr );
    return qq{between $s and $e};
}

=head2 C<< fetch_filter >>

  my $filter = fetch_filter( $c, $created_buckets );

Fetches the current filter settings from the request in C< $c > and returns
it as a hashref.

The current keys are:

=over 4

=item B<q>

The search term, parsed into whitespace separated tokens. Parsing is done
using C<shellwords()>, so you can embed whitespaces by using quotes.

The search term can also contain C<#foo> to search for label C<#foo>.
That word will then be returned as a C<text_or_label> C<foo>
instead.

=item B<folder>

The folders to also include. Valid values are C<archived> and C<deleted>.

=item B<label>

The note label (multiple allowed)

=item B<color>

The note colors, formatted as C< #xxxxxx > (multiple allowed)

=item B<created-between>

The ranges for note creation. The note creation date, must be before C<.end>
and after C<.start>.

Both values will be returned in the C< created-between > array as a subhash.

=back

=cut

sub fetch_filter( $c, $created_buckets ) {
    my @include = $c->every_param('folder')->@*;

    my $text = $c->param('q');
    my $terms = [shellwords( $text )];
    my $col = $c->every_param('color');
    if( ! $col->@* ) {
        undef $col;
    };

    my $lab = $c->every_param('label');
    if( ! $lab->@* ) {
        undef $lab;
    };

    my $unlabeled = $c->param('no-label') ? 1 : undef;

    my $created = $c->every_param('created-range');
    my %bucket = map { $_->{vis} => $_ } $created_buckets->@*;
    $created = [map { $bucket{ $_ } } $created->@*];

    my $filter = {
        maybe label         => $lab,
        maybe unlabeled     => $unlabeled,
        maybe text          => $terms,
        maybe text_as_typed => $text,
        maybe color         => $col,
        maybe created       => ($created->@* ? $created : undef ),
        maybe include       => (@include ? \@include : () ),
    };
    if( $filter->{color} ) {
        $filter->{color}->@* = grep { /\A#[0-9a-f]{6}\z/ }
                                    $filter->{color}->@*
                                    ;
    }

    # Restructure the query in the filter text:
    if( my @labels = grep { /^#/ } $filter->{ text }->@* ) {
        $filter->{ text }->@* = grep { !/^#/ } $filter->{ text }->@*;
        $filter->{ text_or_label } = \@labels;
    }
    return $filter
}

=head2 C<< filter_moniker( $filter ) >>

  my $description = filter_moniker( fetch_filter( $c ));

Returns an (English) textual description of the current filter.

=cut

sub filter_moniker( $filter ) {
    my ($attr, $location, $created);
    if( $filter->{label} && $filter->{label}->@* ) {
        $location = join ", ", map { "'$_'" } $filter->{label}->@*
    } elsif( $filter->{unlabeled} ) {
        $location = "unlabeled"
    }
    if( $filter->{color} and $filter->{color}->@* ) {
        $attr = qq{color notes};
    }
    if( $filter->{created} ) {
        $created = join "or", map { date_range_visual( $_ ) } $filter->{created}->@*;
    }
    return join " ", grep { defined $_ and length $_ } ($attr, $location, $created);
}

=head2 C<< filter_query( $filter, $created_buckets ) >>

Returns an arrayref with list of pairs suitable for constructing a
L<Mojo::URL> query string that encodes the filter.

    my $u = $c->uri_for("/")->query( filter_query( $filter, [...] ));

This is convenient if you want to persist a filter for the user.

=cut

sub filter_query( $filter ) {
    my %names = (
        'text_as_typed' => 'q',
        'text' => undef,
        'text_or_label' => undef,
        'include' => 'folder',
        'unlabeled' => 'no-label',
    );

    my @res;

    if( my $c = delete $filter->{created} ) {
        push @res, map {; "created-range" => $_->{vis} } $c->@*;
    }

    for my $k (keys $filter->%*) {
        if( exists $names{ $k }) {
            my $v = delete $filter->{$k};
            if( my $n = $names{ $k }) {
                push @res, $n => $v;
            }
        }
    }
    for my $k (sort keys $filter->%*) {
        push @res, $k, $filter->{$k};
    }

    return \@res;
}

sub render_notes($c) {
    my $sidebar = $c->param('sidebar');
    my $session = get_session( $c );
    my $filter = fetch_filter($c, $session->created_buckets);
    my @documents = get_documents($c, $session, $filter);

    my @templates = get_templates($c, $session);

    # Now that we have the templates, we can assign colors to the labels:
    my %count;
    my %color = map {
        my $n = $_;
        my $c = $n->frontmatter->{color};
        my @res;
        if( $c ) {
            @res = map { $count{$_}++; $_ => $c } $n->labels->labels->@*
        }
        @res
    } @templates;
    my $labels = $session->labels->labels;
    $labels->@* = map {
        my $l = $_;
        if( ($count{ $l } // 0) == 1 ) {
            # We have a single template with a color
            $l = App::Notetaker::Label->new( text => $l, color => $color{ $l } );
        } else {
            $l = App::Notetaker::Label->new( text => $l );
        }
        $l
    } $labels->@*;

    # Group the labels according to hierarchy
    my %hierarchy = map { $_->text => $_ } $labels->@*;
    # Now sort the elements bottom-up into their hierarchy slot, removing them from the tree
     my @lower = sort { scalar($b =~ tr!/!/!) <=> scalar($a =~ tr!/!/!) || $b cmp $a }
                 grep { m!/! }
                 keys %hierarchy
                 ;
     for my $l (@lower) {
         my $v = delete $hierarchy{ $l };
         $l =~ m!^(.+)/([^/]+)\z!
             or die "Internal error: Item $l should contain a slash, but doesn't!";
         my ($p,$q) = ($1,$2);
         $v = $v->clone;
         $v->visual( $q );
         unshift $hierarchy{ $p }->{ details }->@*, $v;
         #$hierarchy{ $p }->{ details }->@* = sort { $a->{visual}->visual cmp $b->{visual}->visual} $hierarchy{ $p }->{ details }->@*;
     }

    for my $note ( @documents ) {
        my $repr;
        if( length $note->body ) {
            my $base = $c->url_for('/note/');
            $repr = as_html( $base, $note, strip_links => 0, search => $filter->{text} );
        } else {
            $repr = '&nbsp;'; # so even an empty note becomes clickable
        };
        $note->{html} = $repr;
    }

    $c->stash( label_hierarchy => \%hierarchy );

    $c->stash( documents => \@documents );
    $c->stash( show_filter => !!$c->param('show-filter') );

    # How do we sort the templates? By name?!
    @templates = sort { fc($a->title) cmp fc($b->title) } @templates;

    $c->stash( templates => \@templates );
    stash_filter( $c, $filter );
    $c->stash( sidebar => $sidebar );
    $c->stash( moniker => filter_moniker( $filter ));
}

sub render_index($c) {
    return login_detour($c) unless $c->is_user_authenticated;
    $c->session(expiration => 86400);
    render_notes( $c );
    $c->stash( hydrated => 1 );

    # Why do we need to push the updated URL here?!
    my $session = get_session( $c );
    my $filter = fetch_filter($c, $session->created_buckets);
    my $u = $c->url_for("/")->query(filter_query( $filter ));
    $c->htmx->res->replace_url( $u );

    $c->render('index');
}

sub render_filter($c) {
    return login_detour($c) unless $c->is_user_authenticated;
    render_notes( $c );
    # Set the filter URL so we can reload the page in the browser
    my $session = get_session($c);
    my $filter = fetch_filter($c, $session->created_buckets);
    my $u = $c->url_for("/")->query(filter_query( $filter ));
    $u->query( ["show-filter" => 1]);
    $c->htmx->res->replace_url( $u );
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

    my $session = get_session($c);
    my $filter = fetch_filter($c, $session->created_buckets);
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
    || unidecode( $note->body // '' ) =~ /\Q$filter\E/i
    ||          ( $note->title // '' ) =~ /\Q$filter\E/i
    || unidecode( $note->title // '' ) =~ /\Q$filter\E/i
}

# Does an AND match
sub match_terms( $terms, $note ) {
    return ! defined ( first { ! match_text( $_, $note ) } $terms->@* );
}

# Search either a test substring #foo, or a label foo
sub match_text_or_label( $text_or_label, $note ) {
    return ! defined ( first { ! (  match_label_substring( $_, $note )
                                 || match_text( "#".$_, $note )
                                 )
                             } $text_or_label->@* );
}

sub match_color( $color, $note ) {
    first { $_ eq ($note->frontmatter->{color} // '') } $color->@*
}

# Match a label as the entire string, case-insensitively
# Also match sub-labels, that is, "foo" also matches "foo/bar" (but not "fooz")
sub match_label( $labels, $note ) {
    my %l = map { fc $_ => 1 } $labels->@*;
    grep {
            my $label = $_;
               $l{ fc($label) }
               # Try if label is more specific than one of the selected labels
            // grep { $label =~ m!\A\Q$_/!i } keys %l;
         } ($note->labels->labels)->@*
}

sub match_unlabeled( $filter, $note ) {
    0 == ($note->labels->labels)->@*
}

# Match a label substring, case-insensitively
sub match_label_substring( $label, $note ) {
    $label =~ s/^#//;
    grep { /\Q$label\E/i } ($note->labels->labels)->@*
}

sub match_username( $filter, $user ) {
    grep { ($_//'') =~ /\Q$filter\E/i } ([$user->{user}, $user->{name}])->@*
}

sub match_field_range( $filter_list, $field, $note, $created_buckets ) {
    my $val = $note->frontmatter->{ $field } // '';
    my %bucket = map { $_->{vis} => $_ } $created_buckets->@*;
    for my $f ($filter_list->@*) {
        my $filter = $bucket{ $f->{vis} } // {};
        return 1 if (
                (!$filter->{ start } || $filter->{ start } le $val)
            and (!$filter->{ end }   || $filter->{ end } ge $val))
    }
    return;
}

sub match_range( $filter, $field, $note, $created_buckets ) {
    match_field_range( $filter->{$field}, $field, $note, $created_buckets )
}

sub match_path( $filter, $note ) {
    $filter //= [];
    my %allow = map { $_ => 1 } $filter->@*;
       $note->deleted && $allow{ deleted }
    || $note->archived && $allow{ archived }
    || (!$note->archived && !$note->deleted)
}

sub _expand_label_hierarchy( $l ) {
    my @h = (split m!/!, $l);
    my $acc;
    return map { $acc = (defined $acc ? "$acc/" : '') . $_ } @h
}

# If we had a real database, this would be the interface ...
# We cache the list of all documents per-request
sub all_documents( $session, $labels, $colors ) {
    # We are reading the full document list, so we can recreate the list of
    # labels and colors, purging labels that were since deleted

    $labels->%* = ();
    $colors->%* = ();

    my %last_edit;

    return
        map {
            my $n = $_;

            # While we're at it, also read in all labels
            # and expand the hierarchy
            $labels->add( map { _expand_label_hierarchy($_) } $n->labels->labels->@* )
                if (! $n->deleted);

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
            $last_edit{ $b } cmp $last_edit{ $a }
        }
        map {
            my $note = App::Notetaker::Document->from_file( $_, $session->document_directory );
            $last_edit{ $note } =    $note->frontmatter->{"content-edited"}
                                  || timestamp((stat($_))[9]); # most-recent changed;
            $note
        }
        $session->documents( include => ['deleted','archived'])
}

sub get_documents($c, $session, $filter={}) {
    my @all_documents;
    if( $c and my $d = $c->stash('documents')) {
        @all_documents = $d->@*
    } else {
        @all_documents = all_documents( $session, $session->labels, $session->colors );
        $c->stash('documents', \@all_documents)
            if $c;
    };

    my $created_buckets = $session->created_buckets;
    return
        grep {
               (match_path( $filter->{include}, $_ ))
            && ($filter->{text}  ? match_terms( $filter->{text}, $_ )  : 1)
            && ($filter->{text_or_label} && $filter->{text_or_label}->@* ? match_text_or_label( $filter->{text_or_label}, $_ )  : 1)
            && ($filter->{color} ? match_color( $filter->{color}, $_ ) : 1)
            && ($filter->{label} && $filter->{label}->@* ? match_label( $filter->{label}, $_ ) : 1)
            && ($filter->{unlabeled} ? match_unlabeled( $filter->{unlabeled}, $_ ) : 1)
            && ($filter->{created} ? match_range( $filter, 'created', $_, $created_buckets ) : 1)
            #&& ($filter->{updated_range} ? match_range( $filter, 'updated', $_ ) : 1)
        }
        @all_documents
}

# Ugh - we are conflating display and data...
sub get_templates( $c, $session ) {
    get_documents(  $c, $session, { label => ['Template'] } )
}

sub get_users($session, $filter={}, $include_self=1) {
    return
        grep {
               ($filter->{user}  ? match_username( $filter->{user}, $_ )   : 1)
            && (!$include_self   ? $_->{user} ne $session->username        : 1)
        }
        map {
            if( $_ =~ /(\w+)\.yaml\z/ ) {
                load_account( $1 )
            }
        }
        glob "$user_directory/*.yaml"
}

sub find_note( $session, $fn ) {
    my $filename = $session->clean_filename( $fn );

    if( -f $filename ) {
        return App::Notetaker::Document->from_file( $filename, $session->document_directory );
    };
    return;
}

sub find_or_create_note( $session, $fn ) {
    my $filename = $session->clean_filename( $fn );

    if( -f $filename ) {
        return App::Notetaker::Document->from_file( $filename, $session->document_directory );
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
    my ($dark_color, $dark_textcolor);
    if( !$note->frontmatter->{color}) {
        $note->frontmatter->{color} = '#7f7f7f';
    }

    # generate the dark/dimmed colors here as well
    # dim all colors by 20% (?)
    # Should we do that in the template instead?!

    my $session = get_session( $c );
    my $filter = fetch_filter($c, $session->created_buckets);

    my $base = $c->url_for('/note/');
    my $html = as_html( $base, $note );
    $c->stash( note_html => $html );
    $c->stash( moniker => filter_moniker( $filter ));
    $c->stash( show_filter => !!$c->param('show-filter') );
    my @templates = get_templates($c, $session);
    $c->stash( templates => \@templates);

    # Meh - we only want to set this to true if a request is coming from
    # this page during a field edit, not during generic page navigation
    $c->stash( htmx_update => $c->is_htmx_request() );

    my $editor = $c->param('editor') // $session->editor // 'markdown';
    # Sanitize the editor parameter
    ($editor) = grep { $_ eq $editor } (qw(html markdown));
    $editor //= 'markdown';
    $session->editor( $editor );

    $c->stash( selection_start => $c->param('selection-start') // 0 );
    $c->stash( selection_end => $c->param('selection-end') // 0);
    $c->stash( editor => $editor );

    stash_filter( $c, $filter );

    $c->stash( edit_field => undef);
    $c->stash( field_properties => \%field_properties);

    # no filtering yet
    my %shared_with;
    my @users = get_users( $session, { user => $filter }, undef);
    $shared_with{ $_ } = 1 for (keys $note->shared->%*);
    delete $shared_with{ $session->username };
    $c->stash( all_users => \@users );
    $c->stash( shared_with => \%shared_with );

    $c->render('note');
};

sub serve_attachment( $c ) {
    return login_detour($c) unless $c->is_user_authenticated;

    my $session = get_session( $c );
    my $fn = $c->param('fn');
    $fn =~ s![\x00-\x1f\\/]!!g;
    $c->reply->file( $session->document_directory . "/attachments/$fn" );
}

sub assign_template( $c ) {
    return login_detour($c) unless $c->is_user_authenticated;

    my $session = get_session( $c );
    my $fn = $c->param('fn');
    my $t = $c->param('template');
    my $template = find_note($session, $t);

    my $note = find_note( $session, $fn );
    if( $template ) {
        # Copy over the (relevant) attributes, or everything?!
        $note->{body} //= $template->{body};
        $note->labels->add(values $template->labels->as_set->%*);
        $note->labels->remove('Template');

        my $f = $template->{frontmatter};
        for my $k (keys $f->%*) {
            if(     $k ne 'created'
                and $k ne 'updated'
                and $k ne 'labels'
                and $k ne 'title'
                ) {
                $note->frontmatter->{$k} = $f->{$k};
            }
        }
        my $base = $c->url_for("/note/");
        save_note( $base, $session, $note, $fn );
    }
    $c->redirect_to( $c->url_for("/note/$fn"));
}

get '/index.html' => \&render_index;
get '/' => \&render_index;
get '/documents' => \&render_filter;

any  '/new' => sub( $c ) {
    return login_detour($c) unless $c->is_user_authenticated;

    my $session = get_session( $c );

    # We'll create a file here, no matter whether there is content or not
    my ($note, $changed);
    my $fn;
    if( my $title = $c->param('title')) {
        # Save note to new title
        $fn =    clean_fragment( $title ) # derive a filename from the title
              || 'untitled'; # we can't title a note "0", but such is life

        $fn = $session->document_directory . '/' . $fn . ".markdown";
        $fn = basename( find_name( $fn )); # find a filename that is not yet used

        $note //= find_or_create_note( $session, $fn );
        $note->frontmatter->{title} = $title;
        $changed = 1;

    } else {
        $fn = $session->tempnote();
    }

    if( my $t = $c->param('template')) {
        my $template = find_note($session, $t);
        # Copy over the (relevant) attributes, or everything?!
        $note //= find_note( $session, $fn );
        $note->{body} = $template->{body};
        $note->labels->add(values $template->labels->as_set->%*);
        $note->labels->remove('Template');

        my $f = $template->{frontmatter};
        for my $k (keys $f->%*) {
            if(     $k ne 'created'
                and $k ne 'updated'
                and $k ne 'labels'
                ) {
                $note->frontmatter->{$k} = $f->{$k};
            }
        }
        $changed = 1;
    }

    if( my $c = $c->param('color')) {
        $note //= find_note( $session, $fn );
        $note->frontmatter->{color} = $c;
        $changed = 1;
    }
    if( my $labels = $c->every_param('label')) {
        if( $labels->@* ) {
            $note //= find_note( $session, $fn );
            for my $l ($labels->@*) {
                $note->add_label( $l );
            }
            $changed = 1;
        }
    }
    if( my $body = $c->param('body-markdown')) {
        $note //= find_note( $session, $fn );
        $note->body( $body );
        $changed = 1;
    }
    if( my $image = $c->param('image')) {
        $note //= find_note( $session, $fn );
        my $image = $c->every_param('image');
        attach_image_impl( $session, $note, $image );
        $changed = 1;
    }
    if( my $files = $c->every_param('file')) {
        $note //= find_note( $session, $fn );
        attach_files( $session, $note, $files );
        $changed = 1;
    }
    if( my $body_html = $c->param('body-html')) {
        $note //= find_note( $session, $fn );
        my $turndown = Text::HTML::Turndown->new();
        $turndown->use('Text::HTML::Turndown::GFM');
        my $body = $turndown->turndown($body_html);
        $note->body( $body );
        $changed = 1;
    }
    if( $note ) {
        if( $changed ) {
            my $base = $c->url_for("/note/");
            save_note( $base, $session, $note, $fn );
        }
    }

    $c->redirect_to( $c->url_for("/note/$fn"));
};

# Yaah, this should be POST, but I'm lazy
get '/assign-template/*fn' => \&assign_template;

get  '/note/attachments/*fn' => \&serve_attachment;

get '/note/*fn' => sub($c) {
    return login_detour($c) unless $c->is_user_authenticated;
    my $session = get_session( $c );
    my $filter = fetch_filter($c, $session->created_buckets);

    $c->stash( filter => $filter );
    my $note = find_note( $session, $c->param('fn'));
    if( $note ) {
        display_note( $c, $note );
    } else {
        # Can we do better than redirecting to the general list of documents?
        # Should we attempt a search for the title? We would need a fuzzy search
        $c->redirect_to($c->url_for( '/' ));
    }
};

my @previewers = (qw(
    Link::Preview::SiteInfo::YouTube
    Link::Preview::SiteInfo::OpenGraph
    Link::Preview::SiteInfo::HTML
));

require Link::Preview::SiteInfo::YouTube;
require Link::Preview::SiteInfo::OpenGraph;
require Link::Preview::SiteInfo::HTML;


sub setup_fetcher {
    my $fetcher //= App::Notetaker::PreviewFetcher->new(
        previewers => \@previewers,
    );
    #$fetcher->on('pending' => sub($fetcher,$item) {
    #    use Data::Dumper;
    #    warn "pending:".Dumper $item;
    #});
    #$fetcher->on('error' => sub($fetcher,$item,$error) {
    #    use Data::Dumper;
    #    warn "error: $error:" . Dumper $item;
    #});
    #$fetcher->on('done' => sub($fetcher,$item) {
    #    use Data::Dumper;
    #    warn "done.".Dumper $item;
    #});
    return $fetcher;
}
our $fetcher = setup_fetcher();

sub update_links( $base, $session, $note ) {
    my @current_links = as_html($base, $note, strip_links => 0 ) =~ m!<a[^>]+href="([^"]+)"!g;
    my $previews = $fetcher->fetch_previews( \@current_links );

    $note->links->@* = sort { $a->{url} cmp $b->{url} } ($previews->@*);
    for my $l ($note->links->@*) {
        $l->{preview} = $l->{preview}->markdown
            if ref $l->{preview};
    }
}

sub save_note( $base, $session, $note, $fn ) {
    my $ts = time;
    warn "Setting creation timestamp to " . timestamp( $ts )
        if ! $note->frontmatter->{created};
    $note->frontmatter->{created} //= timestamp( $ts );
    $note->frontmatter->{updated} = timestamp( $ts );

    # Update username/version
    $note->frontmatter->{version} = timestamp( $ts );
    $note->frontmatter->{author} = $session->username;

    update_links( $base, $session, $note );

    my $target = $session->clean_filename( $fn );
    if( -f $target) {
        my $prev_version = App::Notetaker::Document->from_file( $target, $session->document_directory );
        if( $prev_version->body ne $note->body ) {
            #warn "Body changed:";
            #warn "Old: " . $prev_version->body;
            #warn "New: " . $note->body;
            $note->frontmatter->{"content-edited"} = timestamp(time());
        } else {
            $note->frontmatter->{"content-edited"} //= timestamp((stat($target))[9]);
        }

    } else {
        $note->frontmatter->{"content-edited"} = timestamp(time());

    }
use Data::Dumper; warn Dumper $note->frontmatter;
    $note->save_to( $target );
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

    if( $p->{version} ne $note->frontmatter->{"version"}) {
        warn "(Unhandled) edit conflict loses information.";

        warn sprintf "new: %s - %s - %s", $note->path, $p->{"version"}, $p->{"author"};
        warn sprintf "old: %s - %s - %s", $note->path, $note->frontmatter->{"version"}, $note->frontmatter->{"author"};
    }

    my $body;
    if( exists $p->{'body-markdown'}) {
        $body = $p->{'body-markdown'};

    } elsif( exists $p->{'body-html'}) {
        # Strip selection markers (and remember selection?)
        if( exists $p->{'selection-start'}) {
            $p->{'body-html'} =~ s/\Q$p->{'selection-start'}//g;
        }
        if( exists $p->{'selection-end'}) {
            $p->{'body-html'} =~ s/\Q$p->{'selection-end'}//g;
        }

        my $turndown = Text::HTML::Turndown->new();
        $turndown->use('Text::HTML::Turndown::GFM');
        $body = $turndown->turndown($p->{'body-html'});
    }

    $body =~ s/\A\s+//sm;
    $body =~ s/\s+\z//sm;

    $note->body($body);

    my $base = $c->url_for("/note/");
    save_note( $base, $session, $note, $fn );

    # XXX If the name has changed, we need to replace the HTMX URL!

    if( $c->is_htmx_request ) {
        # Simply update author/version on the client
        $c->stash(note => $note);
        $c->stash(oob => 1);
        $c->render('note-version')

    } else {
        $c->redirect_to($c->url_for( '/note/'. $fn ));
    }
};

sub delete_note( $c ) {
    return login_detour($c) unless $c->is_user_authenticated;

    my $session = get_session( $c );
    my $fn = $c->param('fn');
    my $note = find_note( $session, $fn );

    if( $note ) {
        # Save undo data?!
        $c->stash( undo => '/undelete/' . $note->path );
        $note->frontmatter->{deleted} = timestamp(time);
        remove_note_symlinks( $note );
        my $base = $c->url_for("/note/");
        save_note( $base, $session, $note, $fn );
        move_note( $session->document_directory . "/" . $note->path  => $session->document_directory . "/deleted/" . $note->filename );
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
        $c->stash( undo => '/unarchive/' . $note->path );
        $note->frontmatter->{archived} = timestamp(time);
        my $base = $c->url_for("/note/");
        save_note( $base, $session, $note, $fn );
        move_note( $session->document_directory . "/" . $note->path  => $session->document_directory . "/archived/" . $note->filename );
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
        $c->stash( undo => '/uncopy/' . $note->path );
        my $filename = $session->clean_filename( $fn );
        my $new_name = basename( find_name( $filename ));
        $note->frontmatter->{created} = timestamp(time);
        warn "Saving to '$new_name'";
        my $base = $c->url_for("/note/");
        save_note( $base, $session, $note, $new_name );
        return $c->redirect_to($c->url_with('/note/' . $new_name ));
    } else {
        $c->redirect_to($c->url_for('/'));
    }
}

sub remove_note_symlinks( $note ) {
    # remove all old symlinks to this note
    for my $user (keys $note->shared->%*) {
        my $info = load_account($user);
        if( $info ) {
            # User still exists, so remove the symlink to the note
            if( my $base = $info->{notes}
                and $note->shared->{ $user }) {
                my $symlink = $base . "/" . $note->shared->{ $user };
                say "Removing/recreating symlink '$symlink'";
                unlink $symlink or warn "Couldn't remove symlink '$symlink': $!";
            }
        }
    }
    $note->shared->%* = ();
    return $note;
}

# This is slightly inefficient as it recreates all symlinks on every sharing
# change
sub share_note( $c, $inline=0 ) {
    return login_detour($c) unless $c->is_user_authenticated;

    my $session = get_session( $c );
    my $fn = $c->param('fn');
    my $note = find_note( $session, $fn );

    my $user_share_fn = Mojo::File->new( $session->document_directory . "/" . $fn )->to_abs;
    if( -l $user_share_fn ) {
        # If it is a symlink, we can't share it further, or edit the sharing
        $c->redirect_to( $c->url_for('/note/') . $fn);
        return
    }

    if( $note ) {
        remove_note_symlinks( $note );

        my @shared_with = $c->every_param('share')->@*;

        # now set up the new symlinks to @shared_with
        my $abs = Mojo::File->new( $session->document_directory . "/" . $note->filename )->to_abs;
        $note->shared->%* = ();
        for my $username (@shared_with) {
            if( my $info = load_account( $username )) {
                if( $info->{notes}) {
                    my $symlink_name = find_name( $info->{notes} . "/" . $abs->basename );
                    $symlink_name = Mojo::File->new( $symlink_name )->to_abs;

                    # Update the note on disk with the new user list
                    $note->shared->{ $username } = $symlink_name->basename;

                    say "Sharing this to $username as $symlink_name";
                    symlink( $user_share_fn => $symlink_name );
                } else {
                    say "User '$username' has no notes directory configured"
                }
            } else {
                say "No user '$username' to share with?!";
            }
        }

        my $base = $c->url_for("/note/");
        save_note( $base, $session, $note, $fn );
    }

    # Display the note, at least until we know how to discriminate from where
    # the sharing UI had been invoked
    if( $inline ) {
        $c->stash( note => $note );
        $c->render('edit-share');
    } else {
        $c->redirect_to( $c->url_for('/note/') . $fn);
    }
}

post '/note/*fn' => \&save_note_body;
post '/note/' => \&save_note_body; # we make up a filename then
post '/delete/*fn' => \&delete_note;
post '/archive/*fn' => \&archive_note;
post '/copy/*fn' => \&copy_note;
post '/htmx-update-share/*fn' => sub( $c ) { share_note( $c, 0 ) };
post '/update-share/*fn' => sub( $c ) { share_note( $c, 0 ) };

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
        # We're rendering a full note here, so we need to pass through everything...
        $c->stash( field_properties => $field_properties{ 'title' } // {} );
        $c->stash( field_name => 'title' );
        $c->stash( edit_field => 'title' );
        $c->stash( note => $note );
        $c->stash( show_filter => 0 );
        display_note( $c, $note );
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

sub contrast_bw( $color ) {
    # UTI-BT.601
    my @weights = (.30,.59,.11);
    my @colors = map { hex($_) // 0 } ($color =~ /([a-f0-9]{2})/gi);
    my $luminosity = reduce { $a + $b } map { $weights[$_] * $colors[$_]} 0..2;
    my $col;
    if( $luminosity > 34 ) {
        $col = "black";
    } else {
        $col = "white";
    }
    #warn "Luminosity: $luminosity -> $col";
    return $col;
}

sub light_dark( $color ) {
    my $darkened = '#' . join '',
                 map { sprintf "%02x", $_ }
                 # maybe do weighted scaling with @weights?
                 map { int((0+$_) * 0.7) }
                 map { hex($_) } ($color =~ /([a-f0-9]{2})/gi);

    return ($color, $darkened)
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
    my $rename = ($note->title ne $title);
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
        $note->path( $final_name );
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

sub attach_file_impl( $session, $note, $file, $markdown ) {
    my $filename = "attachments/" . clean_fragment( $file->filename );
    $file->move_to($session->document_directory . "/$filename");
    $note->body( $note->body . "\n$markdown\n" );
}

sub attach_files( $session, $note, $files ) {
    for my $file ( $files->@* ) {
        my $basename = clean_fragment( $file->filename );
        attach_file_impl( $session, $note, $file,"[$basename](attachments/$basename)" );
    }
}

sub attach_file( $c ) {
    return login_detour($c) unless $c->is_user_authenticated;
    my $session = get_session( $c );
    my $note = find_note( $session, $c->param('fn') );
    my $files = $c->every_param('file');
    if( defined $files && $files->@* ) {
        attach_files( $session, $note, $files );
    } else {
        warn "No file uploaded";
    }
    $c->redirect_to($c->url_for('/note/' . $note->path ));
}

# XXX create note subdirectory
# XXX create thumbnail for image / reduce resolution/quality
# XXX convert image to jpeg in the process, or webp or whatever

sub attach_image_impl( $session, $note, $images ) {
    for my $image ($images->@*) {
        my $filename = "attachments/" . clean_fragment( $image->filename );
        # Check that we have some kind of image file according to the name
        return if $filename !~ /\.(jpg|jpeg|png|webp|dng|heic)\z/i;
        attach_file_impl( $session, $note, $image, "![$filename]($filename)");
    }
}

sub attach_image( $c ) {
    return login_detour($c) unless $c->is_user_authenticated;

    my $session = get_session( $c );
    my $note = find_note( $session, $c->param('fn') );
    my $images = $c->every_param('image');
    attach_image_impl( $session, $note, $images );
    my $base = $c->url_for("/note/");
    save_note( $base, $session, $note, $note->path );
    $c->redirect_to($c->url_for('/note/' . $note->path ));
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
    $note->save_to( $session->document_directory . "/" . $note->path );
    $c->redirect_to($c->url_for('/note/' . $note->path ));
}

sub edit_labels( $c, $inline ) {
    return login_detour($c) unless $c->is_user_authenticated;

    my $session = get_session( $c );
    my $note = find_note( $session, $c->param('fn') );
    my $filter = $c->param('label-filter');

    $c->stash( all_labels => $session->all_labels( $filter ));
    $c->stash( note => $note );
    $c->stash( label_filter => $filter );
    $c->stash( oob => $inline );

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
    my $note = find_or_create_note( $session, $fn );

    my $submitted_labels = $c->req->params->to_hash;

    my @labels = map { $submitted_labels->{$_} } grep { /^label-\d+\z/ } keys $submitted_labels->%*;

    $note->labels->assign(@labels);
    $note->save_to( $session->clean_filename( $fn ));

    $c->stash( oob => $inline );

    if( $inline ) {
        $c->stash( note => $note );
        $c->stash( all_labels => $session->all_labels );
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

    $note->add_label( $label );
    $session->labels->add( $label );
    $note->save_to( $session->clean_filename( $fn ));

    $c->stash(note => $note);
        $c->stash( oob => $inline );

    if( $inline ) {
        $c->stash( all_labels => $session->all_labels );
        $c->stash( label_filter => undef );
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
        $c->stash( note => $note );
        $c->stash( oob => 1 );
        $c->render('display-labels');

    } else {
        # Simply reload the last URL ... except that we need this to be
        # passed in by the client ...
        warn $c->htmx->req->current_url;
        $c->redirect_to( $c->htmx->req->current_url );
    }
}

sub edit_share( $c, $inline ) {
    return login_detour($c) unless $c->is_user_authenticated;

    my $session = get_session( $c );
    my $note = find_note( $session, $c->param('fn') );
    my $filter = $c->param('share-filter') // '';
    $filter =~ s![/\\]!!g;

    my %shared_with;
    my @users = get_users( $session, { user => $filter }, undef);
    $shared_with{ $_ } = 1 for (keys $note->shared->%*);
    delete $shared_with{ $session->username };

    $c->stash( shared_with => \%shared_with );
    $c->stash( all_users => \@users );
    $c->stash( note => $note );
    $c->stash( user_filter => $filter );

    if( $inline ) {
        $c->render('edit-share');

    } else {
        $c->render('filter-edit-share');
    }
}

sub link_preview( $c, $inline ) {
    return login_detour($c) unless $c->is_user_authenticated;

    my $session = get_session( $c );
    my $note = find_note( $session, $c->param('fn') );

    $c->stash( note => $note );

    my $base = $c->url_for("/note/");
    update_links( $base, $session, $note );

    if( $inline ) {
        $c->render('link-preview');

    } else {
        croak "Link preview not implemented as its own page"
    }
}

sub stash_filter( $c, $filter ) {
    my $session = get_session( $c );
    $c->stash( filter => $filter );

    # This is not really the filter anymore...
    $c->stash( all_labels => $session->labels );
    $c->stash( all_types  => [] );
    $c->stash( all_colors => [sort { fc($a) cmp fc($b) } keys $session->colors->%*] );
    $c->stash( all_created_buckets => $session->created_buckets );
}

sub select_filter( $c ) {
    return login_detour($c) unless $c->is_user_authenticated;

    my $session = get_session( $c );

    my $filter = fetch_filter($c, $session->created_buckets);
    stash_filter( $c, $filter );
    $c->stash( moniker => filter_moniker( $filter ));
    $c->render('select-filter' );
}

sub update_pinned( $c, $pinned, $inline ) {
    return login_detour($c) unless $c->is_user_authenticated;

    my $session = get_session( $c );
    my $filter = fetch_filter($c, $session->created_buckets);
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

sub generate_archive( $dir, @notes ) {
    my $base = Mojo::File->new( $dir );
    my $zip = Archive::Zip->new();
    my %seen;
    for my $note (@notes) {
        my $fn = join "/", $dir, $note->path;
        my $ar_name = $note->path;
        next if $seen{ $fn }++;
        $zip->addFile( $fn => $ar_name )
            or warn "Not a plain file: $fn";

        for my $asset ($note->assets->{files}->@*) {
            my $fn = join "/", $dir, $asset;
            my $ar_name = $asset;
            next if $seen{ $fn }++;
            $zip->addFile( $fn => $ar_name )
                or warn "Not a plain file: $fn";
        }
    }
    return $zip
}

# We also want to export the current filter as an archive
# so export_archive should take a list of documents/a filter instead of the
# implicit filter in $c.
# Also, we currently don't export the attached files/images...
sub export_archive( $c ) {
    return login_detour($c) unless $c->is_user_authenticated;

    my $session = get_session( $c );
    my $filter = fetch_filter($c, $session->created_buckets);

    my @notes = get_documents( $c, $session, $filter );

    my $base = Mojo::File->new( $session->document_directory());

    my $zip = generate_archive( $base, @notes );
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
        opendir my $dh, $user_directory
            or die "Couldn't read user directory '$user_directory': $!";
        # Search case-insensitively for the login name/file in $user_directory
        (my $fn) = grep { (fc $_) eq ((fc $u).'.yaml') } readdir $dh;
        try {
            $fn = "$user_directory/$fn";
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
    before_dispatch => sub ($c) {
        if( $ENV{ TEST_NOTES_USER }) {
            #warn app->authenticate( $ENV{ TEST_NOTES_USER }, $ENV{ TEST_NOTES_USER })
            warn "Setting current user to $ENV{ TEST_NOTES_USER }";
            $c->current_user( load_account($ENV{ TEST_NOTES_USER }));
        };
    },
);
app->hook(
    before_render => sub ($c, $args) {
        my $user = $c->is_user_authenticated ? $c->current_user : undef;
        $c->stash(user => $user);
        return $c;
    },
);

# Set our session cookie name to something app-specific, so we can host
# multiple Mojolicious apps without their cookies interfering
app->sessions->cookie_name('notekeeper-session');
# app->sessions->secure(1); # we only want this for production...

# If we are behind a reverse proxy, prepend our path
if ( my $path = $ENV{MOJO_REVERSE_PROXY} ) {
    my $path_uri = Mojo::URL->new($path);

    # Set the path for our cookie to (only) our app
    # Make it end with a slash, so that the cookie is only sent below our
    # path (despite what https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Set-Cookie
    # suggests
    $path .= "/"
       unless $path =~ m!/\z!;
    my $cookie_path = $path_uri->path;
    $cookie_path =~ s!/\z!!; # cookie path should not end with a "/"
    warn sprintf "Cookie path is [%s]", $cookie_path;
    app->sessions->cookie_path( $cookie_path );

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
            $base->port($path_uri->port);
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

    # warn $c->req->to_string;

    # Make the redirect URL relative

    my $login = $c->url_for('/login');
    warn "Detouring for login to <$login>";
    return $c->redirect_to($login);
}

get  '/edit-title' => \&edit_note_title; # empty note
get  '/edit-title/*fn' => \&edit_note_title;
get  '/htmx-edit-title' => sub( $c ) { edit_note_title( $c, 1 ) }; # empty note
get  '/htmx-edit-title/*fn' => sub( $c ) { edit_note_title( $c, 1 ) };
post '/edit-title/*fn' => \&update_note_title;
post '/edit-title' => \&update_note_title; # empty note
get  '/display-title/*fn' => \&display_note_title;
post '/upload-file/*fn' => \&attach_file;
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

get  '/htmx-share-menu/*fn' => sub( $c ) { edit_share( $c, 0 ) };
get  '/edit-share/*fn' => sub( $c ) { edit_share( $c, 0 ) };
post '/edit-share/*fn' => sub( $c ) { edit_share($c, 0 ) };
post '/htmx-edit-share/*fn' => sub( $c ) { edit_share( $c, 1 ) };

# Fragments
get  '/link-preview/*fn' => sub( $c ) { link_preview( $c, 1 ) };

post '/pin/*fn'   => sub($c) { \&update_pinned( $c, 1, 0 ) };
post '/unpin/*fn' => sub($c) { \&update_pinned( $c, 0, 0 ) };
post '/htmx-pin/*fn'   => sub($c) { \&update_pinned( $c, 1, 1 ) };
post '/htmx-unpin/*fn' => sub($c) { \&update_pinned( $c, 0, 1 ) };

get  '/export-archive' => \&export_archive;
get '/setup' => \&render_setup;
get '/pwa' => sub( $c ) {
    return login_detour($c) unless $c->is_user_authenticated;
    $c->session(expiration => 86400);
    render_notes( $c );
    $c->stash( hydrated => 0 );
    $c->render('index');
};

# Session handling
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
    return $c->redirect_to($c->url_for('/'));
};

app->helper(
    contrast_bw => sub($self,$color){ contrast_bw( $color ) },
);
app->helper(
    light_dark => sub($self,$color){ light_dark( $color ) },
);
app->helper(
    clean_fragment => sub($self,$fn){ clean_fragment($fn) },
);
app->helper(
    for_id => sub($self,$text) {
        return clean_fragment($text) =~ s/\./_/gr
    }
);

app->start;

# Make relative links actually relative to /note/ so that we can also
# properly serve attachments
sub as_html( $base, $doc, %options ) {
    my $renderer = Markdown::Perl->new(
        mode => 'github',
        disallowed_html_tags => ['script','a','object'],
    );
    my $body = $doc->body;

    # Markdown::Perl autoconverts (some) URL-like strings to links, even when
    # they are already within a linking tag.
    my $html = $renderer->convert( $body );
    if( $options{ strip_links } ) {
        $html =~ s/<a\s+href=[^>]*?>//gsi;
        $html =~ s!</a>!!gsi;
    }

    $html =~ s!<img src="\K(?=attachments/[^"]+\.(?:png|jpg|jpeg|gif)")!$base!gi;
    $html =~ s!<img src="(attachments/[^"]+\.(?:ogg|mp3|aac))"!<audio src="$base$1" controls>!g;

    # Make checkboxes clickable again
    $html =~ s!<input (checked="[^"]*" |)disabled="" type="checkbox"!<input contentEditable="false" ${1}type="checkbox"!g;

    if( my $w = $options{ search }) {
        if( my @t = $w->@* ) {
            my $t = join "|", map { quotemeta $_ } grep { length $_ } @t;
            $html =~ s!>[^<]*?\K($t)!<mark>$1</mark>!gi;
        }
    };

    return $html
}

__DATA__
@@ htmx-header.html.ep
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
<script src="<%= url_for( "/app-notekeeper.js" )%>"></script>
<script>
//htmx.logAll();

// Hack to show us what element caused the syntax error
// We still don't know what attribute, but that's close enough
htmx.on("htmx:syntax:error", (elt) => { console.log("htmx.syntax.error",elt)});
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
%=include('navbar', type => 'documents', colors => $all_colors, labels => $all_labels, show_filter => $show_filter, note => undef, editor => undef, all_users => undef, shared_with => undef, );
<div class="container-fluid" id="container">
<div class="row flex-nowrap">
    <div class="col-auto px-0">
%=include 'sidebar', labels => $all_labels, filter => $filter,
    </div>

    <main class="col">
% if( $hydrated ) {
%=include "documents", documents => $documents
% } else {
    <script>
    window.addEventListener('load', function() {
        // console.log(window.IS_STANDALONE);
        // hydrate with the documents, and bar etc.
        htmx.ajax("GET", "/documents", "main")
    });
    </script>
% }
    </main>
</div>
<div id="btn-new" class="dropup position-fixed bottom-0 end-0 rounded-circle m-5 noprint">
  <div class="btn-group">
    <div class="btn btn-success btn-lg">
        <form action="<%= url_for( "/new" ) %>" method="POST"
            enctype='multipart/form-data'
            hx-trigger="change"
            id="form-new-note"
        >
            <label for="upload-image-new">&#128247;</label>
            <input id="upload-image-new" type="file" accept="image/*"
                   name="image" id="capture-image-image"
                   style="display: none"
                   capture="environment"
            />
            <button type="submit" class="nojs">Upload</button>
        </form>
    </div>
    <a id="btn-new-note" class="btn btn-success btn-lg"
       href="<%= url_with('/new' )->query( $filter->%* ) %>"
    ><i class="fa-solid fa-plus">+</i>
    </a>
    <button type="button"
            id="btn-new-from-template"
            class="btn btn-secondary btn-lg dropdown-toggle dropdown-toggle-split hide-toggle"
            data-bs-toggle="dropdown"
            aria-expanded="false"
            aria-haspopup="true"
      ><span class="visually-hidden">New from template</span>
    </button>
    <ul class="dropdown-menu">
      <li>
          <a class="dropdown-item" href="<%= url_for("/new")->query({ label => 'Template', 'body-markdown' => "Alternatively just add the 'Template' tag to a note" }) %>">+ Create a new template</a>
      </li>
% for my $template ($templates->@*) {
%     my $title = $template->title || '(untitled)';
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
% my %section_title = (qw(pinned Pinned default Notes deleted Deleted archived Archived));
% for my $note ($documents->@*) {
%     my $section = 'default';
%     if( $note->archived ) {
%         $section = 'archived';
%     } elsif( $note->deleted ) {
%         $section = 'deleted';
%     } elsif( $note->frontmatter->{pinned} ) {
%         $section = 'pinned';
%     }
%     $sections{ $section } //= [];
%     push $sections{ $section }->@*, $note;
% };
% for my $section (qw(pinned default archived deleted)) {
%     if( $sections{ $section }) {
    <h5><%= $section_title{ $section } %></h5>
    <div class="documents grid-layout">
%         for my $note ($sections{$section}->@*) {
% my ($_bgcolor, $_bgcolor_dark) = light_dark($note->frontmatter->{color} // '#cccccc');
% my $textcolor = sprintf q{ color: light-dark(%s, %s)}, contrast_bw( $_bgcolor ), contrast_bw( $_bgcolor_dark );
% my $bgcolor   = sprintf q{ background-color: light-dark( %s, %s )}, $_bgcolor, $_bgcolor_dark ;
% my $style     = sprintf q{ style="%s; %s;"}, $bgcolor, $textcolor;
% my $id = for_id( clean_fragment($note->path) =~ s/\.markdown$//r);
<div class="grid-item note position-relative"<%== $style %>
       id="note-<%= $id %>">
    <div class="note-top-ui">
    <a href="<%= url_for( "/note/" . $note->path ) %>" class="title">
    <div class="title-text"><%= $note->title %></div>
    </a>
        <a href="<%= url_for( "/note/" . $note->path ) %>" class="pop-out"
            target="_blank"
        >pop-out</a>
%=include 'note-pinned', note => $note
    </div>
    <!-- list (some) tags -->
    <a href="<%= url_for( "/note/" . $note->path ) %>" class="title-cover">
    &nbsp;
    </a>
    <div class="content" hx-disable="true"><%== $note->{html} %></div>
    </a>
%=include 'display-labels', note => $note, oob => undef
    <div class="note-bottom-ui">
      <div class="ui-enlarge-note" onclick="javascript:toggleEnlarge('note-<%= $id %>')">&#x2921;</div>
    </div>
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
%=include('navbar', type => 'documents', colors => $all_colors, labels => $all_labels, show_filter => $show_filter, note => undef, editor => undef, all_users => undef, shared_with => undef, );
<div class="container-fluid" id="container">
<div class="row flex-nowrap">
    <div class="col-auto px-0">
%=include 'sidebar', labels => $all_labels, filter => $filter,
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
<nav class="navbar navbar-expand-lg sticky-top bd-navbar bg-body-tertiary noprint">
<div class="container-fluid d-flex">
% if( $type eq 'documents' ) {
    <div class="nav-item">
        <a href="#" data-bs-target="#sidebar" data-bs-toggle="collapse"
               class="border rounded-3 p-1 text-decoration-none"><i class="bi bi-list bi-lg py-2 p-1"></i> Labels</a>
    </div>
    <div class="nav-item"><a href="<%= url_for( "/" )%>"
% if( $show_filter ) {
    hx-trigger="click, keyup[key=='Escape'] from:body"
% }
>index</a></div>
    <div class="nav-item">
      <div id="form-filter">
% if( $show_filter ) {
%=include('select-filter', types => [], colors => $all_colors, labels => $all_labels, moniker => $moniker, all_created_buckets => $all_created_buckets)
% } else {
%# We already have a selection
      <form id="form-filter-instant-small" method="GET" action="<%= url_with( "/" )->query({ "show-filter" => 1 }) %>"
        hx-get="<%= url_for( "/" )->query( 'show-filter'=>1 ) %>"
        hx-trigger="focus delay:500ms"
        hx-target="#body"
        >
        <input id="text-filter" name="q" value="<%= $filter->{text_as_typed}//'' %>"
            placeholder="Search"
            hx-get="<%= url_with( "/" )->query( 'show-filter'=>1 )->query({ q => undef }) %>"
            hx-trigger="input changed delay:500ms, keyup changed delay:500ms"
            hx-target="#body"
            onfocus="this.select()"
%# Ideally, we don't want to swap out the above search element, because that leads to weird behaviour
%# on slow connections, but such is life ...
        />
        <a href="<%= url_with( "/" )->query({ "show-filter" => 1 }) %>">&#x1F50E;&#xFE0F;</a>
      </form>
% }
      </div>
    </div>
% } elsif( $type eq 'note' ) {
% my $id = for_id( clean_fragment($note->path) =~ s/\.markdown$//r);
    <div class="nav-item"><a href="<%= url_for( "/" )->fragment("note-$id") %>"
            hx-trigger="click, keyup[key=='Escape'] from:body"
        ><span class="rounded-circle fs-3">&#x2715;</span></a>
    </div>
%=include('editor-toolbar', editor => $editor)
    <div id="splitbar" class="nav-item flex-grow-1">&nbsp;</div>
    <div class="nav-item dropdown" id="action-share">
    <!-- pop up the sharing selector like a context menu -->
%= include 'menu-edit-share', note => $note, all_users => $all_users, shared_with => $shared_with, user_filter => ''
    </div>
% }

% if( $user ) {
    <div class="nav-item dropdown">
    <div class="btn btn-secondary dropdown-toggle dropdown-menu-end"
        data-bs-toggle="dropdown">☰</div>

    <div class="dropdown-menu dropdown-menu-end dropdown-menu-right">
    <div class="dropdown-item">
      <a href="<%= url_for('/setup') %>"
          class="btn btn-secondary" id="setup">⚙ Setup</a>
    </div>
% if( $type eq 'note' ) {
    <div class="dropdown-item" id="action-copy">
        <form action="<%= url_for('/copy/' . $note->path ) %>" method="POST"
        ><button class="btn btn-secondary" type="submit">&#xFE0E;⎘ Copy note</button>
        </form>
    </div>
% }

    <div class="dropdown-item">
      <a id="btn-export"
        hx-boost="false"
        href="<%= url_with('/export-archive')%>"
        class="btn btn-secondary" id="export">Export selected notes</a>
    </div>
    <div class="dropdown-item">
    <a class="nav-link" href="https://github.com/Corion/App-notes-htmx" target="_blank">Github</a>
    </div>
    <div class="dropdown-item">
      <form id="form-logout" method="POST" action="<%= url_for( "/logout" ) %>">
      <button name="logout"
          class="btn btn-secondary" id="logout">Log '<%= $user->{user} %>' out</button>
      </form>
    </div>
    </div>
    </div>
% }
</div>
</nav>

@@ label-hierarchy-level.html.ep
%# Fold out details if they are a leftmost substring of $current
% my $current_class = $current eq $label->text ? 'sidebar-current' : '';
% my $color = $label->color;
% $color = (!$current_class and $color) ? sprintf 'style="background: %s;"', $color : '';
% if( !$label->details->@* ) {
    <a href="<%= url_with()->query({ "no-label" => undef, label => $label->text, sidebar => 1 }) %>"
       class="list-group-item border-end-0 d-inline-block <%= $current_class %>"
       data-bs-parent="#sidebar"
       <%== $color ? $color : '' %>
    ><%= $label->visual %> &#x1F3F7;</a><br/>
% } else {
% my $open =    $current eq $label->text
%            || index( $current, $label->visual . "/" ) == 0;
% $open = $open ? " open " : "";
    <details class="sidebar-details border-end-0 list-group-item" <%= $open %>>
    <summary><a href="<%= url_with()->query({ "no-label" => undef, label => $label->text, sidebar => 1 }) %>"
       class="<%= $current_class %>"
       data-bs-parent="#sidebar"
       <%== $color ? $color : '' %>
    ><%= $label->visual %> &#x1F3F7;</a>
    </summary>
    <div class="sidebar-details-sublabel">
%     for my $c ($label->details->@* ) {
%=include( "label-hierarchy-level", label => $c, current => $current )
%     }
    </div></details>
% }

@@sidebar.html.ep
<div id="sidebar" class="collapse collapse-horizontal border-end <%= $sidebar ? 'show' : '' %> sticky-top">
    <div id="sidebar-nav" class="list-group border-0 rounded-0 text-sm-start"
    >
% my $current = ($filter->{label} // [])->[0] // '';
    <a href="<%= url_with()->query({ "no-label" => undef, label => undef, sidebar => 1 }) %>"
       class="list-group-item border-end-0 d-inline-block"
       data-bs-parent="#sidebar"
    >All notes</a>
    <a href="<%= url_with()->query({ "no-label" => 1, label => undef, sidebar => 1 }) %>"
       class="list-group-item border-end-0 d-inline-block"
       data-bs-parent="#sidebar"
    ><i>No label</i></a>
% for my $key (sort { fc($label_hierarchy->{$a}->text) cmp fc($label_hierarchy->{$b}->text) } keys $label_hierarchy->%*) {
%= include( "label-hierarchy-level", label => $label_hierarchy->{ $key }, current => $current );
% }
    </div>
</div>

@@note-pinned.html.ep
    <div class="pin-location">
% if( $note->frontmatter->{pinned} ) {
    <form method="POST" action="<%= url_with('/unpin/'.$note->path) %>"
        hx-post="<%= url_with('/htmx-unpin/'.$note->path) %>"
        hx-target="#documents"
        hx-swap="outerHTML transition:true"
    ><button type="submit" class="pinned"><bold><%= "\N{PUSHPIN}" %></bold></button></form>
% } else {
    <form method="POST" action="<%= url_with('/pin/'.$note->path) %>"
        hx-post="<%= url_with('/htmx-pin/'.$note->path) %>"
        hx-target="#documents"
        hx-swap="outerHTML transition:true"
    ><button type="submit" class="unpinned"><%= "\N{PUSHPIN}" %>&#xfe0e;</button></form>
% }
    </div>

@@ note-version.html.ep
<input id="note-version" type="hidden" name="version" value="<%= $note->frontmatter->{version} %>"
% if( $oob ) {
    hx-swap-oob="true"
% }
/>
<input id="note-author" type="hidden" name="author" value="<%= $note->frontmatter->{author} %>"
% if( $oob ) {
    hx-swap-oob="true"
% }
/>
% if( $oob ) {
<div id="edited-date" hx-swap-oob="true"><%= $note->frontmatter->{updated} %></div>
% }

@@link-preview.html.ep
% my @links = $note->links->@*;
% if( my @pending = grep { ($_->{status} //'' ) ne 'done' } @links ) { # we still want to poll
<div id="link-preview" hx-get="<%= url_for( "/link-preview/" ) . $note->path %>"
    hx-trigger="load delay:1s"
    hx-swap="outerHTML">
% } else {
<div id="link-preview">
% }
% for my $l (@links) {
    % if( ($l->{status} //'') eq 'done' ) {
<%== $l->{preview} // '' %>
    % } else {
        <div class="link-preview">
        <!-- This should be a 'domain'-style link-->
<%= $l->{url} %>
        </div>
    % }
% }
% for my $l ($note->assets->{files}->@*) {
Asset: <%= $l %><br />
% }
</div>

@@ dropdown-assign-template.html.ep
<div class="dropup">
    <button type="button"
        id="btn-assign-template-dropup"
        class="btn btn-secondary dropdown-toggle dropdown-toggle-split hide-toggle"
        data-bs-toggle="dropdown"
        aria-expanded="false"
        aria-haspopup="true"
      ><span>Template</span>
    </button>
    <ul class="dropdown-menu">
% for my $template ($templates->@*) {
%     my $title = $template->title || '(untitled)';
      <li>
        <a class="dropdown-item"
            href="<%= url_with( '/assign-template/'.$note->path )->query( template => $template->filename ) %>"
        ><%= $title %></a>
      </li>
% }
    </ul>
</div>

@@ note.html.ep
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
%=include 'htmx-header'

% my $title = $note->title // '';
% $title = 'untitled' if length $title == 0;
<title><%= $title %> - notekeeper</title>
</head>
<body
    hx-boost="true"
    id="body"
    hx-ext="morphdom-swap"
    hx-swap="morphdom"
>
%=include('navbar', type => 'note', show_filter => $show_filter );

<main id="note-container" class="container-flex">
% my ($_bgcolor, $_bgcolor_dark) = light_dark($note->frontmatter->{color}  // '#cccccc');
% my $textcolor = sprintf q{ color: light-dark(%s, %s)}, contrast_bw( $_bgcolor ), contrast_bw( $_bgcolor_dark );
% my $bgcolor   = sprintf q{ background-color: light-dark( %s, %s )}, $_bgcolor, $_bgcolor_dark ;
% my $style     = sprintf q{ style="%s; %s;"}, $bgcolor, $textcolor;
%=include 'display-labels', note => $note, oob => undef
<div class="single-note"<%== $style %>>
% my $doc_url = '/note/' . $note->path;
% if( $edit_field and $edit_field eq 'title' ) {
%=include "edit-text", field_name => 'title', value => $note->title, class => 'title', field_properties => $field_properties->{title},
% } else {
%=include "display-text", field_name => 'title', value => $note->title, class => 'title', reload => 1
% }
<form action="<%= url_for( $doc_url ) %>" method="POST"
    hx-trigger="input from:#note_html delay:200ms, keyup from:#note-textarea delay:200ms changed"
    hx-vals='js:{...getUserContent()}'
    hx-swap="none"
>
%=include "note-version", note => $note, oob => undef
<button class="nojs" name="save" type="submit">Save</button>
<div class="note-container">
% if( $editor eq 'markdown' ) {
<textarea name="body-markdown" id="note-textarea" autofocus
    data-selection-start="<%= $selection_start %>"
    data-selection-end="<%= $selection_end %>"
    style="color: inherit; background-color: inherit;"
><%= $note->body %></textarea>
% } elsif( $editor eq 'html' ) {
%# This can only work with JS enabled; well, the saving
<div id="note_html"><!-- This is untrusted content, so tell HTMX that -->
    <div id="usercontent" autofocus
        hx-disable="true"
        onclick="javascript:updateToolbar()"
        onkeyup="javascript:updateToolbar()"
        contentEditable="true"><%== $note_html %></div>
</div>
% }
%=include("link-preview", note => $note);
</div>
</form>
    <div id="edited-date" class="edited-date"><%= $note->frontmatter->{updated} %></div>
</div>
</main>
<div id="actionbar" class="navbar bg-body-tertiary mt-auto fixed-bottom noprint">
    <div id="action-attach-image">
        <form action="<%= url_for( "/upload-image/" . $note->path ) %>" method="POST"
            enctype='multipart/form-data'
            hx-trigger="change"
        >
            <label for="upload-image">&#128247;</label>
            <input id="upload-image" type="file" accept="image/*"
                   name="image" id="capture-image-image"
                   style="display: none"
                   capture="environment"
                   multiple
            />
            <button type="submit" class="nojs">Upload</button>
        </form>
    </div>
    <div id="action-attach-file">
        <form action="<%= url_for( "/upload-file/" . $note->path ) %>" method="POST"
             hx-post="<%= url_for( "/upload-file/" . $note->path ) %>"
             enctype='multipart/form-data'
          hx-trigger="change"
         hx-encoding="multipart/form-data"
         hx-target="body"
         id="form-attach-file"
        >
            <label for="upload-file">&#x1F4CE;</label>
            <input id="upload-file" type="file" accept="*/*"
                   name="file" id="attach-file-file"
                   style="display: none"
                   multiple
            />
            <button type="submit" class="nojs">Upload</button>
        </form>
    </div>
    <div id="action-attach-audio">
%=include('attach-audio', note => $note, field_name => 'audio' );
    </div>
    <div id="action-labels">
%= include 'menu-edit-labels', note => $note, all_labels => $all_labels, label_filter => ''
    </div>
    <div id="action-copy">
        <form action="<%= url_for('/copy/' . $note->path ) %>" method="POST"
        ><button class="btn btn-secondary" type="submit">&#xFE0E;⎘</button>
        </form>
    </div>
    <div id="action-template">
%= include 'dropdown-assign-template', note => $note, templates => $templates
    </div>
    <div id="action-archive">
        <form action="<%= url_for('/archive/' . $note->path ) %>" method="POST"
        ><button class="btn btn-secondary" type="submit">&#xFE0E;&#x1f5c3;</button>
        </form>
    </div>
    <div id="action-delete">
        <form action="<%= url_for('/delete/' . $note->path ) %>" method="POST"
        ><button class="btn btn-secondary" type="submit">&#xFE0E;&#x1F5D1;</button>
        </form>
    </div>
</div>
</body>
</html>

@@html-actions.html.ep
<div class="nav-item">
<div id="toolbar">
      <button onclick="changeBlock('h1')">XL</button>
      <button onclick="changeBlock('h2')">L</button>
      <button onclick="changeBlock('p')">M</button>
      <!--
      <button onclick="changeBlock('small')">S</button>
      -->
      <button id="btn-CODE" onclick="toggleFormat('code')"><code>C</code></button>
      <button id="btn-STRONG" onclick="toggleFormat('strong')"><b>B</b></button>
      <button id="btn-EM" onclick="toggleFormat('em')"><i>I</i></button>
      <button onclick="applyURL()">🔗</button>
      </div>
</div>

@@edit-actions.html.ep
    <div id="action-color" class="nav-item">
%=include('edit-color', value => $note->frontmatter->{color}, field_name => 'color');
    </div>

@@editor-toolbar.html.ep
% my $active = $editor eq 'markdown' ? ' btn-primary' : '';
    <div class="nav-item jsonly">
    <a id="btn-switch-editor-md" class="btn <%= $active %>"
       href="<%= url_for()->query({ editor => 'markdown' }) %>"
       hx-vals='js:{...getUserCaret()}'
    >MD</a></div>
%    $active = $editor eq 'html' ? ' btn-primary' : '';
    <div class="nav-item jsonly"><a id="btn-switch-editor-html" class="btn <%= $active %>" href="<%= url_for()->query({ editor => 'html' }) %>">HTML</a></div>
%= include('edit-actions')
% if( $editor eq 'html' ) {
      <!-- <div id="splitbar-html">|</div> -->
%= include('html-actions')
% }

@@ login.html.ep
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
  <main class="container" id="container" hx-history-elt>
      <h1>Log into notekeeper</h1>
      <form action="<%= url_for( '/login' )%>" method="POST">
        <div class="form mb-3">
            <label for="username" class="form-label">Username</label>
            <input class="form-control" type="text" autofocus autocomplete="username" name="username" value="" text="Username" id="username" required />
        </div>
        <div class="mb-3">
            <label class="form-label" for="password" class="form-label">Password</label>
            <input class="form-control" type="password" autocomplete="password" name="password" value="" text="Password" id="login-password"/>
        </div>
        <button class="btn btn-primary btn-lg" type="submit">Log in</button>
      </form>
  </main>
</body>
</html>

@@display-text.html.ep
<div id="note-<%= $field_name %>" class="<%= $class %>">
% if( defined $value && $value ne '' ) {
    <a href="<%= url_for( "/edit-$field_name/" . $note->path ) %>"
    hx-get="<%= url_for( "/htmx-edit-$field_name/" . $note->path ) %>"
    hx-target="closest div"
    hx-swap="innerHTML"
    >
    <%= $value %>
    &#x270E;</a>
% } else {
    <a class="editable"
       href="<%= url_for( "/edit-$field_name/" . $note->path ) %>"
%#     if( !$reload ) {
       hx-get="<%= url_for( "/htmx-edit-$field_name/" . $note->path ) %>"
       hx-target="closest div"
       hx-swap="innerHTML"
%#     }
    ><%= $field_name %></a>
% }
</div>

@@edit-text.html.ep
<form id="edit-text-<%= $field_name %>" action="<%= url_for( "/edit-$field_name/" . $note->path ) %>" method="POST"
% if( $field_properties->{ reload } ) {
    hx-trigger="blur from:#note-input-text-<%= $field_name %> changed"
% } else {
    hx-swap="outerHTML"
% }
>
    <input type="text" name="<%= $field_name %>" id="note-input-text-<%= $field_name %>" value="<%= $value %>"
        autofocus
        onfocus="this.select()"
    />
    <button type="submit" class="nojs">Save</button>
</form>

@@attach-audio.html.ep
<div id="audio-recorder" >
    <button class="btn btn-primary" id="button-record" onclick="startRecording()">&#x1F399;</button>
    <form action="<%= url_with( "/upload-audio/" . $note->path ) %>"
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
<form action="<%= url_for( "/edit-color/" . $note->path ) %>" method="POST"
    id="form-edit-color"
    hx-disinherit="*"
    hx-trigger="change"
>
  <input type="color" list="presetColors" value="<%= $value %>" name="color" id="edit-<%= $field_name %>"
  >
  <datalist id="presetColors">
    <option>#ff0000</option>
    <option>#00ff00</option>
    <option>#0000ff</option>
  </datalist>
  <button type="submit" class="nojs">Set</button>
</form>

@@ label-pill.html.ep
% my $class = $active ? 'text-secondary-emphasis bg-secondary' : 'text-secondary bg-secondary-subtle';
<div class="label badge rounded-pill <%= $class %>" ><%= $label %></div>

@@display-labels.html.ep
% my $labels = $note->labels;
% my $id = 'labels-'. $note->filename;
% $id =~ s![.]!_!g;
    <div class="labels"
        id="<%= $id %>"
% if( $oob ) {
        hx-swap-oob="true"
% } else {
        hx-target="this"
        hx-swap="outerHTML"
% }
    >
%     for my $label ($labels->labels->@*) {
    <div class="label badge rounded-pill bg-secondary" ><%= $label %>
%# Yeah, this should be a FORM, but I can't get it to play nice with Bootstrap
    <a class="delete-label"
        href="<%= url_with('/delete-label/' . $note->path)->query(delete=> $label) %>"
        hx-get="<%= url_with('/htmx-delete-label/' . $note->path)->query(delete=> $label) %>"
    >
        &#10006;
    </a>
    </div>
% }
    </div>

@@menu-edit-labels.html.ep
<div class="dropup" id="dropdown-labels" hx-trigger="show.bs.dropdown"
  hx-get="<%= url_with( '/htmx-label-menu/' . $note->path ) %>"
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
%=include 'filter-edit-labels', note => $note, label_filter => $label_filter
    </div>
</div>

@@filter-edit-labels.html.ep
% my $url = url_for( "/edit-labels/" . $note->path );
% my $htmx_url = url_for( "/htmx-edit-labels/" . $note->path );
<div id="menu-container">
<div class="dropdown-item">Label note</div>
<form action="<%= $url %>" method="GET" id="label-filter-form"
 class="form-inline dropdown-item"
 hx-target="#label-edit-list"
 hx-swap="outerHTML"
 hx-get="<%= $htmx_url %>"
>
    <div class="form-group">
        <div class="input-group input-group-unstyled has-feedback inner-addon right-addon">
        <i class="glyphicon glyphicon-search form-control-feedback input-group-addon"
            hx-get="<%= url_for( '/htmx-label-menu/' . $note->path )->query({ label_filter => undef }) %>"
            hx-target="#menu-container"
        >x</i>
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
%=include 'edit-labels', note => $note, new_name => $label_filter, all_labels => $all_labels
</div>

@@edit-labels.html.ep
<div id="label-edit-list">
<form action="<%= url_for( "/update-labels/" . $note->path ) %>" method="POST"
  id="label-set-list"
>
  <button class="nojs btn btn-default" type="submit">Set</button>
%=include 'display-create-label', prev_label => '', new_name => $label_filter
% my $idx=1;
% my $labels = $note->labels;
% my %is_set = $labels->as_set->%*;
% for my $label ($all_labels->labels->@*) {
%   my $name = "label-" . $idx++;
    <span class="edit-label dropdown-item">
    <input type="checkbox" name="<%= $name %>"
           id="<%= $name %>"
           value="<%= $label %>"
           hx-post="<%= url_with( '/htmx-update-labels/' . $note->path ) %>"
           hx-trigger="change"
           hx-swap="none"
           hx-target="this"
           <%== exists $is_set{ fc($label) } ? 'checked' : ''%>
    />
    <label for="<%= $name %>" style="width: 100%"><%= $label %> &#x1F3F7;</label>
    </span>
%   $idx++;
%   delete $is_set{ fc($label) }; # so we know that we don't need to keep this value
% }
%# Keep all the labels that are not visible as unchanged:
% for my $label (keys %is_set) {
%   my $name = "label-" . $idx++;
    <input type="hidden" name="<%= $name %>"
           id="<%= $name %>"
           value="<%= $is_set{ fc($label) } %>"
    />
% }
</form>
</div>
%=include( 'display-labels', note => $note, oob => 1 )

@@display-create-label.html.ep
%# This needs a rework with the above
  <!-- Here, we also need a non-JS solution ... -->
% if( defined $new_name and length($new_name)) {
%    my $url = url_for("/add-label/" . $note->path )->query( "new-label" => $new_name );
<a id="create-label" href="<%= $url %>"
   hx-post="<%= url_for("/htmx-add-label/" . $note->path )->query( "new-label" => $new_name ); %>"
   hx-swap="outerHTML"
>+ Create '<%= $new_name %>'</a>
% }

@@create-label.html.ep
<form id="create-label" action="<%= url_for( "/add-label/" . $note->path ) %>" method="POST"
    hx-post="<%= url_for( "/add-label/" . $note->path ) %>"
    hx-swap="outerHTML"
>
  <button type="submit">Set</button>
    <span class="label">
    <input type="checkbox" name="really" id="really" checked />
    <input type="text" name="new-label" id="new-label" value="" placeholder="New label" autofocus />
    </span>
</form>

@@menu-edit-share.html.ep
<div id="dropdown-share" hx-trigger="show.bs.dropdown"
  hx-get="<%= url_with( '/htmx-share-menu/' . $note->path ) %>"
  hx-target="find .dropdown-menu"
  hx-disinherit="hx-target"
  >
    <button type="button" class="btn btn-secondary dropdown dropdown-toggle hide-toggle"
            data-bs-toggle="dropdown"
            aria-expanded="false"
            aria-haspopup="true"
            data-bs-auto-close="outside"
      ><div class="svg_icon">
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1000 1000" style="fill:#0273a2"><title>Share</title><path d="M163.1,314c84.5,0,153.1,68.5,153.1,153.1c0,84.5-68.5,153.1-153.1,153.1C78.5,620.1,10,551.6,10,467C10,382.5,78.5,314,163.1,314z"></path><path d="M835,7.8c84.5,0,153.1,68.5,153.1,153.1c0,84.5-68.6,153.1-153.1,153.1c-84.5,0-153-68.5-153-153.1C682,76.4,750.5,7.8,835,7.8z"></path><path d="M836.9,686c84.5,0,153.1,68.5,153.1,153.1s-68.6,153.1-153.1,153.1c-84.5,0-153-68.5-153-153.1C683.9,754.5,752.4,686,836.9,686z"></path><path d="M165.3,504l-31.2-69.3l707.2-318l31.1,69.3L165.3,504z"></path><path d="M119.5,488.4l36.8-66.4l733.2,405.8l-36.8,66.4L119.5,488.4z"></path>
            </svg>
        </div>
    </button>

    <div class="dropdown-menu">
%=include 'filter-edit-share', note => $note, all_users => $all_users, user_filter => $user_filter, shared_with => $shared_with
    </div>
</div>

@@filter-edit-share.html.ep
% my $url = url_for( "/update-share/" . $note->path );
% my $htmx_url = url_for( "/htmx-update-share/" . $note->path );
<div class="dropdown-item">Share note with</div>
%=include 'edit-share-filterbox', url => $url, htmx_url => $htmx_url, note => $note, all_users => $all_users, user_filter => $user_filter, shared_with => $shared_with
%=include 'edit-share', note => $note, all_users => $all_users, user_filter => $user_filter, shared_with => $shared_with

@@edit-share-filterbox.html.ep
<form action="<%= $url %>" method="POST" id="share-filter-form"
 class="form-inline dropdown-item"
 hx-target="#share-edit-list"
 hx-swap="outerHTML"
 hx-post="<%= $htmx_url %>"
>
    <div class="form-group">
        <div class="input-group input-group-unstyled has-feedback inner-addon right-addon">
        <i class="glyphicon glyphicon-search form-control-feedback input-group-addon">x</i>
        <input name="share-filter" type="text" class="form-control"
            style="width: 30%;"
            placeholder="User name"
            autofocus="true"
            value="<%= $user_filter %>"
            id="share-filter"
            hx-post="<%= $htmx_url %>"
            hx-trigger="input delay:200ms changed, keyup[key=='Enter']"
        >
        </div>
        <button class="nojs btn btn-default">Filter</button>
    </div>
</form>

@@edit-share.html.ep
<div id="share-edit-list">
<form action="<%= url_for( "/update-share/" . $note->path ) %>" method="POST"
  id="share-edit-list"
>
  <button class="nojs btn btn-default" type="submit">Share</button>
% my $idx = 1;
% for my $user (sort {
%                        ($shared_with->{$b->{user}} // 0) <=> ($shared_with->{$a->{user}} // 0)
%                    ||  fc($a->{name}) cmp fc($b->{name})
%                    } ($all_users->@*)) {
%   my $name = "user-" . $idx++;
    <span class="edit-label dropdown-item">
    <input type="checkbox" name="share"
           id="<%= $name %>"
           value="<%= $user->{user} %>"
           hx-post="<%= url_with( '/htmx-update-share/' . $note->path ) %>"
           hx-trigger="change"
           hx-swap="none"
           hx-target="this"
           <%== $shared_with->{$user->{user}} ? 'checked' : ''%>
    />
    <label for="<%= $name %>" style="width: 100%"><%= $user->{name} %></label>
    </span>
%   $idx++;
% }
</form>
</div>

@@select-filter.html.ep
<div id="form-filter-2">
      <form id="form-filter-instant" method="GET" action="<%= url_for( "/" ) %>"
            hx-target="#body"
            hx-trigger="change delay:200ms changed, input from:input delay:200ms changed, keyup[key=='Enter']"
      >
      <input type="hidden" name="show-filter" value="1" />
        <div class="input-group">
        <input id="text-filter" name="q" value="<%= $filter->{text_as_typed}//'' %>"
% my $vis = $moniker ? "in $moniker" : "Search";
            placeholder="<%== $vis %>"
        />
        <span class="input-group-append">
% if ( keys $filter->%* ) {
            <a class="btn btn-white border-start-0 border" type="button"
            href="<%= url_for('/')->query('show-filter'=>1)->query({ q => undef }) %>"
            hx-disinherit="*"
            hx-target="#body"
            >x</a>
% }
        </span>
        </div>
<!-- (note) types (images, lists, ...) -->
% if( $types->@* ) {
<div>
<h2>Types</h2>
%    for my $t ($types->@*) {
    <a href="<%= url_with('/')->query({ type => $t }) %>"
       hx-disinherit="*"
       hx-target="#body"
       hx-get="<%= url_with('/')->query({ type => $t }) %>"
    ><%= $t %></a>
%    }
</div>
%}
% if( $labels->labels->@* ) {
<div class="filter-label">
<h2>Labels</h2>
    <label for="checkbox-no-label">
    % my $class = $filter->{unlabeled} ? 'text-secondary-emphasis bg-secondary' : 'text-secondary bg-secondary-subtle';
    <div class="label badge rounded-pill <%= $class %>" ><i>No label</i></div>
    <input id="checkbox-no-label" type="checkbox" name="no-label" value="1" <%== $filter->{unlabeled} ? 'checked' : "" %> style="display:none"/>
    </label>
%    my %active = map { $_ => 1 } ($filter->{label} // [])->@*;
%    for my $l ($labels->labels->@*) {
%        my $id = "label-".for_id($l);
    <label for="<%= $id %>"><%= include( 'label-pill', label => $l, active => $active{ $l } ) %>
    <input type="checkbox" name="label" value="<%= $l %>" id="<%= $id %>" <%== $active{$l} ? 'checked' : "" %> style="display:none"/>
    </label>
%    }
</div>
%}
<!-- things -->
% if( $all_colors->@* ) {
<div class="filter-color">
<h2>Colors</h2>
%    my %active = map { $_ => 1 } ($filter->{color} // [])->@*;
%    for my $l ($all_colors->@*) {
%        my $id = "color-".for_id($l);
%        my $active = $active{ $l } ? "border: black solid 2px;" : "border: transparent solid 2px;";
    <label for="<%= $id %>" id="label-<%=$id%>" class="color-circle" style="background-color:<%== $l %>;<%= $active %>">&nbsp;</label>
    <input type="checkbox" name="color" value="<%= $l %>" id="<%= $id %>" <%== $active{$l} ? 'checked' : "" %> style="display:none"/>
%    }
</div>
%}
<!-- date created -->
% if( $all_created_buckets->@* ) {
<div>
<h2>Created</h2>
%    my %active = map {$_->{vis} => 1 } ($filter->{created} // [])->@*;
%    for my $t ( $all_created_buckets->@* ) {
%        my $val = "$t->{vis}";
%        my $id = "date-".for_id($val);
%        my $active = $active{ $val } ? "border: black solid 2px;" : "border: transparent solid 2px;";
    <label for="<%= $id %>" id="date-<%=$id%>" style="<%= $active %>"><%= $t->{vis} %></label>
    <input type="checkbox" name="created-range" value="<%= $val %>" id="<%= $id %>" <%== $active{$val} ? 'checked' : "" %> style="display:none"/>
%    }
</div>
% }
<div>
<h2>Also search</h2>
% my $include = $filter->{include} // [];
% my $deleted = grep { $_ eq 'deleted' } $include->@*;
% my $archived = grep { $_ eq 'archived' } $include->@*;
<label class="form-check-label" for="archived">Archived notes</label>
<input class="form-check-input" type="checkbox" name="folder" value="archived" id="archived" <%= $archived ? 'checked' : '' %>
    hx-trigger="change"
/>
<label  class="form-check-label" for="deleted">Deleted notes</label>
<input  class="form-check-input" type="checkbox" name="folder" value="deleted" id="deleted" <%= $deleted ? 'checked' : '' %>
    hx-trigger="change"
/>
</div>
      </form>
</div>

@@pwa.html.ep
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <title>Home (PWA)</title>
%=include('htmx-header');
    <script type="text/javascript" src="app.js"></script>
    <script>
    // test standalone mode
    window.addEventListener('load', function() {
        console.log(window.IS_STANDALONE);
        // hydrate with the documents, and bar etc.
        htmx.ajax("GET", "/", "body")
    });
    </script>
    <meta name="viewport" content="width=device-width,initial-scale=1">

    <!-- theme browser bar -->
    <meta name="theme-color" content="#000000">

    <!-- don't forget a manifest ! -->
    <link rel="manifest" href="manifest.json">

    <!-- apple touch icon ! -->
    <link rel="apple-touch-icon" href="/example.png">
</head>
<body>
</body>
</html>
