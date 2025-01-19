package App::Notetaker::Session 0.01;
use 5.020;
use experimental 'signatures';
use Moo;
use Mojo::File;
use File::Temp;
use File::Basename;

has 'username' => (
    is => 'ro',
);
has 'document_directory' => (
    is => 'ro',
);

has 'labels' => (
    is => 'ro',
    default => sub { {} },
);
has 'colors' => (
    is => 'ro',
    default => sub { {} },
);

has 'editor' => (
    is => 'rw',
    default => 'html',
);

sub init( $self, $document_directory = $self->document_directory ) {
    mkdir $self->document_directory . "/deleted"; # so we can always (un)delete notes
}

sub documents( $self, $document_directory = $self->document_directory ) {
    #warn "Loading '" . $self->document_directory . "/*.markdown'";
    return glob $self->document_directory . "/*.markdown";
}

sub clean_filename( $self, $fn ) {
    # Sanitize filename; maybe we want Text::CleanFragment?!
    $fn =~ s![\x00-\x1f]! !g;
    $fn =~ s!\\/!!g;
    return join "/", $self->document_directory, $fn
}

sub tempnote($self) {
    my($fh,$fn) = File::Temp::tempfile( "unnamedXXXXXXXX", DIR => $self->document_directory, SUFFIX => '.markdown' );
    close $fh;
    return basename($fn)
}

1;
