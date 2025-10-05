#!perl
use 5.020;
use experimental 'signatures';

use Test2::V0 '-no_srand';
use Link::Preview;

my $l = Link::Preview->new(
    'assets' => {
                  'image' => [
                               'https://img.youtube.com/vi/{id}/0.jpg',
                               'thumbnail_{id}.jpg'
                             ],
                },
    'markdown_template' => '[![Linktext]({image})]({url})',
    'values' => {
                  'id' => 'GQCpZH_YYpQ',
                  'type' => 'video',
                  'url' => 'https://www.youtube.com/embed/GQCpZH_YYpQ'
                },
);

is $l->value('image'), 'thumbnail_GQCpZH_YYpQ.jpg', "We correctly interpolate values";
is $l->markdown, '[![Linktext](thumbnail_GQCpZH_YYpQ.jpg)](https://www.youtube.com/embed/GQCpZH_YYpQ)', "We correctly interpolate values, also in the markdown";

done_testing;
