#!/usr/bin/perl
#crontab -e 5 0 * * Sun perl ts3-plex-newsletter.pl

use IO::Socket; 

use strict;
use warnings;

use POSIX qw(strftime);
my $date = strftime "%m/%d", localtime;
#Grab the newest html file, when tautulli server it, it only uses the hash
my @list = `ls -t /opt/tautulli/newsletters`;
$list[0] =~ /[A-Za-z0-9]+\.html/;
my $newsletter = $&;
$newsletter =~ s/\.html//g;

##Address of your tautulli install
my $url = "https://tautulli/newsletter/" . $newsletter;

print "Updating TS3 Channel URL = $url\n";

my $query_address = "127.0.0.1";
my $query_port = 10011;
my $login = "serveradmin";
my $pass = "XXXXXXXX";
my $sid = 1;
my $cid = 6;

my $sock = IO::Socket::INET->new(
      PeerAddr    => $query_address,
      PeerPort    => $query_port,
      Proto       => 'TCP',
      Autoflush   => 1,
      Blocking    => 1,
) or die "Server Failed to Start : $@";

# Login to TS3
print $sock "login $login $pass\n";
print $sock "use sid=$sid\n"; 
print $sock "clientupdate client_nickname=bot\n";

print $sock "channeledit cid=$cid channel_description=[url=$url]Newsletter" . $date . "[/url]\n";

#
sleep(1);

#
close($sock);
