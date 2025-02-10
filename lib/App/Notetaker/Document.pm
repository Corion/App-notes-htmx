package App::Notetaker::Document 0.01;
use 5.020;
use experimental 'signatures';
use Moo;
use Mojo::File;

has 'frontmatter' => (
    is => 'lazy',
    default => sub($args) {
        my $tfm = Text::FrontMatter::YAML->new(
            document_string => $args->{body},
        );
        $tfm->frontmatter_hashref // {},
    }
);

has 'body' => (
    is => 'rw'
);

has 'filename' => (
    is => 'rw',
);

=head2 C<< ->shared >>

  $note->shared->{ $user } = $target_lint;

For each user that this note has been shared with, the name of the symlink
that this note is shared under.

Later, once we move this to a database, this will likely change to an entry
in a table of shared notes, but for now, this keeps the names of symlinks
and the name of the symlink target (this note) together.

=cut

sub shared( $self ) {
    return $self->frontmatter->{shared} //= {}
}

sub from_file( $class, $fn ) {
    my $f = Mojo::File->new($fn);
    my $body = $f->slurp('UTF-8');
    my $tfm = Text::FrontMatter::YAML->new(
        document_string => $body,
    );

    $class->new( {
        (filename => $f->basename),
        (frontmatter => $tfm->frontmatter_hashref // {}),
        (body => $tfm->data_text),
    } );
}

sub save_to( $self, $fn ) {
    my $f = Mojo::File->new($fn);
    my $tfm = Text::FrontMatter::YAML->new(
        data_text => $self->body,
        frontmatter_hashref => $self->frontmatter,
    );

    # Clean up empty shared entries:
    if( my $s = $self->frontmatter->{ shared }) {
        delete $self->frontmatter->{shared}
            if ! $s->%*;
    }

    $f->spew( $tfm->document_string, 'UTF-8' );
}

sub add_label( $self, @labels ) {
    $self->update_labels( 1, \@labels );
}

sub remove_label( $self, @labels ) {
    $self->update_labels( undef, \@labels );
}

sub update_labels( $self, $add, $labels ) {
    my $l = $self->frontmatter->{labels} // [];
    my %labels;
    @labels{ $l->@* } = (1) x $l->@*;
    if( $add ) {
        @labels{ $labels->@* } = (1) x $labels->@*;
    } else {
        delete @labels{ $labels->@* }
    }
    $self->frontmatter->{labels}->@* = sort { fc($a) cmp fc($b) } keys %labels;
}

1;
