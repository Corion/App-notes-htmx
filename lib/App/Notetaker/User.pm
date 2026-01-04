package App::Notetaker::User;
use 5.020;
use Moo 2;
use YAML::PP::LibYAML 'LoadFile', 'DumpFile';

use feature 'try';
use experimental 'signatures';

has 'notes' => (
    is => 'ro',
);

has 'pass' => (
    is => 'rw',
);

has 'user' => (
    is => 'ro',
);

has 'username' => (
    is => 'rw',
);

sub load( $class, $u, $user_directory ) {
    $u =~ s![\\/]!!g;
    opendir my $dh, $user_directory
        or die "Couldn't read user directory '$user_directory': $!";

    # Search case-insensitively for the login name/file in $user_directory
    (my $fn) = grep { (fc $_) eq ((fc $u).'.yaml') } readdir $dh;
    try {
        $fn = "$user_directory/$fn";
        if( -f $fn and -r $fn ) {
            # libyaml still calls exit() in random situations
            return $class->new(LoadFile($fn))
        }
    } catch ($e) {
        warn "Got exception: $e";
        return undef
    }
}

sub save( $self, $user_directory ) {
    my $u = $self->user;
    DumpFile( "$user_directory/$u.yaml", $self )
}

1;
