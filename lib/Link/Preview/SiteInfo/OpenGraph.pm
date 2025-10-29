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

        my $url = $og->property( "url" )
                  // $info->{url};
        my $domain = Mojo::URL->new($url)->host;
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
                domain => $domain,
                type => $type,
            },
            markdown_template => <<'MARKDOWN',
    <div class="link-preview link-preview-opengraph">
        <div class="title"><a href="{url}">{title}</a></div>
        <a class="image" href="{url}"><img src="{image}" /></a>
        <div class="description">{description}</div>
        <div class="domain"><a href="{url}">{domain}</a></div>
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
