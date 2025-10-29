package Link::Preview 0.01;
use 5.020;
use experimental 'signatures';
use stable 'postderef';
use Moo 2;
use File::Temp 'tempfile';

has 'markdown_template' => (
    is => 'ro',
);

# Programmer-provided
has 'variables' => (
    is => 'lazy',
    default => sub { {} },
);

# Server-provided
has 'values' => (
    is => 'lazy',
    default => sub { {} },
);

# Programmer-provided, cleaned if coming from server
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
    $url =~ m!.*/([^/?\0]+)(?:\z|\?)!
        and return $1
}

# Might need one more layer of ->interpolate() ?!
# Also, we need to distinguish programmer-provided values (which may be
# interpolated further) vs. server-provided values (which may not be interpolated further)
# Maybe change all curly brackets in server-side values to \0...\1 , and change
# them back only in the last step

# Even better, we want a stack of variables and resolve them until only
# server-provided values remain:
#
# programmer-provided: variables
#                      assets
# server-provided:     server_values
#
# We replace template elements with stuff from variables and assets until only
# stuff from server_values remains. Then we replace that in a final go.

sub value( $self, $key, $values = $self->values, $assets = $self->assets ) {
    my $res;
    $res //= $values->{ $key };
    if( $assets->{ $key } ) {
        #$res //= $assets->{ $key }->[1]
        # Quick hack until we get a caching proxy
        $res //= $assets->{ $key }->[0]
    }
    return $self->interpolate( [$res], $values )->[0]
}

sub interpolate( $self, $strings, $values=$self->values ) {
    return [map {
        1 while s!\{(\w+)\}!$self->value( $1, $values, $self->assets )!ge;
        $_
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
