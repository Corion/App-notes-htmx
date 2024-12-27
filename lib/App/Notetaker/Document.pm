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

sub from_file( $class, $fn ) {
    my $f = Mojo::File->new($fn);
    my $body = $f->slurp;
    my $tfm = Text::FrontMatter::YAML->new(
        document_string => $body,
    );

    $class->new( {
        filename => $f->basename,
        frontmatter => $tfm->frontmatter_hashref,
        body => $tfm->data_text,
    } );
}

sub save_to( $self, $fn ) {
    my $f = Mojo::File->new($fn);
    my $tfm = Text::FrontMatter::YAML->new(
        data_text => $self->body,
        frontmatter_hashref => $self->frontmatter,
    );

    $f->spew( $tfm->document_string );
}

1;
