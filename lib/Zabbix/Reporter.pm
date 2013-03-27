package Zabbix::Reporter;

use Moose;
use namespace::autoclean;

use DBI;
use Cache::FileCache;

has 'dbh' => (
    'is'    => 'rw',
    'isa'   => 'DBI::db',
    'lazy'  => 1,
    'builder' => '_init_dbh',
);

has 'cache' => (
    'is'    => 'rw',
    'isa'   => 'Cache::Cache',
    'lazy'  => 1,
    'builder' => '_init_cache',
);

has 'priorities' => (
    'is'    => 'rw',
    'isa'   => 'ArrayRef',
    'default' => sub { [] },
);

has 'min_age' => (
    'is'    => 'rw',
    'isa'   => 'Int',
    'default' => 0,
);

has 'groups' => (
    'is'    => 'rw',
    'isa'   => 'ArrayRef',
    'default' => sub { [] },
);

has '_severity_map' => (
    'is'    => 'ro',
    'isa'   => 'ArrayRef',
    'default' => sub {
        [qw(nc information warning average high disaster)],
    }
);

with qw(Config::Yak::RequiredConfig Log::Tree::RequiredLogger);

sub _dsn {
    my $self = shift;
    
    my $hostname = $self->config()->get( 'Zabbix::Reporter::DB::Hostname', { Default => 'localhost', } );
    my $port = $self->config()->get( 'Zabbix::Reporter::DB::Port', { Default => 3306, } );
    my $database = $self->config()->get( 'Zabbix::Reporter::DB::Database', { Default => 'zabbix', } );
    my $username = $self->config()->get( 'Zabbix::Reporter::DB::Username', { Default => 'zabbix', } );
    my $password = $self->config()->get( 'Zabbix::Reporter::DB::Password', { Default => 'zabbix', } );

    my $dsn = 'DBI:mysql:user=' . $username;
    $dsn .= ';password=' . $password;
    $dsn .= ';host=' . $hostname . ';port=' . $port;
    $dsn .= ';database=' . $database;

    return $dsn;
}

sub _init_dbh {
    my $self = shift;

    my $dbh = DBI->connect($self->_dsn());
    
    return $dbh;
}

sub _init_cache {
    my $self = shift;
    
    my $Cache = Cache::FileCache::->new();
    
    return $Cache;
}

=method fetch_n_store

Fetch a result from cache or DB.

=cut
sub fetch_n_store {
    my $self = shift;
    my $query = shift;
    my $timeout = shift;
    my @args = @_;
    
    my $result = $self->cache()->get($query);
    
    if( ! defined($result)) {
        $result = $self->fetch($query,@args);
        $self->cache()->set($query,$result,$timeout);
    }
    
    return $result;
}

=method fetch

Fetch a result directly from DB.

=cut
sub fetch {
    my $self = shift;
    my $query = shift;
    my @args = @_;
    
    my $sth = $self->dbh()->prepare($query)
        or die("Could not prepare query $query: ".$self->dbh()->errstr);
    
    $sth->execute(@args)
        or die("Could not execute query $query: ".$self->dbh()->errstr);
    
    my @result = ();
    
    while(my $ref = $sth->fetchrow_hashref()) {
        push(@result,$ref);
    }
    $sth->finish();
    
    return \@result;
}

=method triggers

Retrieve all matching triggers.

=cut
sub triggers {
    my $self = shift;
    
    my $sql = <<'EOS';
SELECT
    t.priority,
    h.host,
    t.description,
    h.hostid,
    t.triggerid,
    i.itemid,
    i.lastvalue,
    i.lastclock,
    t.lastchange,
    t.value,
    t.comments,
    i.units,
    i.valuemapid,
    d.triggerdepid
FROM
    hosts AS h
    JOIN items AS i ON (h.hostid = i.hostid)
    JOIN functions AS f ON (i.itemid = f.itemid)
    JOIN triggers AS t ON (f.triggerid = t.triggerid)
    LEFT JOIN trigger_depends AS d ON (d.triggerid_down = t.triggerid)
WHERE
    h.status = 0 AND
    t.value = 1 AND
    t.status = 0 AND
    i.status = 0
EOS
    if($self->priorities() && @{$self->priorities()} > 0) {
        $sql .= ' AND t.priority IN ('.join(',',@{$self->priorities()}).')';
    }
    if($self->min_age()) {
        $sql .= ' AND t.lastchange < NOW() - INTERVAL '.$self->min_age().' MINUTE';
    }
    if($self->groups() && @{$self->groups()} > 0) {
        my $sub_sql = "SELECT hostid FROM host_groups WHERE groupid IN (".join(',',@{$self->groups()}).")";
        my $hostids = $self->fetch_n_store($sub_sql,60);
        $sql .= ' AND h.hostid IN ('.join(',',@{$hostids}).')';
    }
    $sql .= ' GROUP BY t.triggerid';
    $sql .= ' ORDER BY t.priority DESC, h.host';
    my $rows = $self->fetch_n_store($sql,60);

    # Post processing
    if($rows) {
        foreach my $row (@{$rows}) {
            if (defined($row->{'priority'})) {
                $row->{'severity'} = $self->_severity_map()->[$row->{'priority'}];
            }
            if (defined($row->{'description'})) {
                $row->{'description'} =~ s/\{HOSTNAME\}/$row->{'host'}/g;
            }
        }
    }
    
    return $rows;
}

__PACKAGE__->meta->make_immutable;

1; # End of Zabbix::Reporter

__END__

=head1 NAME

Zabbix::Reporter - The great new Zabbix::Reporter!

=head1 VERSION

Version 0.01

=head1 SYNOPSIS

Quick summary of what the module does.

Perhaps a little code snippet.

    use Zabbix::Reporter;

    my $foo = Zabbix::Reporter->new();
    ...

=head1 EXPORT

A list of functions that can be exported.  You can delete this section
if you don't export anything, such as for a purely object-oriented module.

=head1 SUBROUTINES/METHODS

=head2 function1

=head1 AUTHOR

Dominik Schulz, C<< <dominik.schulz at gauner.org> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-zabbix-reporter at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Zabbix-Reporter>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Zabbix::Reporter


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Zabbix-Reporter>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Zabbix-Reporter>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Zabbix-Reporter>

=item * Search CPAN

L<http://search.cpan.org/dist/Zabbix-Reporter/>

=back

=head1 ACKNOWLEDGEMENTS

=head1 LICENSE AND COPYRIGHT

Copyright 2012 Dominik Schulz.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.
