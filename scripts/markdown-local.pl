#!perl
use 5.020;
use experimental 'signatures';
use File::Basename;
use Getopt::Long;
use URI::URL;

GetOptions(
    'n|dry-run' => \my $dry_run,
    'verbose' => \my $verbose,
);

$verbose //= $dry_run;

sub mirror_image( $url, $filename ) {
    my (@cmd) = ('curl', '--silent', $url, '-o', $filename);
    if( $verbose ) {
        print "# @cmd";
    }
    if( !$dry_run ) {
        system(@cmd) == 0;
    }
}

sub process_file( $filename ) {
    my $dir = dirname( $filename );
    open my $fh, '<:utf8', $filename
        or die "Couldn't read '$filename': $!";

    my $res = '';
    while( <$fh> ) {
        if( m"!\[.*?\]\((.*?)\)" ) {
            my $url = $1;

            if( $url =~ m!^https://(?:www\.)?youtube\.com\b! ) {
                (my $id)   = ($url =~ m!\?v=([^/;&]+)!);
                ($id)    //= ($url =~ m!/embed/([^/?]+)!);

                my $filename  = ("$id.jpg");
                my $thumbnail = sprintf 'https://img.youtube.com/vi/%s/0.jpg', $id;

                mirror_image( $thumbnail => "$dir/$filename" );

                # ![youtube.com](https://www.youtube-nocookie.com/embed/FJtF3wzPSrY)
                # [![Witcher 4 Video Thumbnail](witcher-4-thumbnail.jpg)](https://www.youtube-nocookie.com/embed/FJtF3wzPSrY)

                s{!\[(.*?)\]\((.*?)\)}{[![$1]($filename)]($url)};

                warn $_;

            } elsif( $url =~ m!^https://! ) {
                (my $filename) = ($url =~ m!/([^/]+)\z!);
                mirror_image( $url => "$dir/$filename" );
                s{!\[(.*?)\]\((.*?)\)}{![$1]($filename)};
            }
        }
        $res .= $_;
    }
    return $res;
}

sub update_file( $filename ) {
    my $str = process_file( $filename );
    if( $verbose ) {
        say $str;
    }
    if( $str and not $dry_run) {
        rename $filename => "$filename.bak"
            or die "Couldn't create backup of '$filename': $!";
        open my $fh, '>:utf8', $filename
            or die "Couldn't create new file '$filename': $!";
        print $fh $str;
    }
}

for my $f (@ARGV) {
    update_file( $f );
}
