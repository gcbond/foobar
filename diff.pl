#!/usr/bin/perl
# Author: Grant Bond
# Co-Author: Charles Lundblad
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# This program will index a given directory for music files and extract the ID3 tags 
# into an index that you can then sort and parse though.
# The index can then be modified and eventually written to a new path.
# The goal is to create a common structure for your music library
# The structure is EX: Artist/Album/1 - Track.mp3
# The files will be moved from the old source to the new directory.

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

&index();

# runs the main menu
while(1) {
	&menu();
}

#Menu for the user
sub menu {
	print "What would you like to do?\n";
	print "1) Print all music files matching x\n";
	print "2) Remove (from index) all music files matching x\n";
	print "3) Move & Rename indexed files\n";
	print "4) Enter a new source directory to index (or index again)\n";
	print "5) Quit!\n";
	print "Choice: ";

	my $choice = <STDIN>; chomp($choice);
	while($choice !~ m/[1-6]/){
		print "Choice: ";
		$choice = <STDIN>; chomp $choice;
	}
	
	&preprint if $choice eq "1";
	&preremove() if $choice eq "2";
	&prebuild() if $choice eq "3";
	&index() if $choice eq "4";
	exit if $choice eq "5";
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
	&id3();
}

#Extracts ID3 tags from files in @music_list, adding ID3 tags to %tags.
sub id3 {
	my $music_list_length = scalar(@music_list);
	%tags = ();
	print "Retrieving ID3 tags.... this may take awhile!\n";
	my $i = 1;
	foreach (@music_list) {
		print "25% done\n" if $music_list_length / $i == 4;
		print "50% done\n" if $music_list_length / $i == 2;
		print "75% done\n" if $music_list_length / $i == (4/3);
		
		#prints out exactly what is going on, --verbose
		if($verbose){
			print "(" . $i . " of " . $music_list_length . ") Retrieving ID3 tags from: $_\n";
		}
		#SO SLOW! Is there a better way to do this?  Batch job..?
		$tags{"$_"} = $exifTool->ImageInfo("$_", @keep) or warn "*Error getting ID3 tags from $_\n";
		$i++;
	}
	&make_artists();
}

#Builds %artist -> %albums -> %songs -> attributes hash from %tags
sub make_artists {
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
			
			#prints out exactly what is going on, --verbose
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
	my $base = &sanitize(shift, 1);
	my $moveFile;
	my $choice;
	$choice = 0;
	$moveFile = 0;
	
	print "Moving files to $base\n";
	print "Would you like to copy or move your source files?\n";
	print "1) Copy\n";
	print "2) Move\n";
	print "Choice: ";
	
	$choice = <STDIN>; chomp($choice);
	while($choice !~ m/[1-2]/){
		print "Choice: ";
		$choice = <STDIN>; chomp $choice;
	}
	if($choice == 1){
		$moveFile = 0;
	}
	if($choice == 2){
		$moveFile = 1;
	}

	$choice = 0;
	print "\n\nMoving files to $base\n";
	print "Please make one last decision and I won't bother you anymore, please pick one.\n";
	print "1) Overwrite existing files, if any, assume new file is better\n";
	print "2) Overwrite existing file ONLY if source file is a higher bitrate\n";
	print "3) Do not overwrite existing files, only add\n";
	print "Choice: ";
	
	$choice = <STDIN>; chomp($choice);
	while($choice !~ m/[1-3]/){
		print "Choice: ";
		$choice = <STDIN>; chomp $choice;
	}
	
	my $incorrect_ID3_vars = 0;
	
	for my $filepath (keys %artists) {
		my $artistDirectory = &sanitize($filepath);
		make_path("$base/$artistDirectory");
		for my $albumDirectoryPath (keys %{$artist_ref->{$filepath}} ) {
			my $albumDirectory = &sanitize($albumDirectoryPath);
			make_path("$base/$artistDirectory/$albumDirectory");
			for my $song (keys %{$artist_ref->{$filepath}->{$albumDirectoryPath}} ) {
				my $trackTitle = &sanitize($song);
				my $sourceFileLocation = $artists{$filepath}{$albumDirectoryPath}{$song}{"path"};
				my $file_typeetype = $artists{$filepath}{$albumDirectoryPath}{$song}{"filetype"};
				my $trackckno = $artists{$filepath}{$albumDirectoryPath}{$song}{"track"};
				my $new_file_bitrate = $artists{$filepath}{$albumDirectoryPath}{$song}{"bitrate"};
				my $file_typeename;
				if(defined($trackckno)) {
					$file_typeename = $trackckno . " - " . $trackTitle . ".$file_typeetype";
				}
				else {
					$file_typeename = $trackTitle. "." . lc($file_typeetype);
				}
				my $musicfile = "$base/$artistDirectory/$albumDirectory/$file_typeename";
				
				
				if(defined($artistDirectory) && $artistDirectory ne "" && defined($albumDirectory) && $albumDirectory ne "" && defined($file_typeename) && $file_typeename ne ""){
					if(-e $musicfile) {
						if($choice == 1) {
							if($moveFile == 0) {
								
								#prints out exactly what is going on, --verbose
								if($verbose){
									print "Copying $sourceFileLocation --> $base/$artistDirectory/$albumDirectory/$file_typeename\n";
								}		
								copy($sourceFileLocation, "$base/$artistDirectory/$albumDirectory/$file_typeename") or warn "*ERROR could not copy file located at $sourceFileLocation\n";
							}
							else {
							
								#prints out exactly what is going on, --verbose
								if($verbose){
									print "Moving $sourceFileLocation --> $base/$artistDirectory/$albumDirectory/$file_typeename\n";
								}
								move($sourceFileLocation, "$base/$artistDirectory/$albumDirectory/$file_typeename") or warn "*ERROR could not move file located at $sourceFileLocation\n";
							}
						}
						if($choice == 2){
							my $tag = $exifTool->ImageInfo($musicfile, @keep) or warn "*Error getting ID3 tags from $musicfile\n";
							my $AvgBitrate = &num($tag->{"AvgBitrate"});
							my $AudioBitrate = &num($tag->{"AudioBitrate"});
							my $bitrate;

							if(defined($AvgBitrate)){
								$bitrate = $AvgBitrate;
							}
							
							if(defined($AudioBitrate)){
								$bitrate = $AudioBitrate;
							}
							
							if(defined($bitrate) && $new_file_bitrate){
								if($new_file_bitrate > $bitrate){
									
									#prints out exactly what is going on, --verbose
									if($verbose){
										print color 'Bold Green';
										print "New file bitrate of " . $new_file_bitrate . " is > than " . $bitrate . " Replacing\n";
										print color 'reset';
									}
									
									if($moveFile == 0) {
									
										#prints out exactly what is going on, --verbose
										if($verbose){
											print "Copying $sourceFileLocation --> $base/$artistDirectory/$albumDirectory/$file_typeename\n";
										}
										copy($sourceFileLocation, "$base/$artistDirectory/$albumDirectory/$file_typeename") or warn "*ERROR could not copy file located at $sourceFileLocation\n";
									}
									else {
									
										#prints out exactly what is going on, --verbose
										if($verbose){
											print "Moving $sourceFileLocation --> $base/$artistDirectory/$albumDirectory/$file_typeename\n";
										}
										move($sourceFileLocation, "$base/$artistDirectory/$albumDirectory/$file_typeename") or warn "*ERROR could not move file located at $sourceFileLocation\n";
									}
									
								}
								else {
								
									#prints out exactly what is going on, --verbose
									if($verbose){
										print "Old file is of higer or equal bitrate, Skipping.\n";
									}
								}
							}
							#bitrate was not defined, check files size, (used for FLAC files)
							else{
								my $filesize = -s $musicfile;
								my $new_filesize = -s $sourceFileLocation;
								if($new_filesize > $filesize){
									
									#prints out exactly what is going on, --verbose
									if($verbose){
										print "New file size of "  . $new_filesize . " is > than " . $filesize . " Replacing\n";
									}
									
									if($moveFile == 0) {
									
										#prints out exactly what is going on, --verbose
										if($verbose){
											print "Copying $sourceFileLocation --> $base/$artistDirectory/$albumDirectory/$file_typeename\n";
										}
										copy($sourceFileLocation, "$base/$artistDirectory/$albumDirectory/$file_typeename") or warn "*ERROR could not copy file located at $sourceFileLocation\n";
									}
									
									else {
										
										#prints out exactly what is going on, --verbose
										if($verbose){
											print "Moving $sourceFileLocation --> $base/$artistDirectory/$albumDirectory/$file_typeename\n";
										}
										move($sourceFileLocation, "$base/$artistDirectory/$albumDirectory/$file_typeename") or warn "*ERROR could not move file located at $sourceFileLocation\n";
									}
									
								}
								else {
								
									#prints out exactly what is going on, --verbose
									if($verbose){
										print "Old file is of higer or equal bitrate, Skipping.\n";
									}
									
								}
							}
						}
					}
					else {
						if($moveFile == 0) {
						
							#prints out exactly what is going on, --verbose
							if($verbose){
								print "Copying $sourceFileLocation --> $base/$artistDirectory/$albumDirectory/$file_typeename\n";
							}
							copy($sourceFileLocation, "$base/$artistDirectory/$albumDirectory/$file_typeename") or warn "*ERROR could not copy file located at $sourceFileLocation\n";
						}
						else {
							
							#prints out exactly what is going on, --verbose
							if($verbose){
								print "Moving $sourceFileLocation --> $base/$artistDirectory/$albumDirectory/$file_typeename\n";
							}
							move($sourceFileLocation, "$base/$artistDirectory/$albumDirectory/$file_typeename") or warn "*ERROR could not move file located at $sourceFileLocation\n";
						}
					}
				}
				else{
					#ID3 tages were messed up
					$incorrect_ID3_vars++;
				}
			}
		}
	}
	
	print "Number of files with an incorrect directory structure: " . $incorrect_ID3_vars;
	print color 'Bold Green';
	print "\nDone creating and populating directories!\n";
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
	print "Enter directory to move or copy files to, [q] to quit: ";
	my $dir = <STDIN>; chomp($dir);
	$dir =~ s/[\\|\/]$//;
	&build($dir) unless $dir eq "q";
}

sub postbuild {
	my $choice = "";
 	while($choice !~ m/[y|n]/) {
 		print "\n\nRun again? [y/n]> ";
 		$choice = <STDIN>; chomp($choice);
 	}
 	&index() if $choice eq "y";
 	exit if $choice eq "n";
}