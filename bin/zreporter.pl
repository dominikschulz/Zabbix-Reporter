#!/usr/bin/perl
# ABSTRACT: Zabbix::Reporter CLI
# PODNAME: zreporter.pl
use strict;
use warnings;

use Zabbix::Reporter::Cmd;

# All the magic is done using MooseX::App::Cmd, App::Cmd and MooseX::Getopt
my $ZReporter = Zabbix::Reporter::Cmd::->new();
$ZReporter->run();

=head1 NAME

zrerpoter - Zabbix::Reporter CLI

=cut
