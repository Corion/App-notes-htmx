package Link::Preview::SiteInfo 0.01;
use 5.020;
use experimental 'signatures';
use Moo::Role;

requires 'moniker', 'prerequisites';

sub applies( $self, $info ) {
    return undef
}

sub generate( $self, $info ) {
    return undef
}

1;
