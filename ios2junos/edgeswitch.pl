#!/usr/bin/perl -T
use strict;
use warnings;

use English;
use Getopt::Std;
use Net::Netmask;
use Template;

use feature "switch";
no warnings 'experimental::smartmatch';

$OUTPUT_AUTOFLUSH++;

use constant USAGE =>
"$0 [ -h ] [ -g gateway ] [ -l location ] [ -n hostname ]
    [ -t template ] [ -v vlan_config ]
    cisco_config_1 [ cisco_config_2 ] [ ... ]
";

my %config;

# TODO: option to convert uplinks to ge or xe?

getopts( 'hg:l:n:t:v:', \my %opts );
die USAGE if $opts{h};
die USAGE if !@ARGV;

$config{gateway}  = $opts{g} || '##GATEWAY##';
$config{location} = $opts{l} || '##LOCATION##';
$config{hostname} = $opts{n} || '##HOSTNAME##';

my $template = $opts{t} || 'junos.tt';

my @files = @ARGV;

parse_vlanconf($opts{v});

for my $i ( 0 .. $#files ) {
    open ( my $CONFG, '<', $files[$i] ) or die USAGE;

    while ( defined(my $line=<$CONFG>) ) {
        chomp $line;
        if ( $line =~ /^interface (\S+)/ ) {
            parse_interface( { file => $CONFG, switch_num => $i, interface => $1 } );
        }
    }

    close $CONFG;
}

my $tt = Template->new();
$tt->process( $template, \%config ) || die $tt->error();

exit 0;

# TODO:
## chassis/slot/port
## for every slot==0 or slot/2 == 0, set ether-options for uplink port:
##     ge-0/1/0 {
##        ether-options {
##            802.3ad ae0;
##        }
##    }

sub parse_vlanconf {
    my $vlanconf = shift or return;
    my %vlan;

    open ( my $VLANCONF, '<', $vlanconf ) or die "$vlanconf open error";

    while( defined(my $line=<$VLANCONF>) ) {
        chomp $line;

        $line =~ s{ \s* \z }{}xms;  # remove trailing whitespace

        next if $line =~ m{ \A \s* [#] }xms;  # comment lines
        next if $line =~ m{ \A \s* \z }xms;   # blank lines
        next if $line !~ m{ active \z }xms;   # only active interfaces

        next if $line !~ m{ \A \s* (\d+) \s+ (\S+) }xms;

        $config{vlans}{$1} = $2;  # vlan_number{vlan_name}
    }

    close $VLANCONF;

    return;
}

sub parse_interface {
    my ($arg_ref)  = @_;
    my $file       = $arg_ref->{file} or return;
    my $switch_num = $arg_ref->{switch_num};  # might be zero
    my $interface  = $arg_ref->{interface} or return;
    my %ifconfig;

    return if !defined $switch_num;  # zero is ok

    $interface = ios2junos_ifname(
        { switch_num => $switch_num, interface => $interface }
    ) or return;

    # we will not convert any vlan1 interfaces
    return if $interface eq 'vlan1';

    while ( defined(my $line=<$file>) ) {
        chomp $line;

        last if $line =~ /^[!]/;

        for($line) {
            when ( /^ description\s+(\S+.*)/ ) {
                $ifconfig{$interface}{description} = $1;
            }
            when ( /^ switchport access vlan (\d+)/ ) {
                $ifconfig{$interface}{access_vlan} = 'access-' . $config{vlans}{$1};
            }
            when ( /^ switchport voice vlan (\d+)/ ) {
                # destination is not on the interface
                $config{voice_vlan}{$1} = 1;
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
    my ($arg_ref)  = @_;
    my $switch_num = $arg_ref->{switch_num};  # might be zero
    my $interface  = $arg_ref->{interface} or return;

    return if !defined $switch_num;  # zero is ok

    for ($interface) {
        when ( /^FastEthernet(\d+)\/(\d+)/ ) {
            my $type = 'ge';
            my $slot = $1;
            my $port = $2 - 1;
            $interface = "$type-$switch_num/$slot/$port";
        }
        when ( /^GigabitEthernet(\d+)\/(\d+)/ ) {
            my $type = 'xe';
            my $slot = $1;
            my $port = $2 - 1;
            $interface = "$type-$switch_num/$slot/$port";
        }
        default { $interface = lc $interface }
    }

    return $interface;
}
