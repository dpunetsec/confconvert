#!/usr/bin/perl -T
use strict;
use warnings;

use English;
use Net::Netmask;
use Template;

use feature "switch";
no warnings 'experimental::smartmatch';

$OUTPUT_AUTOFLUSH++;

my %config;

# TODO: parse multiple IOS edge switch configs as a group into one JUNOS config
#       switch number variable gets shoved it interface name
my $switch = 0;

# TODO: option to convert uplinks to ge or xe?

while ( defined(my $line=<>) ) {
    chomp $line;

    for($line) {
        when    ( /^hostname (\S+)/ )               { $config{hostname} = $1 }
        when    ( /^interface (\S+)/ )              { parse_interface($1) }
        when    ( /^ip default-gateway (\S+)/ )     { $config{gateway} = $1 }
        when    ( /^snmp-server location (\S+)/ )   { $config{location} = $1; }
        default { next }
    }
}

my $template = Template->new();

# TODO: use an option to grab the template and output
$template->process( 'junos.tt', \%config ) || die $template->error();

exit 0;

sub parse_interface {
    my $interface = ios2junos_ifname(shift) or return;
    my %ifconfig;

    return if $interface eq 'vlan1';  # we will not convert any vlan1 interfaces

    while ( defined(my $line=<>) ) {
        last if $line =~ /^[!]/;

        for($line) {
            when ( /^ description\s+(\S+.*)/ ) {
                $ifconfig{$interface}{description} = $1;
            }
            when ( /^ switchport access vlan (\d+)/ ) {
                $ifconfig{$interface}{access_vlan} = $1;
            }
            when ( /^ switchport voice vlan (\d+)/ ) {
                $ifconfig{$interface}{voice_vlan} = $1;
            }
            when ( /^ ip address (\S+) (\S+)/ ) {
                $ifconfig{$interface}{address} = $1;
                $ifconfig{$interface}{netmask} = new Net::Netmask($1, $2)->bits;
            }
            when ( /^ shutdown$/ ) {
                $ifconfig{$interface}{shutdown} = 1;
            }
            default { next }
        }
    }

    return if !%ifconfig;
    $ifconfig{$interface}{name} = $interface;
    push @{$config{interfaces}}, $ifconfig{$interface};

    return;
}

sub ios2junos_ifname {
    my $interface = shift or return;
    # XXX: $switch is currently a global var, pass as arg?

    for ($interface) {
        when ( /^FastEthernet(\d+)\/(\d+)/ ) {
            my $type = 'ge';
            my $slot = $1;
            my $port = $2 - 1;
            $interface = "$type-$switch/$slot/$port";
        }
        when ( /^GigabitEthernet(\d+)\/(\d+)/ ) {
            my $type = 'xe';
            my $slot = $1;
            my $port = $2 - 1;
            $interface = "$type-$switch/$slot/$port";
        }
        default { $interface = lc $interface }
    }

    return $interface;
}
