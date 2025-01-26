package App::Notetaker::Session 0.01;
use 5.020;
use experimental 'signatures';
use Moo;
use Mojo::File;
use File::Temp;
use File::Basename;
use Time::Local 'timelocal';
use Date::Period::Human;
use POSIX 'strftime';

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

sub _make_bucket( $start, $end, $name=undef ) {
    my $d = Date::Period::Human->new({ lang => 'en' });
    return +{
        vis => $name // $d->human_readable( $start ),
        start => main::timestamp( $start ),
        end => main::timestamp( $end ),
    };
}

has 'created_buckets' => (
    is => 'ro',
    default => sub {
        my $ts = time();
        my( $S,$M,$H,$d,$m,$y ) = gmtime($ts);
        my $daystart = timelocal(0,0,3,$d,$m,$y);
        [
        # Missing: a "today" bucket that catches everything from 03:00 until now
            _make_bucket( $daystart, $daystart+365*24*60*60, 'today' ),
            _make_bucket( $daystart-24*60*60, $daystart, 'yesterday' ),
            _make_bucket( $daystart-24*60*60*7,  $daystart - 24*60*60, 'a week ago' ),
            _make_bucket( $daystart-24*60*60*13, $daystart - 24*60*60*7, 'two weeks ago' ),
            _make_bucket( 0, $daystart-24*60*60*13, 'earlier' ),
        ]
    },
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
