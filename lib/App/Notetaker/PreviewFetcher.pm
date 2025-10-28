package App::Notetaker::PreviewFetcher 0.01;
use 5.020;
use experimental 'signatures';
use Moo 2;
use Mojo::UserAgent::Paranoid;
use Future;
use Crypt::Digest::SHA256 'sha256_b64u';

with 'MooX::Role::EventEmitter';

# Should we maybe emit events whenever a preview is
# * Initialized
# * Has found a renderer
# * Is ready
# ?

=head1 SYNOPSIS

  my @previewers = (qw(
      Link::Preview::SiteInfo::YouTube
      Link::Preview::SiteInfo::OpenGraph
  ));
  my $fetcher = App::Notetaker::PreviewFetcher->new(
      previewers => \@previewers,
  );
  my $link_preview = $fetcher->fetch_previews( [ 'https://example.com' ] );



=head1 METHODS

=head2 C<< ->new >>

=cut

has 'ua' => (
    is => 'lazy',
    default => sub { Mojo::UserAgent::Paranoid->new() },
);

has 'done' => (
    is => 'lazy',
    default => sub { {} },
);

has 'pending' => (
    is => 'lazy',
    default => sub { {} },
);

has 'previewers' => (
    is => 'lazy',
    default => sub { [] },
);

sub fetch_preview_set( $self, $prereq_set, $exclude = {} ) {
    my $have = join "\0", sort { $a cmp $b } grep { $prereq_set->{$_} } keys $prereq_set->%*;
    my @res;
    for my $p (grep { ! $exclude->{ $_ }} $self->previewers->@*) {
        my $need = join "\0", sort { $a cmp $b } keys $p->prerequisites->%*;
        if( $need eq $have ) {
            push @res, $p;
        }
    }
    return @res
}

sub fetch_preview( $self, $ua, $url, $html=undef ) {
    warn "Fetching preview for <$url>";
    my $done = $self->done;
    my $pending = $self->pending;
    if( $done->{ $url }) {
        warn "already done: $url";
        return $done->{ $url }
    }
    if( $pending->{ $url }) {
        warn "already pending: $url";
        return $pending->{ $url }
    }

    # First, check with URL only, then (optionally) fetch HTML and check with
    # that, if we have no candidate that works without fetching the HTML
    my %prereqs = (
        url => $url,
        html => $html,
    );

    my $launched;

    my %already_checked;
    my @most_fitting = grep {
        $_->applies( \%prereqs ) or $already_checked{ $_ }++;
    } $self->fetch_preview_set( \%prereqs, \%already_checked );

    # Maybe push fetching the HTML one level upwards instead?!
    # but that implies that the logic also has to live upwards?!
    # What is then the result/aim of this subroutine at all?
    if( ! @most_fitting and ! $html ) {
        my $u = $url;
        # For development, we should cache this a lot!
        $ua->get_p( $u )->then(sub( $tx ) {
            my $res = $tx->res;
            my $html = $tx->res->body;
            $prereqs{ html } = $html;

            @most_fitting = grep {
                $_->applies( \%prereqs );
            } $self->fetch_preview_set( \%prereqs, \%already_checked );
            if( $most_fitting[0] ) {
                $pending->{ $url }->{preview} = $most_fitting[0]->generate(\%prereqs);
            }
            $done->{ $url } = delete $pending->{ $url };
            $done->{ $url }->{status} = 'done';
            $self->emit(done => $done->{$url});
        })
        ->catch(sub( $err ) {
            #warn "** $u: $err";
            $done->{ $url } = delete $pending->{ $url };
            $done->{ $url }->{status} = "error: $err";
            $self->emit(error => $done->{ $url }, $err);
        });

        $launched = $pending->{ $url } = {
            url => $url,
            status => 'pending',
            preview => undef,
            id => sha256_b64u( $url ),
        };
        $self->emit(pending => $launched);
    }
    if( $launched ) {
        warn "Launched a request";
        return $launched
    } elsif( @most_fitting ) {
        warn "Generating preview via $most_fitting[0]";
        my $res = { preview => $most_fitting[0]->generate( \%prereqs ), status => 'done' };
        $self->emit( done => $res );
        return $res;
    } else {
        warn "No previewer found for '$url'";
        return undef
    }
}

# Adds a list of links to the previews to be fetched
sub fetch_previews( $self, $links, $ua = $self->ua ) {
    $ua->max_redirects(10);

    my %seen;

    my @res = map { $seen{$_}++
                    ? ()
                    : +{ url => $_, $self->fetch_preview( $ua, $_ )->%* } } $links->@*;

    return \@res
}


=head1 EVENTS

The following events are emitted:

=over 4

=item C<done> - when fetching a preview is complete

=item C<error> - in case an error happens when fetching

=item C<pending> - when an item is in progress

=cut

1;
