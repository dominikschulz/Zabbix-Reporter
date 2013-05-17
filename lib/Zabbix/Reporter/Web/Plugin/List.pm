package Zabbix::Reporter::Web::Plugin::List;
# ABSTRACT: List all active triggers

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
use Template;

# extends ...
extends 'Zabbix::Reporter::Web::Plugin';
# has ...
# with ...
# initializers ...
sub _init_fields { return [qw(limit offset refresh)]; }

sub _init_alias { return 'list_triggers'; }

# your code here ...
=method execute

List all active triggers.

=cut
sub execute {
    my $self = shift;
    my $request = shift;
    
    my $triggers = $self->zr()->triggers();
    my $refresh  = $request->{'refresh'} || 30;

    my $body;
    $self->tt()->process(
        'list_triggers.tpl',
        {
            'triggers' => $triggers,
            'refresh'  => $refresh,
        },
        \$body,
    ) or $self->logger()->log( message => 'TT error: '.$self->tt()->error, level => 'warning', );
    
    return [ 200, [
      'Content-Type', 'text/html',
      'Cache-Control', 'max-age='.($refresh+10).', private',
    ], [$body] ];
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;

__END__

=head1 NAME

Zabbix::Reporter::Web::API::Plugin::List - List all active triggers

=cut
