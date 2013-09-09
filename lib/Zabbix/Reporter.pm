package Zabbix::Reporter;
# ABSTRACT: Zabbix dashboard

use Moose;
use namespace::autoclean;

use DBI;
use Cache::MemoryCache;

has 'dbh' => (
    'is'      => 'rw',
    'isa'     => 'DBI::db',
    'lazy'    => 1,
    'builder' => '_init_dbh',
);

has 'cache' => (
    'is'      => 'rw',
    'isa'     => 'Cache::Cache',
    'lazy'    => 1,
    'builder' => '_init_cache',
);

has 'priorities' => (
    'is'      => 'rw',
    'isa'     => 'ArrayRef',
    'default' => sub { [] },
);

has 'min_age' => (
    'is'      => 'rw',
    'isa'     => 'Int',
    'default' => 0,
);

has 'warn_unsupported' => (
    'is'      => 'rw',
    'isa'     => 'Bool',
    'default' => 0,
);

has 'warn_unattended' => (
    'is'      => 'rw',
    'isa'     => 'Bool',
    'default' => 0,
);

has 'groups' => (
    'is'      => 'rw',
    'isa'     => 'ArrayRef',
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

=method do

Execute an Stmt in the DB.

=cut
sub do {
    my $self = shift;
    my $query = shift;
    my @args = @_;

    my $sth = $self->dbh()->prepare($query)
        or die("Could not prepare query $query: ".$self->dbh()->errstr);

    $sth->execute(@args)
        or die("Could not execute query $query: ".$self->dbh()->errstr);

    return 1;
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
        $sql .= ' AND t.lastchange < UNIX_TIMESTAMP(NOW() - INTERVAL '.$self->min_age().' MINUTE)';
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
                $row->{'description'} =~ s/\{HOST\.DNS\}/$row->{'host'}/g;
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

  # Check for any unsupported items and prepend a warning as a pseudo trigger
  # if there are some
  if($self->warn_unsupported()) {
    my $unsupported = $self->unsupported_items();
    if($unsupported && ref($unsupported) eq 'ARRAY' && scalar @{$unsupported} > 0) {
      my $row = {
         'severity'     => 'high',
         'host'         => 'Zabbix',
         'description'  => 'Unsupported Items!',
         'lastchange'   => time(),
         'comments'     => 'There are '.(scalar @{$unsupported}).' unsupported items.',
      };
      unshift @{$rows}, $row;
    }
  }

  # Check for any unattended alarms and prepend a warning as a pseudo trigger
  # if there are some
  if($self->warn_unattended()) {
    my $unattended = $self->unattended_alarms();
    if($unattended && ref($unattended) eq 'ARRAY' && scalar @{$unattended} > 0) {
      my $row = {
         'severity'     => 'high',
         'host'         => 'Zabbix',
         'description'  => 'Unattended Alarms!',
         'lastchange'   => time(),
         'comments'     => 'There are '.$unattended->[0].' unattended alarms.',
      };
      unshift @{$rows}, $row;
    }
  }
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

=method enable_actions

Enables all actions.

=cut
sub enable_actions {
  my $self = shift;

  # status = 0 -> action is enabled
  # status = 1 -> action is disabled
  my $sql = <<'EOS';
UPDATE
  actions
SET
  status = 0
WHERE
  status = 1 AND
  eventsource = 0
EOS

  my $rows = $self->do($sql);

  return $rows;
}

=method unsupported_items

Retrieve all unsupported items.

=cut
sub unsupported_items {
    my $self = shift;

    # i.status 3 == Item Error: Not Supported
    my $sql = <<'EOS';
SELECT
    h.host,
    i.key_,
    i.lastclock
FROM
    items i
    JOIN hosts h ON (h.hostid = i.hostid)
WHERE
    i.status = 3
ORDER BY
    i.lastclock DESC
EOS

    my $rows = $self->fetch_n_store($sql,3600);

    return $rows;
}

=method unattended_alarms

Retrieve all unsupported items.

=cut
sub unattended_alarms {
    my $self = shift;
    my $time = shift || 3600;

    my $sql = <<'EOS';
SELECT
    COUNT(t.triggerid) AS alarms
FROM
    triggers AS t
    JOIN functions AS f ON (f.triggerid = t.triggerid)
    JOIN items     AS i ON (i.itemid = f.itemid)
    JOIN hosts     AS h ON (h.hostid = i.hostid)
    JOIN events    AS e ON (e.objectid = t.triggerid)
WHERE
    t.lastchange = e.clock AND
    h.status= 0 AND
    t.value = 1 AND
    t.status = 0 AND
    i.status = 0 AND
    t.lastchange < ( UNIX_TIMESTAMP() - ? ) AND
    e.acknowledged = 0
EOS

    my $rows = $self->fetch_n_store($sql,360,$time);

    return $rows;
}

=method history

Retrieve all triggers.

=cut
sub history {
    my $self = shift;
    my $max_age = shift // 30;
    my $max_num = shift // 100;

    my $sql = <<'EOS';
SELECT
    h.host,
    t.description,
    t.priority,
    e.clock
FROM
    events e
    JOIN triggers t ON (t.triggerid = e.objectid)
    JOIN functions f ON (f.triggerid = t.triggerid)
    JOIN items i ON (i.itemid = f.itemid)
    JOIN hosts h ON (h.hostid = i.hostid)
WHERE
    e.source = 0 AND
    e.value = 1
EOS
  my @args = ();
  if($max_age) {
      $sql .= ' AND e.clock > UNIX_TIMESTAMP(NOW() - INTERVAL ? DAY)';
      push(@args,$max_age);
  }
  $sql .= ' ORDER BY e.clock DESC';
  if($max_num) {
      $sql .= ' LIMIT ?';
      push(@args,$max_num);
  }
  my $rows = $self->fetch_n_store($sql,120,@args);

  # Postprocessing
  if($rows) {
      foreach my $row (@{$rows}) {
          if (defined($row->{'priority'})) {
              $row->{'severity'} = $self->_severity_map()->[$row->{'priority'}];
          }
      }
  }
  return $rows;
}
__PACKAGE__->meta->make_immutable;

1; # End of Zabbix::Reporter

__END__

=head1 NAME

Zabbix::Reporter - Zabbix dashboard

=cut

