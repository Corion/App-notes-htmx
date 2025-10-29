package Link::Preview::SiteInfo::HTML;
use 5.020;
use experimental 'signatures';
use Moo 2;
use Mojo::DOM;
use Mojo::URL;

with 'Link::Preview::SiteInfo';

use constant moniker => 'HTML';
use constant prerequisites => { url => 1, html => 1 }; # we want the URL so we can resolve relative attributes

around 'applies' => sub( $orig, $class, $info ) {
    1 # this is our fallback thing
};

around 'generate' => sub( $orig, $class, $info ) {
    my $dom = Mojo::DOM->new( $info->{html} );

    my $title = $dom->find('title')->map('text')->first;

    # Find the largest image, not the first...
    # Facebook uses/used the following algorithm:
    # The candidate images are filtered by javascript that removes all images
    # less than 50 pixels in height or width and all images with a ratio of
    # longest dimension to shortest dimension greater than 3:1. The filtered
    # images are then sorted by area and users are given a selection if
    # multiple images exist.
    my $image =  $dom->find('link[rel=image_src]')->map( attr => 'href')->first
              // $dom->find('img[src]')->map( attr => 'src')->first
    ;
    # XXX make image URL relative to $info->{url}

    my $domain = Mojo::URL->new($info->{url})->host;

    # We need HTML escaping for everything here!
    return Link::Preview->new(
        assets => { image => $image },
        values => {
            title => $title,
            url => $info->{url},
            domain => $domain,
            image => $image,
            #type => $type,
        },
        markdown_template => <<'MARKDOWN',
    <div class="link-preview link-preview-html">
        <div class="title"><a href="{url}">{title}</a></div>
        <a class="image" href="{url}">
            <img src="{image}" />
        </a>
        <div class="description">{description}</div>
        <div class="domain"><a href="{url}">{domain}</a></div>
    </div>
MARKDOWN
        );

};

1;


=head1 SEE ALSO

L<https://andrejgajdos.com/how-to-create-a-link-preview/>

L<https://medium.com/slack-developer-blog/everything-you-ever-wanted-to-know-about-unfurling-but-were-afraid-to-ask-or-how-to-make-your-e64b4bb9254>

=cut
