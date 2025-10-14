package App::Notetaker::Label 0.01;
use 5.020;
use experimental 'signatures';
use Moo 2;

use overload '""' => sub {shift->visual}, fallback => 1;

=head1 NAME

App::Notetaker::Label - hold information about a label

=head1 SYNOPSIS

  my $label = App::Notetaker::Label->new(
      visual  => 'Kermit',
      color   => 'green',
  );

=head1 METHODS

=head2 C<< ->new >>

=cut

has 'text' => (
    is => 'ro',
    required => 1,
);

has 'visual' => (
    is => 'rw',
    default => sub { $_[0]->text },
);

has 'color' => (
    is => 'ro',
    default => '',
);

has 'details' => (
    is => 'lazy',
    default => sub { [] },
);

sub clone( $self ) {
    __PACKAGE__->new( { $self->%* } )
}

1;
