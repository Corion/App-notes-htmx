#! /usr/bin/perl -w
use 5.020;
use experimental 'signatures';
use File::Find ();
use Getopt::Long;
use File::Basename;
use App::Notetaker::User;

=head1 NAME

cleanup-deleted-notes.pl - Clean up deleted notes after some days

This is intended to be run from a cron job

  # Clean up all notes older than 15 days, for all users
  30 2 * * * /home/notes/scripts/cleanup-deleted-notes.pl --days 15

To test out what notes would be deleted run it with the C<--dry-run> option

  /home/notes/scripts/cleanup-deleted-notes.pl --days 15 --dry-run

=cut

GetOptions(
    'u|user=s' => \my @users,
    'b|directory=s' => \my $directory,
    'd|days=i' => \my $days,
    'n|dry-run' => \my $dry_run,
);

$directory //= dirname( $0 )."/..";
$days //= 15;

if(! @users) {
    @users = map { basename( s/\.yaml\z//r ) } glob "$directory/users/*.yaml";
}

sub do_unlink( $filename ) {
    if( $dry_run ) {
        say $filename;
    } else {
        unlink $filename
            or warn "Couldn't remove '$filename': $!";
    }
}

sub cleanup_user( $user ) {
    File::Find::find({
        wanted => sub { !-d && -M $_ > $days and do_unlink( $File::Find::name )},
        no_chdir => 1,
    }, "$directory/" . $user->notes . "/deleted");
}

for my $u (@users) {
    my $user = App::Notetaker::User->load($u, "$directory/users");
    cleanup_user( $user );
}
