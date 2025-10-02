package Mojolicious::Plugin::UrlWithout;
use 5.020;
use Mojo::Base 'Mojolicious::Plugin';
use experimental 'signatures';
use Carp 'croak';

sub register( $self, $app, @args ) {
    $app->helper( url_without => \&url_without );
}

=head2 C<< url_without >>

    # ?filter=Open&filter=New
    my $url = url_without("/", filter => 'New');
    # ?filter=Open

=cut

sub url_without( $c, $path, @remove ) {
    my $url = $c->url_with( $path );

    while( defined( my $param = shift @remove )) {
        if( ref $param ) {
            if( ref $param eq 'HASH') {
                croak "What is a hashref supposed to mean?";
            } elsif(ref $param eq 'ARRAY') {
                croak "What is a arrayhref supposed to mean?";
            } else {
                croak sprintf "Unknown ref %s", ref $param;
            }
        } else {
            my $arg = shift @remove;
            if( defined $arg ) {
                $url->query->merge( $param => [grep { $_ ne $arg } $url->query->every_param( $param )->@*]);
            } else {
                $url->query->remove( $param );
            }
        }
    }
    return $url
}

1;
