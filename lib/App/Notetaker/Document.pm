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

has 'path' => (
    is => 'rw',
);

has 'filename' => (
    is => 'rw',
);

has 'labels' => (
    is => 'ro',
);

sub BUILD( $self, $args ) {
    $args->{labels} = App::Notetaker::LabelSet->new( labels => $self->frontmatter->{labels} );
}

sub deleted( $self ) {
    my $fn = $self->filename;
    $self->path =~ m!^deleted/!;
}

sub archived( $self ) {
    my $fn = $self->filename;
    $self->path =~ m!^archived/!;
}

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

sub from_file( $class, $fn, $document_directory ) {
    my $f = Mojo::File->new($fn);
    my $body = $f->slurp('UTF-8');
    my $tfm = Text::FrontMatter::YAML->new(
        document_string => $body,
    );
    my $l = (($tfm->frontmatter_hashref // {})->{labels}) // [];

    my $path = $f->abs2rel( $document_directory );

    $class->new( {
        (path => $path),
        (filename => $f->basename),
        (frontmatter => $tfm->frontmatter_hashref // {}),
        (labels => App::Notetaker::LabelSet->new(labels => $l)),
        (body => $tfm->data_text),
    } );
}

sub save_to( $self, $fn ) {
    my $f = Mojo::File->new($fn);

    $self->frontmatter->{labels} = $self->labels->labels;

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
    $self->labels->add( @labels );
}

sub remove_label( $self, @labels ) {
    $self->labels->remove( @labels );
}

sub title( $self ) {
    if( exists $self->frontmatter->{title}) {
        return $self->frontmatter->{title}
    } elsif( $self->body ) {
        $self->body =~ /^.*?(\S+.*?)$/m
            and return $1
    } else {
        return ''
    }
}

1;
