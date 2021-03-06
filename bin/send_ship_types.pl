#!/usr/bin/env perl

use strict;
use warnings;
use DateTime;
use Getopt::Long          (qw(GetOptions));
use List::Util            (qw(first));
use POSIX                  qw( floor );
use Time::HiRes            qw( sleep );
use Try::Tiny;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Games::Lacuna::Client ();

  my $ships_per_fleet = 500;
  my $login_attempts  = 5;
  my $reattempt_wait  = 0.1;

  my %opts = (
    h            => 0,
    v            => 0,
    config       => "lacuna.yml",
    dump         => 0,
    outfile      => 'log/send_ship_type.js',
    sleep        => 1,
    arrival      => "Earliest",
  );

  my $ok = GetOptions(\%opts,
      'config=s',
      'dump',
      'outfile=s',
      'sleep=i',
      'name=s@',
      'type=s@',
      'leave=i',
      'max=i',
      'from=s@',
      'fid=s@',
      'x=i',
      'y=i',
      'star=s',
      'planet=s',
      'star_id=i',
      'planet_id=i',
      'arrival=s',
      'speed=i',
      'combat=i',
      'stealth=i',
      'dry',
      'earliest',
  );

  usage() if !$ok;

  my $json = JSON->new->utf8(1);
  my $of;
  if ($opts{dump}) {
    open($of, ">", "$opts{outfile}") or die "Could not write to $opts{outfile}\n";
  }

  my ($arrival, $current) = parse_time($opts{arrival});
  my $cstr = sprintf("%04d:%02d:%02d:%02d:%02d:%02d",
         $current->{year},
         $current->{month},
         $current->{day},
         $current->{hour},
         $current->{minute},
         $current->{second});
  my $astr = sprintf("%04d:%02d:%02d:%02d:%02d:%02d",
         $arrival->{year},
         $arrival->{month},
         $arrival->{day},
         $arrival->{hour},
         $arrival->{minute},
         $arrival->{second});
  printf "Current time: %s\n", $cstr;
  printf "Arrival time: %s : %s Sec:%d\n",
         $astr,
         $opts{arrival},
         $arrival->{trip_time};

  die "Arrival time can not be set before Current time\n" if ($cstr ge $astr and $arrival->{earliest} == 0);

  usage() if ((!$opts{name} && !$opts{type}) or
             (!$opts{from} && !$opts{fid}) or
             (!$opts{star} && !$opts{planet} && !$opts{star_id} && !$opts{planet_id} && (!$opts{x} && !$opts{y})));

  unless ( $opts{config} and -e $opts{config} ) {
    $opts{config} = eval{
      require File::HomeDir;
      require File::Spec;
      my $dist = File::HomeDir->my_dist_config('Games-Lacuna-Client');
      File::Spec->catfile(
        $dist,
        'login.yml'
      ) if $dist;
    };
    unless ( $opts{config} and -e $opts{config} ) {
      die "Did not provide a config file";
    }
  }

  my $glc = Games::Lacuna::Client->new(
	cfg_file       => $opts{config},
        prompt_captcha => 1,
        rpc_sleep => $opts{sleep},
	 #debug    => 1,
  );

  my $empire = $glc->empire->get_status->{empire};

# reverse hash, to key by name instead of id
  my %colonies = map { $empire->{colonies}{$_}, $_ } keys %{ $empire->{colonies} };

#  die "--from colony '$opts{from}' not found"
#    if !$colonies{$opts{from}};
#XXX Make sure at least one item in @{$opts{from}} is valid
  my $death = 0;
  for my $pname (sort @{$opts{from}}) {
    unless ( grep { $pname eq $_ } keys %colonies ) {
      $death = 1;
      print "$pname is not a valid launcher!\n";
    }
  }
  die "Invalid colonies\n" if $death;

  my $target;
  my $target_name;

# Where are we sending to?

  if ( defined $opts{x} && defined $opts{y} ) {
    $target      = { x => $opts{x}, y => $opts{y} };
    $target_name = "$opts{x},$opts{y}";
  }
  elsif ( defined $opts{star} ) {
    $target      = { star_name => $opts{star} };
    $target_name = $opts{star};
  }
  elsif ( defined $opts{planet_id} ) {
    $target      = { body_id => $opts{planet_id} };
    $target_name = $opts{planet_id};
  }
  elsif ( defined $opts{star_id}) {
    $target      = { star_id => $opts{star_id} };
    $target_name = $opts{star_id};
  }
  elsif ( defined $opts{planet} ) {
    $target      = { body_name => $opts{planet} };
    $target_name = $opts{planet};
  }
  else {
    die "target arguments missing\n";
  }

  my $output;
  $output->{target} = $target;
  $output->{arrival} = $arrival;
  for my $pname (@{$opts{from}}) {
    print "Inspecting $pname $colonies{$pname}\n";
    my $body = $glc->body( id => $colonies{"$pname"});
    die "no body!" unless $body;
    my $buildings = $body->get_buildings->{buildings};

    $output->{$pname}->{pname} = $pname;
    $output->{$pname}->{pid} = $pname;
    $output->{$pname}->{ships} = [];
# Find the first Space Port
    my $space_port_id = first {
      $buildings->{$_}->{name} eq 'Space Port'
    } keys %$buildings;

    my $space_port = $glc->building( id => $space_port_id, type => 'SpacePort' );

    my $fleets = $space_port->get_fleet_for($colonies{$pname}, $target)->{ships};

    print "Total of ", scalar @$fleets, " fleets found.\n";
    my %fleet;
    my $use_count = 0;
    my %skip;
    my %tcnt;

FLEET: for my $fleet ( @$fleets ) {
      next FLEET if $opts{name} && !grep { $fleet->{name} eq $_ } @{$opts{name}};
      next FLEET if $opts{type} && !grep { $fleet->{type} eq $_ } @{$opts{type}};
      next FLEET if $opts{speed}   && $fleet->{speed}   >= $opts{speed};
      next FLEET if $opts{combat}  && $fleet->{combat}  >= $opts{combat};
      next FLEET if $opts{stealth} && $fleet->{stealth} >= $opts{stealth};
      my $key = sprintf("%s:%05d:%05d:%05d:%09d:%s",
                        $fleet->{type},
                        $fleet->{speed},
                        $fleet->{combat},
                        $fleet->{stealth},
                        $fleet->{hold_size},
                        $fleet->{name});
      next FLEET if ($tcnt{$fleet->{type}} && $tcnt{$fleet->{type}} >= $opts{max});
      if ($arrival->{earliest} != 1 and $fleet->{estimated_travel_time} > $arrival->{trip_time}) {
        unless ($skip{"$key"}) {
          print $fleet->{quantity}," of ",$key," would take ",$fleet->{estimated_travel_time}," and we scheduled ", $arrival->{trip_time},".\n";
          $skip{"$key"} = 1;
        }
        next FLEET;
      }
      $use_count += $fleet->{quantity};
      if ($tcnt{$fleet->{type}}) {
        $tcnt{$fleet->{type}} += $fleet->{quantity};
      }
      else {
        $tcnt{$fleet->{type}} = $fleet->{quantity}
      }
      if ($fleet{"$key"}) {
        $fleet{"$key"}->{quantity} += $fleet->{quantity};
      }
      else {
        $fleet{"$key"}->{type} = $fleet->{type};
        $fleet{"$key"}->{speed} = $fleet->{speed};
        $fleet{"$key"}->{combat} = $fleet->{combat};
        $fleet{"$key"}->{stealth} = $fleet->{stealth};
        $fleet{"$key"}->{hold_size} = $fleet->{hold_size};
        $fleet{"$key"}->{name} = $fleet->{name};
        $fleet{"$key"}->{quantity} = $fleet->{quantity};
        $fleet{"$key"}->{estimated_travel_time} = $fleet->{estimated_travel_time};
      }
    }
#End FLEET:
    if ($use_count < 1) {
      print "No ships to send from $pname\n";
      next;
    }
    print "Total of $use_count ships from $pname can be sent.\n";
#TODO
# Instead of grouping by $fleet, keep adding to a fleet array to send multiples thru server call
    for my $key (sort {$fleet{"$a"}->{speed} <=> $fleet{"$b"}->{speed} } keys %fleet) { # sort slowest to fastest being sent
      if ($opts{max}) {
        $fleet{"$key"}->{quantity} = $fleet{"$key"}->{quantity} > $opts{max} ? $opts{max} : $fleet{"$key"}->{quantity};
      }
      if ($opts{dry}) {
        printf "%s would send %4d of %s. Fastest time: %d seconds.\n", $pname, $fleet{"$key"}->{quantity},$key, $fleet{"$key"}->{estimated_travel_time};
        next;
      }
      printf "%s sending %4d of %s. Fastest time: %d seconds.\n", $pname, $fleet{"$key"}->{quantity},$key, $fleet{"$key"}->{estimated_travel_time};
      do {
        my $send_q;
        if ($fleet{"$key"}->{quantity} > $ships_per_fleet) {
          $send_q = $ships_per_fleet;
          $fleet{"$key"}->{quantity} -= $ships_per_fleet;
        }
        else {
          $send_q = $fleet{"$key"}->{quantity};
          $fleet{"$key"}->{quantity} = 0;
        }
        my $sent;
        my $send_arr = [ {
                         type => $fleet{"$key"}->{type},
                         speed => $fleet{"$key"}->{speed},
                         stealth => $fleet{"$key"}->{stealth},
                         combat => $fleet{"$key"}->{combat},
                         name     => $fleet{"$key"}->{name},
                         quantity => $send_q,
                       } ];
        my $ok = eval {
          $sent = $space_port->send_ship_types( $colonies{$pname}, $target, $send_arr, $arrival );
        };
        if ($ok) {
          push @{$output->{$pname}->{ships}}, $send_arr;
        }
        else {
          my $error = $@;
          print "$error\n";
        }
      } while ($fleet{"$key"}->{quantity} > 0);
    }
  }
  if ($opts{dump}) {
    print $of $json->pretty->canonical->encode($output);
    close($of);
  }
exit;

sub parse_time {
  my ($entry) = @_;

  my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = gmtime(time);

  my $current = {
    year   => $year + 1900,
    month  => $mon + 1,
    day    => $mday,
    hour   => $hour,
    minute => $min,
    second => $sec,
    trip_time => 0,
  };

  if ($entry eq "Earliest") {
    $current->{earliest} = 1;
    return ($current, $current);
  }

  my @time_bits = split(":", $entry);

  my $arrival->{second} = 0;
  $arrival->{minute} = pop @time_bits;
  $arrival->{minute} = $min unless ($arrival->{minute});
  $arrival->{hour} = pop @time_bits;
  $arrival->{hour} = $hour unless ($arrival->{hour});
  $arrival->{day} = pop @time_bits;
  $arrival->{day} = $mday unless ($arrival->{day});
  $arrival->{month} = pop @time_bits;
  $arrival->{month} = $mon + 1 unless ($arrival->{month});
  $arrival->{year} = pop @time_bits;
  $arrival->{year} = $year + 1900 unless ($arrival->{year});

  my $arrival_time = DateTime->new(
    year   => $arrival->{year},
    month  => $arrival->{month},
    day    => $arrival->{day},
    hour   => $arrival->{hour},
    minute => $arrival->{minute},
    second => $arrival->{second},
    time_zone => 'UTC',
  );

  $arrival->{trip_time} = $arrival_time->subtract_datetime_absolute(DateTime->now)->seconds;
  $arrival->{earliest} = 0;

  return ($arrival, $current);
}
  

sub usage {
  die <<"END_USAGE";
Usage: $0 lacuna.yml
       --from        NAME  (required, Multiples possible)
       --name   NAME
       --type        TYPE
       --arrival     YYYY:MM:DD:HH:MM (defaults to current Year, Month, Day, Hour, if not entered)
       --max         MAX Number of each type to send per planet
       --leave       LEAVE Number to leave of each type on each planet
       --x           Target COORDINATE
       --y           Target COORDINATE
       --star        Target NAME
       --planet      Target NAME
       --own-star
       --sleep       SECONDS
       --dryrun

Either of --name or --type is required.

--name can be passed multiple times.

--type can be passed multiple times.
It must match the ship's "type", not "type_human", e.g. "scanner", "spy_pod".

If --max is set, this is the maximum number of matching ships that will be
sent. Default behaviour is to send all matching ships.

--from is the colony from which the ships should be sent, multiple possible.

At least one of --star or --planet or --own-star or both --x and --y are
required.

--own-star and --planet cannot be used together.

If --sleep is specified, will wait that number of seconds before sending ships.
Ignored if --seconds is set.

If --dryrun is provided, nothing will be sent, but all actions that WOULD
happen are reported

END_USAGE

}
