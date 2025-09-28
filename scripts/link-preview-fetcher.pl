#!perl
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
    # XXX also fill "title", "type"

    return Link::Preview->new(
        markdown_template => <<'MARKDOWN',
[![Linktext]({image})]({url})
MARKDOWN
        assets => { image => ['https://img.youtube.com/vi/{id}/default.jpg', 'thumbnail_{id}.jpg'] },
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
            return Link::Preview->new(
                assets => { image => $image },
                values => {
                    title => $title,
                    description => $description,
                    url => $url,
                    type => $type,
                },
                markdown_template => <<'MARKDOWN',
    <div class="opengraph">
        <a href="{url}">
            <div class="title">{title}</div>
            <img src="{image}" />
            <div class="description">{description}</div>
        </a>
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
    return
        fetch_preview_youtube( $ua, $url )
     // fetch_preview_opengraph( $ua, $url )
        ;
}

#say "<html>";
for my $url (@ARGV) {
    #say "<h1>$url</h1>";
    if( my $preview = fetch_preview( $ua, $url )) {
    #use Data::Dumper; warn Dumper $preview;
        for my ($asset, $target) ($preview->assets_for_fetch->%*) {
            my ($url, $filename) = $target->@*;
            $filename //= tmpfile;
            $filename = "assets/$filename";
            say "Fetching $asset <$url> to $filename";
            $preview->fetched( $asset, $filename );
        }
        # How do we actually want to render these?
        # Different sites warrant different "cards"
        # but different output formats also warrant different "cards"
        # So we would want/need to create an OpenGraph-like data format
        # and have separate templates to render them?!
        # On the other hand, one can always render into a custom template
        say $preview->markdown;
    }
}
#say "</html>";
