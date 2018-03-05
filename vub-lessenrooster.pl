#!/usr/bin/env perl

use strict;
use DateTime;
use List::Util qw(first);

my $version = "v1.1";
my $timezone = 'Europe/Brussels';

chomp(my $rc_file = `echo \$HOME/.lessenroosterrc`);
while (!-e $rc_file) {
    open(my $fh, ">", $rc_file) or die "Can't create > $rc_file: $!";
    print $fh "studiejaren:$/";
    print "Enter url of timetable or hit enter when done: $/> ";
    while (chomp(my $url = <STDIN>)) {
        if ($url) {
            print $fh $url.$/;
            print "Enter url of timetable: $/> ";
        } else {
            last;
        }
    }
    print $fh "$/vakken:$/";
    print "Enter courses of interest or hit enter when done: $/> ";
    while (chomp(my $course = <STDIN>)) {
        if ($course) {
            print $fh $course.$/;
            print "Enter courses of interest: $/> ";
        } else {
            last;
        }
    }
    close $fh;
}

open(my $fh, "<", $rc_file) or die "Can't open < $rc_file: $!";

my @rosters;
while (<$fh>) {
    if (/^http/) {
        chomp($_);
        push(@rosters, $_);
    } elsif (/^vakken/) {
        last;
    }
}

my @courses;
while (<$fh>) {
    chomp($_);
    push(@courses, $_);
}
close $fh;

my $week;
sub get_week {
    my $html = $_[0] ? $_[0] : `curl -s "$rosters[0]"`;
    return $1 if $html =~ /<span class='header-6-0-1'>(\d+)</;
}

my $date;
my %months = qw(jan 01 feb 02 mrt 03 apr 04 mei 05 jun 06 jul 07 aug 08 sep 09 okt 10 nov 11 dec 12);
sub get_date {
    my ($day, $month, $year) = ($1, $2, $3) if $_[0] =~ /<span class='header-6-0-3'>(\d\d) (\w\w\w) (\d\d\d\d)</;
    return DateTime->new(
        year => $year,
        month => $months{$month},
        day => $day,
        time_zone  => $timezone,
    );
}

my $export_ics = 0;
if ($ARGV[$export_ics] eq '-e') {
    $export_ics = 1;
}
if ($ARGV[$export_ics] =~ /^(\d+)$/) {
    $week = $1;
} elsif ($ARGV[$export_ics] =~ /^\+(\d+)$/) {
    $week = get_week() + $1;
} elsif ($ARGV[$export_ics] =~ /^\-(\d+)$/) {
    $week = get_week() - $1;
}

my %roster;
my @days = qw(ma di wo do vr za);
my @times = qw(08:00 08:30 09:00 09:30 10:00 10:30 11:00 11:30 12:00 12:30 13:00 13:30 14:00 14:30 15:00 15:30 16:00 16:30 17:00 17:30 18:00);
my @half_hour_intervals;

sub add_roster {
    my $raw = `curl -s "$_[0]"`;
    $week = get_week($raw) unless $week;
    $date = get_date($raw) unless $date;

    my @roster1 = split("row-label-one'>", $raw);

    my @header = split('</td>', shift(@roster1));

    my @cols;
    foreach (@header) {
        if (/colspan='(\d+)'>(\w\w)/) {
            my $i = $1;
            push(@cols, $2) while $i--;
        }
    }

    my @roster2;
    for my $col (0 .. $#cols) {
        foreach (@times) {
            $roster2[$col]{$_};
        }
    }

    while (my $i = shift(@roster1)) {
        my $currcol = 0;
        my @currcols = split("<td +[cs]", $i);
        my $time = substr('0'.$1, -5, 5) if shift(@currcols) =~ /^(\d?\d:\d\d)/;
        for my $j (0 .. $#currcols) {
            if ($currcols[$j] =~ /colspan='1'\s+rowspan='(\d+)'/) {
                my $rowspan = $1;
                my $course = $1 if $currcols[$j] =~ m|<td align='left'>(.+?)</td>|;
                if ($time =~ /30$/) {
                    foreach (@courses) {
                        if ($course =~ /^$_/) {
                            push(@half_hour_intervals, $time);
                            last;
                        }
                    }
                }
                my $type;
                if ($course =~ /(HOC|hoorcollege)/i) {
                    $type = $course =~ /WPO|werkcollege/i ? 'H+W' : 'HOC';
                } elsif ($course =~ /WPO|werkcollege/i) {
                    $type = 'WPO';
                }
                my $class = $1 if $currcols[$j] =~ m|<td align='left'>(\w\..+)</td>|;
                my $timeidx = first {$times[$_] eq $time} 0 .. $#times;
                my $prevslots = 0;
                for my $k (0 .. $j) {
                    ++$prevslots if ($roster2[$k]{$time} && $roster2[$k]{$time}[0] ne $time);
                }
                my $day = $cols[$j - 1 + $prevslots];
                foreach (0 .. $rowspan - 1) {
                    push(@{$roster2[$j + $prevslots]{$times[$timeidx + $_]}}, $time);
                    push(@{$roster2[$j + $prevslots]{$times[$timeidx + $_]}}, $course);
                    push(@{$roster2[$j + $prevslots]{$times[$timeidx + $_]}}, $type);
                    push(@{$roster2[$j + $prevslots]{$times[$timeidx + $_]}}, $class);
                }
            }
        }
    }
    for my $i (0 .. $#cols) {
        foreach my $time (@times) {
            if ($roster2[$i]{$time}[1]) {
                my $include;
                foreach (@courses) {
                    if ($roster2[$i]{$time}[1] =~ /^$_/i) {
                        $include = 1;
                        last;
                    }
                }
                if ($include) {
                    push(@{$roster{$cols[$i]}{$time}}, $roster2[$i]{$time}[1]);
                    push(@{$roster{$cols[$i]}{$time}}, $roster2[$i]{$time}[2]);
                    push(@{$roster{$cols[$i]}{$time}}, $roster2[$i]{$time}[3]);
                }
            }
        }
    }
}

foreach (@rosters) {
    s/weeks=\d*/weeks=$week/;
    add_roster($_);
}

sub export_ics {
    my $ics_file = "VUB lessenrooster week $week.ics";
    open(my $fh, ">", $ics_file) or die "Can't create > $ics_file: $!";
    my $dt = DateTime->now->set_time_zone($timezone);
    my $current_date = $dt->date('');
    my $current_time = $dt->hms('');
    my $class_dt = $date->clone();
    my $day_duration = DateTime::Duration->new(days => 1);

    print $fh "BEGIN:VCALENDAR$/";
    print $fh "METHOD:PUBLISH$/";
    print $fh "VERSION:2.0$/";
    print $fh "PRODID:-//lvsz//vub-lessenrooster $version//EN$/";
    for my $day (@days) {
        my $class_date = $class_dt->date('');
        $class_dt->add($day_duration);
        for my $t (0 .. $#times) {
            my $time = $times[$t];
            for my $i (0 .. $#{$roster{$day}{$time}} / 3) {
                if ($roster{$day}{$time}[$i*3] and $roster{$day}{$times[$t-1]}[$i*3] ne $roster{$day}{$time}[$i*3]) {
                    my $l = 0;
                    ++$l while $roster{$day}{$times[$t+$l]}[$i*3] eq $roster{$day}{$time}[$i*3];
                    my ($start_h, $start_m) = ($1, $2) if $time =~ /(\d\d):(\d\d)/;
                    my ($end_h, $end_m) = ($start_h + int($l / 2), $start_m + 30 * ($l & 1));
                    $end_h += 1, $end_m = 0 if $end_m == 60;
                    print $fh "BEGIN:VEVENT$/";
                    print $fh "UID:VUB-week-$week-$day-$time-$i$/";
                    print $fh "SUMMARY:$roster{$day}{$time}[$i*3]$/";
                    print $fh "LOCATION:$roster{$day}{$time}[$i*3+2]$/";
                    printf $fh "DTSTART;TZID=$timezone:$class_date"."T%02d%02d00$/", $start_h, $start_m;
                    printf $fh "DTEND;TZID=$timezone:$class_date"."T%02d%02d00$/", $end_h, $end_m;
                    print $fh "DTSTAMP:$current_date"."T$current_time"."Z$/";
                    print $fh "END:VEVENT$/";
                }
            }
        }
    }
    print $fh "END:VCALENDAR$/";
    close($fh);
}

export_ics() if $export_ics;

my %conflicts;
printf("   %2s | ", $week);
printf("%20s | ", $_) foreach @days;
print $/.'------+';
print '----------------------+' foreach (0 .. 5);
print $/;
for my $time (@times) {
    if ($time =~ /\d\d:00/ || grep(/^$time$/, @half_hour_intervals)) {
        print $time.' | ';
        for my $day (@days) {
            if ($roster{$day}{$time}[3] && $roster{$day}{$time}[0] ne $roster{$day}{$time}[3]) {
                push(@{$conflicts{$day}}, "conflict on $day @ $time: $roster{$day}{$time}[0] & $roster{$day}{$time}[3]$/");
            }
            printf("%20s | ", substr($roster{$day}{$time}[0], 0, 20));
        }
        print $/.'      | ';
        for my $day (@days) {
            printf("%3s", $roster{$day}{$time}[1]);
            if ($roster{$day}{$time}[3] && $roster{$day}{$time}[0] eq $roster{$day}{$time}[3]) {
                printf("%17s | ", substr(sprintf("%s, %s", $roster{$day}{$time}[2], $roster{$day}{$time}[5]), 0, 16));
            } else {
                printf("%17s | ", substr($roster{$day}{$time}[2], 0, 16));
            }
        }
        print $/.'------+';
        print '----------------------+' foreach (0 .. 5);
        print $/;
    }
}

foreach my $day (@days) {
    print foreach (@{$conflicts{$day}});
}

