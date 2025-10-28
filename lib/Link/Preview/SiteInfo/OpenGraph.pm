package Link::Preview::SiteInfo::OpenGraph;
use 5.020;
use experimental 'signatures';
use Moo 2;
use Data::OpenGraph;
with 'Link::Preview::SiteInfo';

use constant moniker => 'OpenGraph';
use constant prerequisites => { url => 1, html => 1 }; # we want the URL so we can resolve relative attributes

around 'applies' => sub( $orig, $class, $info ) {
    my $og = Data::OpenGraph->parse_string( $info->{html} );
    return $og->property("type");
};

around 'generate' => sub( $orig, $class, $info ) {
    my $og = Data::OpenGraph->parse_string( $info->{html} );

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
};

1;


=head1 SEE ALSO

L<https://ogp.me/>

=cut
