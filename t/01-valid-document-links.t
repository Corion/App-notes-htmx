#!perl
use 5.020;
use experimental 'signatures';

use Test2::V0 '-no_srand';
use List::Util 'uniq';
use IPC::Open3;
use Symbol 'gensym';

$ENV{TEST_NOTES_BASE}="t/";
$ENV{TEST_NOTES_USER}="demo";

sub request( $method, $url ) {
    #diag "$^X, '-Ilib', 'scripts/notetaker.pl', 'get', $url";
    my $pid = open3( my $input, my $output, my $err = gensym(),
        $^X, '-Ilib', 'scripts/notetaker.pl', $method, $url
    );

    my $html = do { local $/; <$output> };
    my $error = do { local $/; <$err> };
    waitpid( $pid, 0 );
    return { html => $html, error => $error };
}

sub extract_attribute( $html, $tag, $attr, $method='get' ) {
    my @res;
    while( $html =~ m!(<$tag [^>]*${attr}="([^"]+)".*?>)!gsi ) {
        push @res, { method => $method, tag => $1, link => $2 }
    }
    for( @res ) {
        $_->{link} =~ s!&amp;!&!g;
    }
    @res
}

sub extract( $html, $tag, @attributes ) {
    map { extract_attribute( $html, $tag, $_ ) } @attributes;
}

sub links( $html ) {
    # Yees, we could use XML::LibXML for that ...
    my @links;
    push @links, extract( $html, 'a', 'href' );
    push @links, extract( $html, 'link', 'href' );
    push @links, extract( $html, 'img', 'src' );
    push @links, extract( $html, 'script', 'src' );

    # Also scan for HTMX attributes here
    return @links
}

sub title( $html ) {
   [($html =~ m!<title>([^<]+)</title>!msi)]->[0];
}

my @queue = ({ link => "/" });
my %seen = (
    '#' => 1,
);

my @errors;

# Clean up all temporary notes our links might create
opendir my $dh, "t/notes";
my %keep = map {; "t/notes/$_" => 1 }
           readdir $dh;
END {
    opendir $dh, "t/notes";
    unlink grep { ! $keep{ $_ } }
        map {; "t/notes/$_" }
        readdir $dh
        ;
}

while (@queue) {
    my $info = shift @queue;
    next if $seen{ $info->{link} }++;

    if( $info->{link} =~ m!^https?://! ) {
        # Skip absolute link
        note "Ignoring $info->{link}";
        next;
    } elsif( $info->{link} =~ /^#/ ) {
        next;
    }

    my $res = request( $info->{link} );
    my $page = $res->{html};

    my $title = title( $page );
    $title //= '<no title>';

    diag sprintf "%s - %s", $info->{link}, $title;
    if( $title =~ /\Q(development mode)/) {
        diag $res->{error};
        diag "URL: $info->{link}";
        diag "Found on : $info->{found_on}";
        diag "Tag: $info->{tag}";
        # Later, we'll do some fancy statistics, but not now
        exit;
    };

    push @queue,
        map { $_->{ found_on } = $info->{link}; $_ }
        grep { ! $seen{ $_->{link} }}
        grep { $_->{link} !~ /^\s*javascript:/ }
        links( $page )
        ;
}

is \@errors, [], "No pages had errors";

done_testing;
