package Zabbix::Reporter::Cmd::Command::actions;
# ABSTRACT: enable all actions from the CLI

use 5.010_000;
use mro 'c3';
use feature ':5.10';

use Moose;
use namespace::autoclean;

# use IO::Handle;
# use autodie;
# use MooseX::Params::Validate;
# use Carp;
# use English qw( -no_match_vars );
# use Try::Tiny;
use Data::Dumper;

# extends ...
extends 'Zabbix::Reporter::Cmd::Command';
# has ...
# with ...
# initializers ...

# your code here ...
=method execute

List all triggers.

=cut
sub execute {
    my $self = shift;

    my $status = $self->zr()->enable_actions();

    return 1;
}

=method abstract

Workaround.

=cut
sub abstract {
    return 'Enable all actions';
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;

__END__

=head1 NAME

Zabbix::Reporter::Cmd::Command::list - list all triggers from the CLI

=cut
