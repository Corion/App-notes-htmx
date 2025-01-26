package App::Notetaker::Utils 0.01;
use 5.020;
use experimental 'signatures';
use POSIX 'strftime';

use Exporter 'import';
our @EXPORT_OK = qw(
    timestamp
);

sub timestamp( $ts = time ) {
    return strftime '%Y-%m-%dT%H:%M:%SZ', gmtime($ts)
}

1;
