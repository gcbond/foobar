#!/usr/bin/perl
# Author: Grant Bond
# Co-Author: Charles Lundblad
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# This program will index a given directory for music files and extract the ID3 tags 
# then it will create an SQL script to insert into your database

use strict;
use warnings;
use File::Find;
use File::Copy;
use File::Path qw(make_path);
use Cwd;
use Image::ExifTool;
use Lingua::EN::Numbers qw(num2en num2en_ordinal);
use Term::ANSIColor;

my $verbose = 0;
if(defined($ARGV[0]) && $ARGV[0] =~ /^--verbose$/ ){
	$verbose = 1;
}

my @music_list;
my %tags; #Each File is Here with a hash of ID3 tags
my $tags_ref = \%tags;
my %artists; #Final Hash o' Hashes.. %Artist -> %Album -> %TrackTitle {Values}
my $artist_ref = \%artists;
my $exifTool = new Image::ExifTool;
my @keep = qw(Year Track Album FileType AudioBitrate Artist Title AvgBitrate Albumartist FileSize);
my $oldSetting = $exifTool->Options(Duplicates => 0);

# runs the main menu
while(1) {
	&menu();
}

#Menu for the user
sub menu {
	print "What would you like to do?\n";
	print "1) Index <directory>\n";
	print "2) Remove (from index) all music files matching x\n";
	print "3) Create SQL script\n";
	print "4) Quit!\n";
	print "Choice: ";

	my $choice = <STDIN>; chomp($choice);
	while($choice !~ m/[1-4]/)
	{
		print "Choice: ";
		$choice = <STDIN>; chomp $choice;
	}
	&index() if $choice eq "1";
	&preremove() if $choice eq "2";
	&prebuild() if $choice eq "3";
	exit if $choice eq "4";
}

#Scans a directory for music files supported by ExifTool adding them to @music_list.
sub index {
	print "Please enter the source directory to index: ";
	my $source_directory = <STDIN>; chomp($source_directory);
	@music_list =();
	find sub {
		my $current_working_file = getcwd() . "/" . $_;
		push(@music_list, $current_working_file) if($_ =~ m/\.(wav|flac|m4a|wma|mp3|mp4|aac|ogg)+$/i);
		
		if($verbose){
			print "Indexing: " . $current_working_file . "\n";
		}
		
	}, $source_directory;
	
	#Extracts ID3 tags from files in @music_list, adding ID3 tags to %tags.
	my $music_list_length = scalar(@music_list);
	%tags = ();
	print "Retrieving ID3 tags.... this may take awhile!\n";
	#print "This tool indexes all your music files.  It knows the Artist, Album, Year, Track, Track #, Bitrate, and File Type.\n";
	#print "When searching the index simple enter a word or FLAC to get flac.  If you want to search a range of bit rates use the format \"> 160\" or \"< 128\"\n";
	#print "Once you decide to write it will create Artist/Album/0Title.mp3 tree for each entry, moving the old files from the source.\n";
	my $i = 1;
	foreach (@music_list) {
		print "25% done\n" if $music_list_length / $i == 4;
		print "50% done\n" if $music_list_length / $i == 2;
		print "75% done\n" if $music_list_length / $i == (4/3);
		#SO SLOW! Is there a better way to do this?  Batch job..?
		
		if($verbose){
			print "Retrieving ID3 tags from: $_\n";
		}
		
		$tags{"$_"} = $exifTool->ImageInfo("$_", @keep) or warn "*Error getting ID3 tags from $_\n";
		$i++;
	}
	
	#Builds %artist -> %albums -> %songs -> attributes hash from %tags
	print "Building index...\n";
	%artists = ();
	my $no_id3_tags = 0;
	my $files_with_lower_bitrate = 0;
	my $duplicate_files = 0;
	for my $filepath (sort keys %tags) {
		my $artist = &sane($tags_ref->{$filepath}->{"Albumartist"});
		my $album = &cap($tags_ref->{$filepath}->{"Album"});
		my $title = &cap($tags_ref->{$filepath}->{"Title"});
		my $file_type = $tags_ref->{$filepath}->{"FileType"};
		my $file_size = $tags_ref->{$filepath}->{"FileSize"};
		my $track = $tags_ref->{$filepath}->{"Track"};
		my $audio_bitrate = $tags_ref->{$filepath}->{"AudioBitrate"};
		my $current_hash_bitrate = 0;
		$artist = &sane($tags_ref->{$filepath}->{"Artist"}) if !defined($artist); #Sometimes ID3 uses AlbumArtists or Artist
		$artist = &doors($artist);
		
		if(defined($artist) && defined($album) && defined($title) && defined($file_type)) {
			$artists{$artist} = &anon_hash() unless $artists{$artist};
			$artists{$artist}{$album} = &anon_hash() unless $artists{$artist}{$album};
			$artists{$artist}{$album}{$title} = &anon_hash() unless $artists{$artist}{$album}{$title};
			
			if($artists{$artist}{$album}{$title}{"filetype"}) {
				#count duplcate files
				$duplicate_files++;
				
				#only update hash is new file has higher bitrate
				if(defined($audio_bitrate) && defined($artists{$artist}{$album}{$title}{"bitrate"})){
				
					my $current_hash_bitrate = $artists{$artist}{$album}{$title}{"bitrate"};
					
					if(&num($audio_bitrate) > $current_hash_bitrate){
						#Increment files with lower bitrate
						$files_with_lower_bitrate++;

						#change the filepath in this hash to the higher quality version
						$artists{$artist}{$album}{$title}{"path"} = $filepath
					}
				}
			}
			
			$artists{$artist}{$album}{$title}{"filetype"} = lc($file_type) unless $artists{$artist}{$album}{$title}{"filetype"};
			$artists{$artist}{$album}{$title}{"path"} = $filepath unless $artists{$artist}{$album}{$title}{"path"};
			$artists{$artist}{$album}{$title}{"filesize"} = $file_size unless $artists{$artist}{$album}{$title}{"filesize"};
			$artists{$artist}{$album}{$title}{"track"} = &track($track) unless $artists{$artist}{$album}{$title}{"track"} || !defined($track);
			if(defined($audio_bitrate)) {
				$artists{$artist}{$album}{$title}{"bitrate"} = &num($audio_bitrate) unless $artists{$artist}{$album}{$title}{"bitrate"};
			}
			else {
				$audio_bitrate = $tags_ref->{$filepath}->{"AvgBitrate"};
				$artists{$artist}{$album}{$title}{"bitrate"} = &num($audio_bitrate) unless $artists{$artist}{$album}{$title}{"bitrate"} || !defined($audio_bitrate);
			}
		}
		else {
			$no_id3_tags++;
			if($verbose){
				print color 'Bold Red';
				print "[Skipping] Error with tags in file: $filepath\n";
				print color 'reset';
			}
			next;
		}
	}
	
	print "\nTotal files checked: " . @music_list . "\n";
	print color 'Bold Red';
	print "Files with Bad/No ID3 Tags: " . $no_id3_tags . "\n";
	print color 'reset';
	print "Files dropped because a better quality version was found: " . $files_with_lower_bitrate . "\n";
	print "Duplicate files not counted: " . $duplicate_files . "\n";
}

sub anon_hash {
	my %temp;
	return \%temp;
}

sub anon_array {
	my @temp;
	return \@temp;
}

#Single digit tracks
sub track {
	my $text = shift;
	return $text if !defined($text);
	$text =~ s/\/.*//g;
	$text =~ s/^0//g;
	return $text;
}

#Replaces &, _, Numbers.
sub sane {
	my $text = shift;
	return $text if !defined($text);
	$text =~ s/&/and/g;
	$text =~ s/_/ /g;
	if($artists{$text}) {
		return &cap($text);
	}
	my $number = $text;
	if($number =~ m/\b\d\b/) {
		$number =~ s/\D//g;
		$number = num2en($number);
		$text =~ s/\b\d\b/$number/g;
	}
	return &cap($text);
}

#Captilize The First Letter
sub cap {
	my $text = shift;
	$text =~ s/([\w']+)/\u\L$1/g if defined($text);
	return $text;
}

sub num {
	my $text = shift;
	$text =~ s/\D//g if defined($text);
	return $text;
}

sub spaces {
	my $text = shift;
	return $text if !defined($text);
	$text =~ s/^\s+//;
	$text =~ s/\s+$//;
	return $text;
}

#The Doors -> Doors, The
sub doors {
	my $text = &spaces(shift);
	return $text if !defined($text);
	if ($text =~ m/^\bThe\b/i) {
		$text =~ s/^\bThe\s//i;
		$text = $text . ", The";
	}
	return $text;
}

#Build will create the file structure and then move the files
sub build {
	my $SQL_file = &spaces(shift);

	print "\n\nGenerating SQL Script: $SQL_file\n";
	open (MYFILE, ">>$SQL_file");
	print MYFILE "-- This script will create the database music_database\n";
	print MYFILE "-- and will also populate the table with your music list\n";
	print MYFILE "CREATE DATABASE `music_database` ;\n";
	print MYFILE "USE music_database;\n";
	
	
	print MYFILE "CREATE TABLE `music_database`.`music_list` (\n";
	print MYFILE "`id` INT NOT NULL AUTO_INCREMENT PRIMARY KEY ,\n";
	print MYFILE "`artist` VARCHAR( 255 ) NOT NULL ,\n";
	print MYFILE "`album` VARCHAR( 255 ) NOT NULL ,\n";
	print MYFILE "`title` VARCHAR( 255 ) NOT NULL ,\n";
	print MYFILE "`track_number` VARCHAR( 255 ) NOT NULL ,\n";
	print MYFILE "`bitrate` INT NOT NULL ,\n";
	print MYFILE "`file_extension` VARCHAR( 10 ) NOT NULL,\n";
	print MYFILE "`path` VARCHAR( 255 ) NOT NULL\n";
	print MYFILE ") ENGINE = MYISAM ;\n";
	
	for my $filepath (keys %artists) {
		my $artistDirectory = &sanitize($filepath);

		for my $albumDirectoryPath (keys %{$artist_ref->{$filepath}} ) {
			my $albumDirectory = &sanitize($albumDirectoryPath);

			for my $song (keys %{$artist_ref->{$filepath}->{$albumDirectoryPath}} ) {
				my $trackTitle = &sanitize($song);
				my $sourceFileLocation = $artists{$filepath}{$albumDirectoryPath}{$song}{"path"};
				my $file_extension = $artists{$filepath}{$albumDirectoryPath}{$song}{"filetype"};
				my $trackckno = $artists{$filepath}{$albumDirectoryPath}{$song}{"track"};
				my $new_file_bitrate = $artists{$filepath}{$albumDirectoryPath}{$song}{"bitrate"};
				my $filename;
				my $filePath;
				
				if(defined($trackckno)) {
					$filename = $trackckno . " - " . $trackTitle . ".$file_extension";
				}
				else {
					$filename = $trackTitle. "." . lc($file_extension);
					$trackckno = "NULL";
				}
				
				$filePath = "$artistDirectory/$albumDirectory/$filename";
				
				
				if(!defined($new_file_bitrate) || $new_file_bitrate == 0) {
					
					$new_file_bitrate = "NULL";
				}

				if($verbose){
					print "Adding $sourceFileLocation --> $SQL_file\n";
				}
				
				if(defined($artistDirectory) && $artistDirectory ne "" && defined($albumDirectory) && $albumDirectory ne "" && defined($trackTitle) && $trackTitle ne ""){
					print MYFILE "INSERT INTO `music_database`.`music_list` (
							`artist` ,
							`album` ,
							`title`,
							`track_number` ,
							`bitrate` ,
							`file_extension`,
							`path`)
							VALUES (\"". $artistDirectory .
							"\", \"" . $albumDirectory .
							"\", \"" . $trackTitle .
							"\", \"" . $trackckno .
							"\", \"" . $new_file_bitrate .
							"\", \"" . $file_extension .
							"\", \"" . $filePath .
							"\");\n";
				}
			}
		}
		
	}
	
	close (MYFILE); 
	print color 'Bold Green';
	print "\nDone creating SQL Script!\n";
	print color 'reset';
	
	&postbuild();
}

sub sanitize {
	my $text = shift;
	if(shift) {
		$text =~ s/[\<|\>|\.|\?|\||\*|\"]//g if defined($text);
	}
	else {
		$text =~ s/[\<|\>|\.|\?|\||\:|\*|\"|\\|\/]//g if defined($text);
	}
	return $text;
}

##If there is a left over key with no values it removes it.
sub cleanartist {
	for my $filepath (keys %artists) {
		for my $albumDirectoryPath (keys %{$artist_ref->{$filepath}} ) {
			for my $thirdkey (keys %{$artist_ref->{$filepath}->{$albumDirectoryPath}} ) {	
				delete $artist_ref->{$filepath}->{$albumDirectoryPath}->{$thirdkey} or warn "Could not remove indexes\n" unless scalar(%{$artist_ref->{$filepath}->{$albumDirectoryPath}->{$thirdkey}} );
			} ## end of $thirdkey
			delete $artist_ref->{$filepath}->{$albumDirectoryPath} or warn "Could not remove indexes\n" unless scalar(%{$artist_ref->{$filepath}->{$albumDirectoryPath}} );
		} ##end of $albumDirectoryPath
		delete $artist_ref->{$filepath} or warn "Could not remove indexes\n" unless scalar(%{$artist_ref->{$filepath}} );
	} ##end of $filepath
}

#Removes entries from index passed to it from &artistaction.
sub remove {
	my $removal_ref = shift;
	my %removal = %$removal_ref;
	for my $filepath (keys %artists) {
		for my $albumDirectoryPath (keys %{$artist_ref->{$filepath}} ) {
			for my $song (keys %{$artist_ref->{$filepath}->{$albumDirectoryPath}} ) {
				my $songs_path = $artist_ref->{$filepath}->{$albumDirectoryPath}->{$song}->{"path"};
				next if !defined($songs_path);
				if($removal{$songs_path}) {
					print "Removing from index $songs_path\n";
					delete $artist_ref->{$filepath}->{$albumDirectoryPath}->{$song} or warn "Could not remove indexes\n";
					my $testsong;
					my $i;
					if($song =~ m/d\d$/) {
						$i = substr($song, length($song)-1, length($song)-1)+1;
						$testsong = substr($song, 0, length($song)-1);
					}
					else {
						$i = 1;
						$testsong = $song . " d";
					}
					while($artist_ref->{$filepath}->{$albumDirectoryPath}->{"$testsong$i"}) {
						my $last = $testsong . ($i-1);
						if (($i - 1) == 0) {
							$artists{$filepath}{$albumDirectoryPath}{$song} = $artists{$filepath}{$albumDirectoryPath}{"$testsong$i"};
						$i++;
						}
						else {
							print "$last setting\n";
							my $ref = $artist_ref->{$filepath}->{$albumDirectoryPath}->{"$testsong$i"};
							$artists{$filepath}{$albumDirectoryPath}{$last} = $ref;
						$i++;
						}
					}
					$i--;
					delete $artists{$filepath}{$albumDirectoryPath}{"$testsong$i"};
				}
			}
		}
	}
	&cleanartist();
}

#High-level sub to interact with %artist can print / remove entries.
sub artistaction {
	my $action = &spaces(shift);
	my $match = shift;
	my $location = shift;
	my $operator = &spaces(shift);
	my $goal = &spaces(shift);
	if($action eq "p") {
		if($operator) {
			my @big = &print($location, $operator, $goal);
			print grep(/kbs/i, @big);
		}
		else {
			print grep(/$match/i, &print($location, 0, 0));
		}
	}
	if($action eq "r") {
		my %path_of_smalls;
		#Search for kbs range
		if($operator) {
			my @big = &print($location, $operator, $goal);
			my @small = grep(/kbs/i, @big);
			print "Removal of files based on kbs\n";
			for(my $i = 0; $i < scalar(@small); $i++) {
				print $i . ".) $small[$i]\n";
			}
			print "Type in numbers seprated by a space to keep or press enter if selection is what you want> ";
			my $choice = <STDIN>; chomp($choice);
			my @selection = split(/\s+/, $choice);
			foreach (@selection) {
				delete $small[$_];
			}
			my @temparray;
			foreach(@small) {
				if(defined($_)) {
					push(@temparray, $_);
				}
			}
			@small = @temparray;
			print "\n\n\nThese files are currently selected for removal\n\n@small";
			$choice = "";
			while ($choice !~ m/[y|n]/) {
				print "Proceed with removal from index? [y/n]> ";
				$choice = <STDIN>; chomp($choice);
			}
			if($choice eq "y") {
				%path_of_smalls = ();
				foreach(@small) {
					my $temppath = $_;
					if ($temppath =~ m/"(.+?)"/) {
		  			$temppath = $1;
					}
					$path_of_smalls{$temppath} = "1";
				}
			}
		}
		else {
			my @big = &print($location, 0, 0);
			my @small = grep(/$match/i, @big);
			for(my $i = 0; $i < scalar(@small); $i++) {
				print $i . ".) $small[$i]\n";
			}
			print "Type in numbers seprated by a space to keep or press enter if selection is what you want> ";
			my $choice = <STDIN>; chomp($choice);
			my @selection = split(/\s+/, $choice);
			foreach (@selection) {
				delete $small[$_];
			}
			my @temparray;
			foreach(@small) {
				if(defined($_)) {
					push(@temparray, $_);
				}
			}
			@small = @temparray;
			print "\n\n\nThese files are currently selected for removal\n\n@small";
			$choice = "";
			while ($choice !~ m/[y|n]/) {
				print "Proceed with removal from index? [y/n]> ";
				$choice = <STDIN>; chomp($choice);
			}
			if($choice eq "y") {
				%path_of_smalls = ();
				foreach(@small) {
					my $temppath = $_;
					if ($temppath =~ m/"(.+?)"/) {
		  			$temppath = $1;
					}
					$path_of_smalls{$temppath} = "1";
				}
			}
		}
		&remove(\%path_of_smalls);
	}
}

#Returns an array for greping/printing/removing
sub print {
	my $inc = shift;
	my $operator = shift;
	my $goal = shift;
	my @toprint = ();
	for my $filepath (keys %artists) {
		for my $albumDirectoryPath (keys %{$artist_ref->{$filepath}} ) {
			for my $thirdkey (keys %{$artist_ref->{$filepath}->{$albumDirectoryPath}}) {
				my @attributes;
				for my $forthkey (keys %{$artist_ref->{$filepath}->{$albumDirectoryPath}->{$thirdkey}}) {
					my $value = $artist_ref->{$filepath}->{$albumDirectoryPath}->{$thirdkey}->{$forthkey};
					if($forthkey eq "bitrate" && $operator) {
						if($operator eq ">") {
							push(@attributes, "$value kbs") if $value > $goal;
						}
						elsif($operator eq "<") {
							push(@attributes, "$value kbs") if $value < $goal;
						}
					}
					else {
						push(@attributes, "$value kbs") if $forthkey eq "bitrate";
					}
					push(@attributes, "$value") if $forthkey eq "filetype";
					
					push(@attributes, "\"$value\"") if $forthkey eq "path" && $inc;
				}
				push(@toprint, "$filepath - $albumDirectoryPath -> $thirdkey\n@attributes\n");
			}
		}
	}
	return @toprint;
}

sub preprint{
	print "You may enter an Artist, Album, Song, File Type, Bitrate (ie < 192 or > 128), or leave blank for all.\n";
	print "Select \> ";
	my $match = <STDIN>; chomp($match);
	if($match =~ m/[\<\>]/) {
		my $schoice = "";
		while($schoice !~ m/[y|n|q]/) {
			print "Include file path as well? [y/n/q to quit]> ";
			$schoice = <STDIN>; chomp($schoice);
		}
		my $operator = $match;
		$operator =~ s/[^\<\>]*//g;
		my $goal = $match;
		$goal =~ s/\D//g;
		&artistaction("p", $match, 1, $operator, $goal) if $schoice eq "y";
		&artistaction("p", $match, 0, $operator, $goal) if $schoice eq "n";
	}
	else {
		my $schoice = "";
		while($schoice !~ m/[y|n|q]/) {
			print "Include file path as well? [y/n/q to quit]> ";
			$schoice = <STDIN>; chomp($schoice);
		}
		&artistaction("p", $match, 1, 0, 0) if $schoice eq "y";
		&artistaction("p", $match, 0, 0, 0) if $schoice eq "n";	
	}
}

sub preremove {
	print "You may enter an Artist, Album, Song, File Type, Bitrate (ie < 192 or > 128), or leave blank for all.\n";
	print "Select [q to quit]\> ";
	my $match = <STDIN>; chomp($match);
	my $operator = $match;
	$operator =~ s/[^\<\>]*//g;
	my $goal = $match;
	$goal =~ s/\D//g;
	&artistaction("r", $match, 1, $operator, $goal) unless $match eq "q";
}
sub prebuild {

	print "Enter the Name of the SQL script: ";
	my $file = <STDIN>; chomp($file);
	&build($file) unless $file eq "q";
}

sub postbuild {
	#$makecopies = 0;
	my $choice = "";
 	while($choice !~ m/[y|n]/) {
 		print "\n\nRun again? [y/n]> ";
 		$choice = <STDIN>; chomp($choice);
 	}
 	&index() if $choice eq "y";
 	exit if $choice eq "n";
}