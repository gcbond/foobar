#!/usr/bin/perl
#Just some useful perl code

#######STACK TRACE###########
use Carp qw(confess);
$SIG{__DIE__} =  \&confess;
$SIG{__WARN__} = \&confess;
#############################

###Print Out Vars Easily#####
use Data::Dumper;
print Dumper(\$myvar);
#############################

##Working with directories###
use Cwd;
my $path = getcwd();
#############################

#####Serialize Variables#####
use Storable;
store $var, $path;
my $newvar = retrieve($path);
#############################

####Directory Transversal####
use File::Find;
#Depth First Search
find sub {
	##MY CODE HERE##
}, $my_starting_directory;
#############################