package Link::Preview 0.01;
use 5.020;
use experimental 'signatures';
use stable 'postderef';
use Moo 2;
use File::Temp 'tempfile';

has 'markdown_template' => (
    is => 'ro',
);

has 'values' => (
    is => 'lazy',
    default => sub { {} },
);

has 'assets' => (
    is => 'lazy',
    default => sub { {} },
);

around 'BUILDARGS' => sub( $orig, $class, %args ) {
    if( $args{ assets } and ref $args{assets} eq 'ARRAY' ) {
        $args{ assets } = +{ map {; $_ => [$_, tempfile()] } $args{ assets }->@* };
    }

    for my $asset (keys $args{ assets }->%*) {
        if( ! ref $args{ assets }->{ $asset }) {
            $args{ assets }->{ $asset } = [ $args{ assets }->{ $asset }, $class->asset_filename( $args{ assets }->{$asset}) // tempfile ]
        }
    }
    return $class->$orig( %args )
};

sub asset_filename( $class, $url ) {
    $url =~ m!.*/([^/?]+)(?:\z|\?)!
        and return $1
}

# Might need one more layer of ->interpolate() ?!
sub value( $self, $key, $values = $self->values, $assets = $self->assets ) {
    my $res;
    $res //= $values->{ $key };
    if( $assets->{ $key } ) {
        $res //= $assets->{ $key }->[1]
    }
    return $self->interpolate( [$res], $values )->[0]
}

sub interpolate( $self, $strings, $values=$self->values ) {
    return [map {
        s!\{(\w+)\}!$self->value( $1, $values, $self->assets ) // "{$1}"!gre
    } ($strings->@*)]
}

sub render( $self, $values = $self->values, $template = $self->markdown_template ) {
    return $self->interpolate( [$template], $values )->[0]
}

sub markdown( $self, $values = $self->values, ) {
    return $self->render( $values, $self->markdown_template )
}

sub assets_for_fetch( $self ) {
    my $assets = $self->assets;
    return +{
        map { $_ => $self->interpolate( $assets->{$_} )}
            keys $assets->%*
    }
}

sub fetched( $self, $asset, $target ) {
    $self->assets->{ $asset } = $target;
    $self->values->{ $asset } = $target;
}

1;
