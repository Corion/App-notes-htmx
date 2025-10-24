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

    return Link::Preview->new(
        markdown_template => <<'MARKDOWN',
[![Linktext]({image})]({url})
MARKDOWN
        assets => { image => ['https://img.youtube-nocookie.com/vi/{id}/0.jpg', 'thumbnail_{id}.jpg'] },
        values => { id => $id, url => $url,
            type => 'video',
        },
    );
};

1;
