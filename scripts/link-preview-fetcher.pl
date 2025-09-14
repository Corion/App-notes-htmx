#!perl
package Link::Preview::Markdown 0.01;
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

sub interpolate( $self, $strings, $values=$self->values ) {
    return [map {
        s!\{(\w+)\}!$values->{$1} // "{$1}"!gre
    } ($strings->@*)]
}

sub markdown( $self, $values = $self->values, ) {
    return $self->interpolate( [$self->markdown_template], $values )->[0]
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

package main;
use 5.020;
use experimental 'signatures';
use experimental 'for_list';
use stable 'postderef';

use Data::OpenGraph;
use Getopt::Long;
use LWP::UserAgent::Paranoid;
use Data::Dumper;
use File::Temp 'tmpfile';

sub fetch_preview_youtube( $ua, $url ) {
    my $id;
    if( $url =~ m!v=([^;&]+)! ) {
        $id = $1;
    } elsif( $url =~ m!/embed/([^/?]+)! ) {
        $id = $1;
    } else {
        return
    }
    # XXX also handle youtu.be , youtube-nocookie

    return Link::Preview::Markdown->new(
        markdown_template => <<'MARKDOWN',
[![Linktext]({thumbnail})]({url})
MARKDOWN
        assets => { thumbnail => ['https://img.youtube.com/vi/{id}/default.jpg', 'thumbnail_{id}.jpg'] },
        values => { id => $id, url => $url, },
    );
}

sub fetch_preview_opengraph( $ua, $url ) {
    my $res = $ua->get( $url );

    if( $res->is_success ) {

        my $og = Data::OpenGraph->parse_string( $res->decoded_content );

        if( $og->property("type")) {
            # We found some (valid) OpenGraph entity

            my $url = $og->property( "url" );
            my $title = $og->property( "title" );
            my $type  = $og->property( "type" );
            my $image  = $og->property( "image" );
            my $description  = $og->property( "description" );

            # We need HTML escaping for everything here!
            return Link::Preview::Markdown->new(
                assets => { image => $image },
                values => {
                    title => $title,
                    description => $description,
                    url => $url,
                    type => $type,
                },
                markdown_template => <<'MARKDOWN',
    <div class="opengraph" href="{url}">
        <div class="title">{title}</div>
        <img src="{image}" />
        <div class="description">{description}</div>
    </div>
MARKDOWN
            );
        } else {
            return;
        }

    } else {
        return;
    }
}

my $ua = LWP::UserAgent::Paranoid->new();
$ua->protocols_allowed(["http", "https"]);

sub fetch_preview( $ua, $url ) {
    if( my $r = fetch_preview_youtube( $ua, $url )) {
        return $r
    } elsif( my $r = fetch_preview_opengraph( $ua, $url )) {
        return $r
    } else {
        return
    }
}

#say "<html>";
for my $url (@ARGV) {
    #say "<h1>$url</h1>";
    my $preview = fetch_preview( $ua, $url );
    #use Data::Dumper; warn Dumper $preview;
    for my ($asset, $target) ($preview->assets_for_fetch->%*) {
        my ($url, $filename) = $target->@*;
        $filename //= tmpfile;
        $filename = "assets/$filename";
        say "Fetching $asset <$url> to $filename";
        $preview->fetched( $asset, $filename );
    }
    say $preview->markdown;
}
#say "</html>";
