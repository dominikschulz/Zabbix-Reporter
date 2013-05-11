package Zabbix::Reporter;
# ABSTRACT: Zabbix dashboard

use Moose;
use namespace::autoclean;

use DBI;
use Cache::MemoryCache;

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
    },
);

has '_event_value_map' => (
   'is'        => 'ro',
   'isa'       => 'ArrayRef',
   'default'   => sub {
      [qw(OK PROBLEM UNKNOWN)],
   },
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
    $dbh->{'mysql_auto_reconnect'} = 1;
    
    return $dbh;
}

sub _init_cache {
    my $self = shift;
    
    my $Cache = Cache::MemoryCache::->new({
      'namespace'          => 'ZabbixReporter',
      'default_expires_in' => 600,
    });
    
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
    
    my $key = $query.join(',',@args);
    
    my $result = $self->cache()->get($key);
    
    if( ! defined($result) ) {
        $result = $self->fetch($query,@args);
        $self->cache()->set($key,$result,$timeout);
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
    my @unacked = ();
    my @acked   = ();
    if($rows) {
        foreach my $row (@{$rows}) {
            if (defined($row->{'priority'})) {
                $row->{'severity'} = $self->_severity_map()->[$row->{'priority'}];
            }
            if (defined($row->{'description'})) {
                $row->{'description'} =~ s/\{HOSTNAME\}/$row->{'host'}/g;
            }
            if (defined($row->{'triggerid'}) && defined($row->{'lastclock'})) {
               my $ack = $self->acks($row->{'triggerid'},$row->{'lastclock'});
               if($ack && ref($ack) eq 'ARRAY' && scalar @{$ack} > 0) {
                  foreach my $field (keys %{$ack->[0]}) {
                     $row->{$field} = $ack->[0]->{$field};
                  }
               }
            }
            # this should be the last post-processing action
            if($row->{'acknowledged'}) {
               push(@acked,$row);
            } else {
               push(@unacked,$row);
            }
        }
    }
    # sort acked triggers to the end
    @{$rows} = (@unacked,@acked);

    # Check for any disabled actions and prepend a warning as a pseudo trigger
    # if there are some
    my $disacts = $self->disabled_actions();
   if($disacts && ref($disacts) eq 'ARRAY' && scalar @{$disacts} > 0) {
      my $row = {
         'severity'     => 'high',
         'host'         => 'Zabbix',
         'description'  => 'Notifications disabled!',
         'lastchange'   => time(),
         'comments'     => 'There are '.(scalar @{$disacts}).' notifications disabled. Please make sure you enable them again in time.',
      };
      unshift @{$rows}, $row;
   }
    
    return $rows;
}

=method acks

Retrieve all matching acknowlegements.

=cut
sub acks {
    my $self = shift;
    my $triggerid = shift;
    my $triggerclock = shift;
    
    my $sql = <<'EOS';
SELECT
   e.eventid,
   e.clock AS eventclock,
   e.value,
   e.acknowledged,
   a.acknowledgeid,
   a.userid,
   a.clock AS ackclock,
   a.message,
   u.alias AS user
FROM
   events AS e
LEFT JOIN
   acknowledges AS a
ON
   e.eventid = a.eventid
LEFT JOIN
   users AS u
ON
   a.userid = u.userid
WHERE
   e.source = 0 AND
   e.object = 0 AND
   e.objectid = ? AND
   e.clock >= ?
ORDER BY
   eventid DESC
LIMIT 1
EOS

    my $rows = $self->fetch_n_store($sql,60,($triggerid,$triggerclock));

    # Post processing
    if($rows) {
        foreach my $row (@{$rows}) {
            if (defined($row->{'value'})) {
                $row->{'status'} = $self->_event_value_map()->[$row->{'value'}];
            }
        }
    }
    
    return $rows;
}

=method disabled_actions

Retrieve all disabled actions.

=cut
sub disabled_actions {
    my $self = shift;
    
    # status = 0 -> action is enabled
    # status = 1 -> action is disabled
    my $sql = <<'EOS';
SELECT
   a.actionid,
   a.name,
   a.status
FROM
   actions AS a
WHERE
   a.eventsource = 0 AND
   status = 1
EOS

    my $rows = $self->fetch_n_store($sql,60);

    return $rows;
}

__PACKAGE__->meta->make_immutable;

1; # End of Zabbix::Reporter

__END__

=head1 NAME

Zabbix::Reporter - Zabbix dashboard

=cut

