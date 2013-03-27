#!/usr/bin/perl
# ABSTRACT: Zabbix Reporter CGI Endpoint
# PODNAME: zreporter-web.pl
use strict;
use warnings;

use Plack::Loader;

my $app = Plack::Util::load_psgi('zreporter-web.psgi');
Plack::Loader::->auto->run($app);

=head1 NAME

zreporter-web - Zabbix::Reporter web endpoint (CGI)

=cut
