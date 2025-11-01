package Link::Preview::SiteInfo::YouTube;
use 5.020;
use Moo 2;
use experimental 'signatures';
with 'Link::Preview::SiteInfo';
use Link::Preview;

use constant moniker => 'YouTube';
use constant prerequisites => { url => 1 };

around 'applies' => sub( $orig, $class, $info ) {
    my $url = $info->{url} // '';
       $url =~ m!\?v=([^;&]+)!
    || $url =~ m!/embed/([^?]+)!
    ;
};

around 'generate' => sub( $orig, $class, $info ) {
    # XXX also handle youtu.be , youtube-nocookie
    # XXX also fill "title", "type"

    my $res = {};
    my $url = ($info->{url} // '');
    my $id;
    # XXX use a proper URL parser here
    if( $url =~ m!\?v=([^;&]+)! ) {
        $id = $1;
    } elsif( $url =~ m!/embed/([^/?]+)! ) {
        $id = $1;
    } else {
        return
    }

    # We should fetch this without an API key. Maybe simply by fetching that
    # page?
    my $title = 'Youtube video';
    my $description = 'Youtube video';

    return Link::Preview->new(
        markdown_template => <<'MARKDOWN',
    <div class="link-preview link-preview-youtube">
        <a href="{url}">
            <div class="title">{title}</div>
            <a class="image" href="{url}"><img src="{image}" /></a>
            <div class="description">{description}</div>
            <div class="domain">{domain}</div>
        </a>
    </div>
MARKDOWN
        assets => { image => ['https://img.youtube.com/vi/{id}/0.jpg', 'thumbnail_{id}.jpg'] },
        values => {
            id => $id,
            url => $url,
            domain => 'youtube-nocookie.com',
            type => 'video',
            title => $title,
            description => $description,
        },
    );
};

1;
