#!/usr/bin/perl -w

use strict;
use warnings;
use Getopt::Long;

my ($print, $sudo, $item);

GetOptions (
    "item=s"       => \$item,
    "print"        => \$print,
    "sudo"         => \$sudo,
);

#my $cli             = '/opt/MegaRAID/MegaCli/MegaCli64';
my $cli             = '/usr/local/bin/MegaCli';
if ($sudo) {
    $cli = "/usr/bin/sudo ". $cli;
}
my $zabbix_config   = '/etc/zabbix/zabbix_agent2.conf';
my $zabbix_sender   = '/usr/bin/zabbix_sender';
my $tmp_path        = '/tmp/raid-discovery-zsend-data.tmp';
my %enclosures      = ();
my %adapters        = ();
my %battery_units   = ();
my %physical_drives = ();
my %virtual_drives  = ();

my $adp_count   = `$cli -AdpCount -NoLog`;
# Controller Count: 1.
if ($adp_count =~ m/.*Controller\sCount:\s(\d)\.*/i) {
    $adp_count = $1;
} else {
    print "Didn't find any adapter, check regex or $cli\n";
    exit(1);
}

for (my $adapter = 0; $adapter < $adp_count; $adapter++) {
    my $pd_num = `$cli -pdGetNum -a $adapter -NoLog`;
    # Number of Physical Drives on Adapter 0: 6
    if ($pd_num =~ m/.*Number\sof\sPhysical\sDrives\son\sAdapter\s$adapter:\s(\d+)\n.*/) {
        $pd_num = $1;
        if ($pd_num == 0) {
            print "No physical disks found on adapter $adapter\n";
            next;
        } else {
            $adapters{$adapter} = "{ \"{#ADAPTER_ID}\":\"$adapter\" }";
        }
    }
    my $number_of_lds = `$cli -LDGetNum -a $adapter -NoLog`;
    # Number of Virtual Drives Configured on Adapter 0: 3
    if ($number_of_lds=~ m/.*Number\sof\sVirtual\sDrives\sConfigured\son\sAdapter\s$adapter:\s(\d+)/) {
        $number_of_lds = $1;
        if ($number_of_lds == 0) {
            print "No virtual disks found on adapter $adapter\n";
            next;
        }
        my @vd_list     = `$cli -LDinfo -Lall -a $adapter -NoLog`;
        my $vdrive_id   = -1;
        foreach my $line (@vd_list) {
            if ($line =~ m/^\s*Virtual\sDrive:\s(\d+)\s.*$/) {
                $vdrive_id = $1;
                $virtual_drives{"$adapter$vdrive_id"} = "{ \"{#VDRIVE_ID}\":\"$vdrive_id\", \"{#ADAPTER_ID}\":\"$adapter\" }";
            } else {
                next;
            }
        }
    }
    my $bbu_info = `$cli -AdpBbuCmd -GetBbuStatus -a $adapter -NoLog`;
    if (!($bbu_info =~ m/.*Get BBU Status Failed.*/)) {
        $battery_units{$adapter} = "{ \"{#ADAPTER_ID}\":\"$adapter\" }";
    }

    my @pd_list = `$cli -pdlist -a $adapter -NoLog`;
    my $check_next_line = 0;
    my $position = 'None';
    my $enclosure_id    = -1;
    my $slot = -1;
    # Determine Slot Number for each drive on current enclosure
    foreach my $line (@pd_list) {
        if ($line =~ m/^Enclosure\sDevice\sID:\s(\d+)$/) {
            $enclosure_id       = $1;
            $check_next_line    = 1;
        } elsif ($line =~ m/^\s*Enclosure\sDevice\sID:\sN\/A$/) {
            # This can happen, if embedded raid controller is in use, there are drives and logical disks, but no enclosures
            $enclosure_id       = 2989; # 0xBAD, :( magic hack
            $check_next_line    = 1;
        } elsif ($line =~ m/^\s*Drive's\sposition:\s(.*)$/) {
            $position           = $1;
            $check_next_line    = 1;
        } elsif (($line =~ m/^Slot\sNumber:\s(\d+)$/) && $check_next_line) {
            $slot = $1;
        } elsif ($line =~ m/^Drive\shas\sflagged/) {
            $physical_drives{"$adapter$enclosure_id$slot"} = "{ \"{#ENCLOSURE_ID}\":\"$enclosure_id\", \"{#PDRIVE_ID}\":\"$slot\", \"{#ADAPTER_ID}\":\"$adapter\", \"{#PD_POSITION}\":\"$position\" }";
            $check_next_line    = 0;
            $check_next_line = 0;
            $position = 'None';
            $enclosure_id    = -1;
            $slot = -1;
        } else {
            next;
        }
    }
}

open(ZSEND_FILE,">$tmp_path") or die "Can't open $tmp_path: $!";

my $phd_count = keys %physical_drives;
my $lds_count = keys %virtual_drives;

if (($phd_count != 0) && ($lds_count != 0)) {
    my $i = 1;
    print ZSEND_FILE "- hw.raid.discovery.pdisks { \"data\":[";
    foreach my $drive (keys %physical_drives) {
        if ($i < $phd_count) {
            print ZSEND_FILE "$physical_drives{$drive},";
            $i++;
        } else {
            print ZSEND_FILE "$physical_drives{$drive}]}\n";
        }
    }
    $i = 1;
    print ZSEND_FILE "- hw.raid.discovery.vdisks { \"data\":[";
    foreach my $vdrive (keys %virtual_drives) {
        if ($i < $lds_count) {
            print ZSEND_FILE "$virtual_drives{$vdrive},";
            $i++;
        } else {
            print ZSEND_FILE "$virtual_drives{$vdrive}]}\n";
        }
    }
    $i = 1;
    my $bbu_count = keys %battery_units;
    if ($bbu_count != 0) {
        print ZSEND_FILE "- hw.raid.discovery.bbu { \"data\":[";
            foreach my $bbu (keys %battery_units) {
                if ($i < $bbu_count) {
                    print ZSEND_FILE "$battery_units{$bbu},";
                    $i++;
                } else {
                    print ZSEND_FILE "$battery_units{$bbu}]}\n";
                }
            }
    }
    $i = 1;
    my $adp_count = keys %adapters;
    if ($adp_count != 0) {
        print ZSEND_FILE "- hw.raid.discovery.adapters { \"data\":[";
        foreach my $adapter (keys %adapters) {
            if ($i < $adp_count) {
                print ZSEND_FILE "$adapters{$adapter},";
                $i++;
            } else {
                print ZSEND_FILE "$adapters{$adapter}]}\n";
            }
        }
    }
}
close (ZSEND_FILE) or die "Can't close $tmp_path: $!";
if ($print){
    open (FH, "<$tmp_path") or die "Can't open $tmp_path: $!";
    while (my $line = <FH>) {
         if ($item and $line =~ /^- hw\.raid\.discovery\.$item (.*)/) {
             print ("$1\n");
         }
    }
    close(FH) or die "Can't close $tmp_path: $!";
}
else {
    my @cmd_args = ($zabbix_sender,'-c',$zabbix_config,'-i',$tmp_path);
    system(@cmd_args);
}
