#!perl
use 5.020;

use Getopt::Long;
use Pod::Usage;
use experimental 'signatures';
use stable 'postderef';
use PerlX::Maybe;

use File::Temp 'tempdir';
use Mail::Header;
use MIME::Parser;
use XML::LibXML;
use lib '../Text-HTML-Turndown/lib';
use Text::HTML::Turndown 'html2markdown';
use Text::HTML::ExtractInfo 'extract_info';
use Text::CleanFragment 'clean_fragment';
use Mail::IMAPClient;
use Mail::IMAPClient::BodyStructure;
use URI;
use URI::URL;
use URI::imap;
use URI::imaps;
use POSIX 'strftime';
use Fcntl 'SEEK_END', 'LOCK_UN', 'LOCK_EX';
use Path::Class;

our $VERSION = '0.01';

GetOptions(
    'inbox|i=s'            => \my $folder,
    'outdir|d=s'           => \my $outdir,
    'from|f=s'             => \my $from_regex,
    'to|t=s'               => \my $to_regex,
    'archive-folder|a=s'   => \my $archive_folder,

    'verbose|v'            => \my $verbose,
    'dry-run|n'            => \my $dryrun,

    'inbox-message-file=s'    => \my $lastmessage_file,
) or pod2usage(2);

sub verbose(@msg) {
    if( $verbose ) {
        say $_ for @msg
    };
}

$from_regex //= qr/\A.*\z/;
$to_regex //= qr/\A.*\z/;

$outdir //= '.';

sub connect_to_inbox( $inbox_url ) {
    verbose( "Reading mail" );
    $inbox_url = URI->new( $inbox_url );
    my $mailserver = $inbox_url->host;
    my ($user, $password) = split ':', $inbox_url->userinfo;
    my $imap = Mail::IMAPClient->new(
        Server   => $mailserver,
        User     => $user,
        Password => $password,
        Uid      => 1,
        Ssl      => 1,
    ) or die "Can't connect to $inbox_url: $@";
    my $folder = $inbox_url->path;
    $folder =~ s!^/!!;
    $imap->connect();
    $imap->Peek(1); # we want to keep unread messages unread
    $imap->select( $folder )
        or die "Couldn't select folder '$folder': " . $imap->LastError;
    return $imap
}

our @whitelist;
our %known_email;
our $promiscous = 0;

my $tempdir = tempdir(CLEANUP => 1);
my $p = MIME::Parser->new;
$p->output_under( $tempdir );

my $config_dir = $ENV{ XDG_CONFIG_HOME } // $ENV{ HOME } // '~';
$lastmessage_file //= file( "$config_dir/mail2markdown-lastmessage" );

# Set up the file for the last message we handled
my $today = strftime '%Y-%m-%dT00:00:01', localtime;
my ($lastmessage);
my $lastmessage_fh;
if( -f $lastmessage_file ) {
    open $lastmessage_fh, '<:raw', $lastmessage_file
        or die "Couldn't read last message from '$lastmessage_file': $!";
    flock($lastmessage_fh, LOCK_EX)
        or die "Cannot lock last message file '$lastmessage_file': $!";

    # and, in case someone appended while we were waiting...
    seek($lastmessage_fh, 0, SEEK_END)
        or die "Cannot seek '$lastmessage_file': $!";
    ($lastmessage) = map { s/\s*$//; $_ } <$lastmessage_fh>;
};

END {
    if( $lastmessage_fh and ! $dryrun) {
        seek($lastmessage_fh, 0, SEEK_END);
        truncate( $lastmessage_fh, 0 );
        print $lastmessage_fh
            join "\n", $lastmessage;
        flock($lastmessage_fh, LOCK_UN)
            or die "Cannot unlock last message file '$lastmessage_file': $!";
        close $lastmessage_fh;
    };
};

sub extract_mail( $m ) {
    if( $m->head->get('To') !~ /$from_regex/ ) {
        return;
    }

    my $subj = $m->head->get('Subject');
    # Clean up subject, remove ^(Re: / Wg: / Fwd:)*
    $subj =~ s/\A(aw|wg|re|fwd:\s*)+//i;

    my $tfm;

    # See if we got any text/html entity
    # dump that using html2markdown
    for my $part ($m->parts) {
        if( $part->head->mime_type eq 'text/html' ) {
            $tfm = html2markdown(join( "\n", $part->body->@* ), title => $subj);
            last
        };
    }

    if( ! $tfm ) {
        for my $part ($m->parts) {
            if( $part->head->mime_type eq 'text/plain' ) {
                $tfm = Text::FrontMatter::YAML->new(
                    frontmatter_hashref => { subject => $subj },
                    data_text => $part->body,
                );
                last
            }
        }
    }

    # Must have been a test-only mail
    $tfm //= Text::FrontMatter::YAML->new(
        frontmatter_hashref => { subject => $subj },
        data_text => $m->body,
    );

    my $outname = sprintf '%s/%s.markdown', $outdir, clean_fragment($tfm->frontmatter_hashref->{title});
    if( ! -e $outname ) {
        open my $fh, '>:encoding(UTF-8)', $outname
            or die "Couldn't create '$outname': $!";
        print { $fh } $tfm->document_string;
    }

    return $tfm
}


sub _parse_bodystructure( $bodystructure_string ) {
    my $bs = "(BODYSTRUCTURE ($bodystructure_string))";
    my $body = Mail::IMAPClient::BodyStructure->new($bs)
        or die "Couldn't parse bodystructure '$bs'";
}

sub _parse_envelope( $envelope_string ) {
    my $bs = "(ENVELOPE ($envelope_string))";
    my $body = Mail::IMAPClient::BodyStructure::Envelope->new($bs)
        or die "Couldn't parse envelope '$bs'";
    $body
}

sub unseen_mails( $imap, $last_mail_uid ) {
    my $new = $imap->search(SINCE => "01-Jan-2025")
        or die $imap->LastError;
    # Expand body structure to find text/calendar attachments
    my %res = $imap->fetch_hash($imap->Range(@$new), 'INTERNALDATE', 'BODYSTRUCTURE', 'ENVELOPE');
    die $imap->LastError if $imap->LastError;

use Data::Dumper; warn Dumper \%res;

    # parse the bodystructure right here
    for (values %res) {
        $_->{BODYSTRUCTURE} = _parse_bodystructure( $_->{BODYSTRUCTURE});
        $_->{ENVELOPE} = _parse_envelope( $_->{ENVELOPE});
    };

    \%res
};

sub calendar_attachments( $bodystructure, $moniker_prefix="", $seen = {} ) {
    my $moniker = 1;

    return map {
        if( ! $seen->{ $_ }++) {
            my $moniker_path = length $moniker_prefix ? "$moniker_prefix." : "";

            my $mimetype = join "/", $_->bodytype, $_->bodysubtype;
            #warn "$moniker_path$moniker\t$mimetype $_";
            if(   $mimetype eq 'MESSAGE/RFC822'
            or $mimetype =~ qr!^MULTIPART/[A-Z]+$!
            ) {
                #warn "Recursing into $moniker_path$moniker";
                my @res = calendar_attachments( $_, $moniker_path . ($moniker++), $seen);
                #warn "Recursing from $moniker_path$moniker";
                @res
            } else {
                is_calendar_attachment( $_, $moniker_path . ($moniker++) )
            }
        } else {
            ()
        }
    } $bodystructure->bodystructure;
}

my $inbox = connect_to_inbox( $folder );
my $unseen = unseen_mails( $inbox, undef );

my @mails;

# Also add the explicit whitelist
for (@whitelist) {
    $known_email{ $_ } = 1;
};

for my $uid (sort keys %$unseen) {
    # Check mail sender against blacklist
    # Check mail sender against whitelist
    # Check mail sender against contact book(s)
    #die Dumper $unseen->{$uid}->{ENVELOPE};

    # We support only one From: header:
    my $sender = $unseen->{$uid}->{'ENVELOPE'}->from->[0];
    $sender = join '@', $sender->mailboxname, $sender->hostname;

    if( !$promiscous and !$known_email{ $sender } and $sender !~ /$from_regex/) {
        verbose("Mail ... unknown sender '$sender'");
        next;
    }

    push @mails, {
        uid => $uid,
        #info => $unseen->{$uid},
        mail => $unseen->{$uid}->{ENVELOPE},
        attachments => [],
    };
};

for my $mail (@mails) {
    $lastmessage = $mail->{UID};
    if( $mail->{attachments}->@*) {

        EVENT: for my $att (@{ $mail->{attachments}}) {

            # Maybe we'd be better off here using MIME::Parser?!
            # But MIME::Parser has some scary things like writing to disk
            # automatically ...

            my $body_path = 'BODY[' . $att->{path} . ']';
            my $header_path = 'BODY[' . $att->{path} . '.MIME]';
            my $attachments = $inbox->fetch_hash($mail->{uid}, $body_path, $header_path)
                or die join ':', $inbox->LastIMAPCommand, $inbox->LastError;

            # Now, parse the headers and decode the body:
            my $h = Mail::Header->new( [ split /\r\n/, $attachments->{$mail->{uid}}->{$header_path} ]);
            my $encoding = $h->get('Content-Transfer-Encoding');
            $encoding =~ s!\s+$!!;

use Data::Dumper; warn Dumper $attachments;
            my $payload = $attachments->{ $mail->{uid} }->{ $body_path };
            if( $encoding eq 'base64' ) {
                $payload = decode_base64 $payload;

            } else {
                use Data::Dumper;
                warn Dumper $h;
                warn Dumper $attachments;
                die "Unknown transfer encoding '$encoding', please fix the source";
            };

            # mail2markdown($payload)

        };
    };
}
