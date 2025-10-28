#!perl
use 5.020;
use experimental 'signatures';

use Test2::V0 '-no_srand';
use Link::Preview::SiteInfo::YouTube;
use Link::Preview::SiteInfo::OpenGraph;
use Data::Dumper;

my $l = Link::Preview::SiteInfo::YouTube->generate({
    url => 'https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ',
    html => undef,
});

is $l->markdown,
    "[![Linktext](thumbnail_dQw4w9WgXcQ.jpg)](https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ)\n",
    "We correctly interpolate values, also in the markdown";

   $l = Link::Preview::SiteInfo::OpenGraph->generate({
    url => 'https://example.com/',
    html => <<'HTML',
<head>
<meta property="og:url"   content="https://example.com/" />
<meta property="og:title" content="Bleh" />
<meta property="og:type"  content="text" />
<meta property="og:image" content="https://example.com/mythumb.jpg" />
<meta property="og:description" content="My description" />
</head>
HTML
});

is $l->markdown,
    <<'HTML',
    <div class="opengraph">
        <a href="https://example.com/">
            <div class="title">Bleh</div>
            <img src="https://example.com/" />
            <div class="description">My description</div>
        </a>
    </div>
HTML
    "We correctly interpolate values, also in the markdown for OpenGraph"
    or diag Dumper $l;

$l->fetched('image' => 'mythumb_cached.jpg');

is $l->markdown,
    <<'HTML',
    <div class="opengraph">
        <a href="https://example.com/">
            <div class="title">Bleh</div>
            <img src="mythumb_cached.jpg" />
            <div class="description">My description</div>
        </a>
    </div>
HTML
    "We correctly interpolate values, after fetching stuff to local storage"
    or diag Dumper $l;

my $malformed = Link::Preview::SiteInfo::OpenGraph->generate({
    url => 'https://example.com/',
    html => <<'HTML',
<head>
<meta property="og:url"   content="https://example.com/" />
<meta property="og:title" content="{url}" />
<meta property="og:type"  content="text" />
<meta property="og:image" content="https://example.com/mythumb.jpg" />
<meta property="og:description" content="My description" />
</head>
HTML
});
is $malformed->markdown,
    <<'HTML',
    <div class="opengraph">
        <a href="https://example.com/">
            <div class="title">{url}</div>
            <img src="mythumb_cached.jpg" />
            <div class="description">My description</div>
        </a>
    </div>
HTML
    "Our fake templating system handles curly brackets"
    or diag Dumper $malformed;

done_testing;
