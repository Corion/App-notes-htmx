#!perl
use 5.020;
use experimental 'signatures';

use Test2::V0 '-no_srand';
use Link::Preview::SiteInfo::YouTube;
use Link::Preview::SiteInfo::OpenGraph;

my $l = Link::Preview::SiteInfo::YouTube->generate({
    url => 'https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ',
    html => undef,
});

is $l->markdown,
    "[![Linktext](thumbnail_dQw4w9WgXcQ.jpg)](https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ)\n",
    "We correctly interpolate values, also in the markdown";

my $l = Link::Preview::SiteInfo::OpenGraph->generate({
    url => 'https://example.com/',
    html => <<'HTML',
<head>
<meta property="og:url"   content="https://example.com/" />
<meta property="og:title" content="Bleh" />
<meta property="og:type"  content="text" />
</head>
HTML
});

is $l->markdown,
    "",
    "We correctly interpolate values, also in the markdown for OpenGraph";



done_testing;
