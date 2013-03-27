package Zabbix::Reporter::Cmd::Command;
# ABSTRACT: baseclass for any CLI command

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
use Config::Yak;
use Log::Tree;
use Zabbix::Reporter;

# extends ...
extends 'MooseX::App::Cmd::Command';

# has ...
has '_config' => (
    'is'       => 'rw',
    'isa'      => 'Config::Yak',
    'lazy'     => 1,
    'builder'  => '_init_config',
    'accessor' => 'config',
);

has '_logger' => (
    'is'       => 'rw',
    'isa'      => 'Log::Tree',
    'lazy'     => 1,
    'builder'  => '_init_logger',
    'accessor' => 'logger',
);

has '_zr' => (
    'is'       => 'rw',
    'isa'      => 'Zabbix::Reporter',
    'lazy'     => 1,
    'builder'  => '_init_zr',
    'accessor' => 'zr',
);

# with ...
# initializers ...
sub _init_config {
    my $self = shift;

    my $Config = Config::Yak::->new( { 'locations' => [qw(conf /etc/zreporter)], } );

    return $Config;
} ## end sub _init_config

sub _init_logger {
    my $self = shift;

    my $Logger = Log::Tree::->new('zreporter');

    return $Logger;
} ## end sub _init_logger

sub _init_sapi {
    my $self = shift;

    my $ZR = Zabbix::Reporter::->new(
        {
            'config'   => $self->config(),
            'logger'   => $self->logger(),
        }
    );

    return $ZR;
} ## end sub _init_sapi

# your code here ...

no Moose;
__PACKAGE__->meta->make_immutable;

1;

__END__

=head1 NAME

Zabbix::Reporter::Cmd::Command - baseclass for any CLI command

=cut
