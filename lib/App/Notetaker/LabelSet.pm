package App::Notetaker::LabelSet 0.01;
use 5.020;
use experimental 'signatures';
use Moo 2;

has 'labels' => (
    is => 'lazy',
    default => sub { [] },
);

sub BUILD( $self, $args ) {
    $args->{labels} //= [];

    $self->assign( $args->{labels}->@* );
}

sub as_set( $self ) {
    my %l = map { fc $_ => $_ } $self->labels->@*;
    return \%l;
}

sub _rebuild( $self, $set ) {
    $self->labels->@* = map { $set->{ fc($_)} } sort { fc($a) cmp fc($b) } keys $set->%*;
}

sub add($self, @added) {
    my $l = $self->as_set();

    for (@added) {
        $l->{ fc($_) } = $_;
    }

    $self->_rebuild( $l );
}

sub remove($self, @deleted) {
    my $l = $self->as_set();

    for (@deleted) {
        delete $l->{ fc($_) };
    }

    $self->_rebuild( $l );
}

# Sort the labels, make them unique
sub assign($self, @labels) {
    my %seen;
    $self->{ labels }->@* = grep { ! $seen{fc($_)}++ }
                            sort { fc($a) cmp fc($b) }
                            @labels;
}


1;
