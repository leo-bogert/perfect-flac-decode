#!/bin/bash

# See https://github.com/leo-bogert/perfect-flac-encode/blob/master/README.md for Syntax etc.

#################################################################
# Configuration:
#################################################################
wav_singletrack_subdir="Stage1_WAV_Singletracks_From_WAV_Image"
wav_jointest_subdir="Stage2_WAV_Image_Joined_From_WAV_Singletracks"
flac_singletrack_subdir="Stage3_FLAC_Singletracks_Encoded_From_WAV_Singletracks"
decoded_wav_singletrack_subdir="Stage4_WAV_Singletracks_Decoded_From_FLAC_Singletracks"

temp_dirs_to_delete=( "$wav_singletrack_subdir" "$wav_jointest_subdir" "$flac_singletrack_subdir" "$decoded_wav_singletrack_subdir" )

# "Unit tests": Enabling these will damage the said files to test the checksum verification
# Notice that only enabling one at once makes sense because the script will terminate if ANY checksum verification fails :)
# Set to 1 to enable
test_damage_to_input_wav_image=0
test_damage_to_split_wav_singletracks=0
test_damage_to_rejoined_wav_image=0
test_damage_to_flac_singletracks=0
test_damage_to_decoded_flac_singletracks=0
#################################################################
# End of configuration
#################################################################



#################################################################
# Global variables
#################################################################
VERSION=BETA7
#################################################################
# End of global variables
#################################################################


# parameters: $1 = target working directory
set_working_directory_or_die() {
	#echo "Changing working directory to $1..."
	if ! cd "$1" ; then
		echo "Setting working directory failed!" >&2
		exit 1
	fi
}

# parameters:
# $1 = output dir 
ask_to_delete_existing_output_and_temp_dirs_or_die() {
	local output_dir_and_temp_dirs=( "${temp_dirs_to_delete[@]}" "$1" )
	local confirmed=n
	
	for existingdir in "${output_dir_and_temp_dirs[@]}" ; do
		if [ -d "$working_dir_absolute/$existingdir" ]; then
			[ "$confirmed" == "y" ] || read -p "The output and/or temp directories exist already. Delete them and ALL contained files? (y/n)" confirmed
		
			if [ "$confirmed" == "y" ]; then
				rm --preserve-root -rf "$working_dir_absolute/$existingdir"
			else
				echo "Quitting because you want to keep the existing output."
				exit 1
			fi
		fi
	done
}

delete_temp_dirs() {
	echo "Deleting temp directories..."
	for existingdir in "${temp_dirs_to_delete[@]}" ; do
		if [ -d "$working_dir_absolute/$existingdir" ]; then
			if ! rm --preserve-root -rf "$working_dir_absolute/$existingdir" ; then
				echo "Deleting the temp files failed!"
				exit 1
			fi
		fi
	done
}

# parameters:
# $1 = filename of cue/wav/log
check_whether_input_is_accurately_ripped_or_die() {
	echo "Checking EAC LOG for whether AccurateRip reports a perfect rip..."
	
	if ! iconv --from-code utf-16 --to-code utf-8 "$1.log" | grep --quiet "All tracks accurately ripped" ; then
		echo "AccurateRip reported that the disk was not ripped properly - aborting!"
		exit 1
	else
		echo "AccurateRip reports a perfect rip."
	fi
}

# parameters:
# $1 = filename of cue/wav/log
# $2 = "test" or "copy" = which crc to get, EAC provides 2
get_eac_crc_or_die() {
	local filename="$working_dir_absolute/$1.log"

	case $2 in
		test)
			local mode="Test" ;;
		copy)
			local mode="Copy" ;;
		*)
			echo "Invalid mode: $2"
			exit 1
	esac
	
	local regex="^([[:space:]]*)($mode CRC )([0-9A-F]*)([[:space:]]*)\$"
	iconv --from-code utf-16 --to-code utf-8 "$filename" | grep -E "$regex" | sed -r s/"$regex"/\\3/
	
	if  [[ ! $? -eq 0  ]]; then
		echo "Regexp for getting the EAC CRC failed!" >&2
		exit 1
	fi
}

# parameters:
# $1 = filename of cue/wav/log
test_whether_the_two_eac_crcs_match() {
	test_crc=`get_eac_crc_or_die "$1" "test"`
	copy_crc=`get_eac_crc_or_die "$1" "copy"`
	
	echo "Checking whether EAC Test CRC matches EAC Copy CRC..."
	if [ "$test_crc" != "$copy_crc" ] ; then
		echo "EAC Test CRC does not match EAC Copy CRC!" >&2
		exit 1
	fi
	echo "Test and Copy CRC match."
}

# parameters:
# $1 = filename of cue/wav/log
test_eac_crc_or_die() {
	echo "Comparing EAC CRC from EAC LOG to CRC of the input WAV image..."
	
	local input_dir_absolute="$working_dir_absolute"
	local input_wav_image="$input_dir_absolute/$1.wav"
	local expected_crc=`get_eac_crc_or_die "$1" "copy"`
	
	if [ "$test_damage_to_input_wav_image" -eq 1 ]; then 
		echo "Deliberately damaging the input WAV image (original is renamed to *.original) to test the EAC checksum verification ..."
		
		if ! mv --no-clobber "$input_wav_image" "$input_wav_image.original" ; then
			echo "Renaming the original WAV image failed!" >&2
			exit 1
		fi
		
		set_working_directory_or_die "$input_dir_absolute"
		# We replace it with a silent WAV so we don't have to damage the original input image
		if ! shntool gen -l 1:23 -a "$1"; then 
			echo "Generating silent WAV file failed!"
			exit 1
		fi
	fi
	
	echo "Computing CRC of WAV image..."
	local actual_crc=`~/eac-crc "$input_wav_image"` # TODO: as soon as a packaged version is available, use the binary from the package
	echo "Expected EAC CRC: $expected_crc"
	echo "Actual CRC: $actual_crc"
	
	if [ "$actual_crc" != "$expected_crc" ] ; then
		echo "EAC CRC mismatch!" >&2
		exit 1
	fi
	
	echo "EAC CRC of input WAV image is OK."
}

# parameters:
# $1 = filename of cue/wav/log
split_wav_image_to_singletracks_or_die() {
	echo "Splitting WAV image to singletrack WAVs..."
	
	local outputdir_relative="$wav_singletrack_subdir"
	
	set_working_directory_or_die "$working_dir_absolute"
	
	if ! mkdir -p "$outputdir_relative" ; then
		echo "Making $outputdir_relative subdirectory failed!" >&2
		exit 1
	fi
	
	# shntool syntax:
	# -D = print debugging information
	# -P type Specify progress indicator type. dot shows the progress of each operation by displaying a '.' after each 10% step toward completion.
	# -d dir Specify output directory 
	# -o str Specify output file format extension, encoder and/or arguments.  Format is:  "fmt [ext=abc] [encoder [arg1 ... argN (%f = filename)]]"
	# -f file Specifies a file from which to read split point data.  If not given, then split points are read from the terminal.
    # TODO: we can replace special characters in filenames generated from cuesheets with "-m".  Replace Windows/Mac reserved filename characters in filenames.
	# -n fmt Specifies the file count output format.  The default is %02d, which gives two‐digit zero‐padded numbers (01, 02, 03, ...).
	# -t fmt Name output files in user‐specified format based on CUE sheet fields. %t Track title, %n Track number
	# -- = indicates that everything following it is a filename
	
	# TODO: shntool generates a "00 - pregap.wav" for HTOA. Decide what to do about this and check MusicBrainz for what they prefer. Options are: Keep as track 0? Merge with track 1? Shift all tracks by 1?
	
	# Ideas behind parameter decisions:
	# - We specify a different progress indicator so redirecting the script output to a log file will not result in a bloated file"
	# - We do NOT let shntool encode the FLAC files on its own. While testing it has shown that the error messages of FLAC are not printed. Further, because we want this script to be robust, we only use the core features of each tool and not use fancy stuff which they were not primarily designed for.
	# - We split the tracks into a subdirectory so when encoding the files we can just encode "*.wav", we don't need any mechanism for excluding the image WAV
	# - We prefix the filename with the maximal amount of zeroes required to get proper sorting for the maximal possible trackcount on a CD which is 99. We do this because cuetag requires proper sort order of the input files and we just use "*.flac" for finding the input files

	# For making the shntool output more readable we don't use absolute paths but changed the working directory above.
	if ! shntool split -P dot -d "$outputdir_relative" -f "$1.cue" -n %02d -t "%n - %t" -- "$1.wav" ; then
		echo "Splitting WAV image to singletracks failed!" >&2
		exit 1
	fi
	
	local outputdir_absolute="$working_dir_absolute/$outputdir_relative"
	local wav_singletracks=( "$outputdir_absolute"/*.wav )
	set_working_directory_or_die "$outputdir_absolute"
	if [ "$test_damage_to_split_wav_singletracks" -eq 1 ]; then 
		echo "Deliberately damaging a singletrack to test the AccurateRip checksum verification ..."
		
		# accurateripchecksum will ignore trailing garbage in a WAV file and adding leading garbage would make it an invalid WAV which would cause the checksum computation to not even happen
		# Luckily, while reading the manpage of shntool I saw that it is able to generate silent WAV files. So we just replace it with a silent file as "damage".
		if ! shntool gen -l 1:23 ; then 
			echo "Generating silent WAV file failed!"
			exit 1
		fi
		if ! mv "silence.wav" "${wav_singletracks[0]}" ; then
			echo "Overwriting track 0 with silence failed!"
			exit 1
		fi
	fi
	set_working_directory_or_die "$working_dir_absolute"
}

# parameters:
# $1 = filename of cue/wav/logs
# $2 = tracknumber
# $3 = accuraterip version, 1 or 2
get_accuraterip_checksum_of_singletrack_or_die() {
	local filename="$working_dir_absolute/$1.log"
	local tracknumber="$2"
	local accuraterip_version="$3"
	tracknumber=`echo "$tracknumber" | sed 's/^[0]//'`	# remove leading zero (we use 2-digit tracknumbers)
	
	if [ "$accuraterip_version" != "1" -a "$accuraterip_version" != "2" ] ; then
		echo "Invalid AccurateRip version: $accuraterip_version!" >&2
		exit 1
	fi
	
	local regex="^Track( {1,2})($tracknumber)( {2})accurately ripped \\(confidence ([[:digit:]]+)\\)  \\[([0-9A-Fa-f]+)\\]  \\(AR v$accuraterip_version\\)(.*)\$"
	
	iconv --from-code utf-16 --to-code utf-8 "$filename" | grep -E "$regex" | sed -r s/"$regex"/\\5/
}

# parameters:
# $1 = filename with extension
get_tracknumber_of_singletrack() {
	filename="$1"
	regex='^([[:digit:]]{2}) - (.+)([.])(.+)$'
	
	echo "$filename" | grep -E "$regex" | sed -r s/"$regex"/\\1/
}


# parameters:
# $1 = full path of cuesheet
get_total_wav_tracks_without_hiddentrack() {
	cueprint -d '%N' "$1"
}

# parameters:
# $1 = filename of cue/wav/log
test_accuraterip_checksums_of_split_wav_singletracks_or_die() {
	echo "Comparing AccurateRip checksums of split WAV singletracks to AccurateRip checksums from EAC LOG..."
	
	local log_cue_filename="$1"
	local inputdir_wav="$working_dir_absolute/$wav_singletrack_subdir"
	local wav_singletracks=( "$inputdir_wav"/*.wav )
	local hidden_track="$inputdir_wav/00 - pregap.wav"
	local totaltracks=`get_total_wav_tracks_without_hiddentrack "$working_dir_absolute/$log_cue_filename.cue"`
	
	if [ -f "$hidden_track" ] ; then
		echo "Hidden track one audio found."
		local hidden_track_excluded_message=" (excluding hidden track)"
	else
		echo "Hidden track one audio not found."
	fi
	
	echo "Total tracks$hidden_track_excluded_message: $totaltracks"
	for filename in "${wav_singletracks[@]}"; do
		local filename_without_path=`basename "$filename"`
		local tracknumber=`get_tracknumber_of_singletrack "$filename_without_path"`
		
		if  [ "$tracknumber" = "00" ] ; then
			echo "Skipping tracknumber 0 as this is a hidden track, EAC won't list AccurateRip checksums of hidden track one audio"
			continue
 		fi
		
		local expected_checksums[1]=`get_accuraterip_checksum_of_singletrack_or_die "$log_cue_filename" "$tracknumber" "1"`
		local expected_checksums[2]=`get_accuraterip_checksum_of_singletrack_or_die "$log_cue_filename" "$tracknumber" "2"`
		
		if [ "${expected_checksums[2]}" != "" ] ; then
			local accuraterip_version="2"
		else
			if [ "${expected_checksums[1]}" != "" ] ; then
				local accuraterip_version="1"
			else
				echo "AccurateRip checksum not found in LOG!" >&2
				exit 1
			fi
		fi
		
		local expected_checksum="${expected_checksums[$accuraterip_version]^^}" # ^^ = convert to uppercase
		local actual_checksum=`~/accuraterip-checksum --version$accuraterip_version "$filename" "$tracknumber" "$totaltracks"`	#TODO: obtain an ubuntu package for this and use the binary from PATH, not ~
	
		if [ "$actual_checksum" != "$expected_checksum" ]; then
			echo "AccurateRip checksum mismatch for track $tracknumber: expected='$expected_checksum'; actual='$actual_checksum'" >&2
			local do_exit=1	# Don't exit right now so we get an overview of all checksums so we have a better chance of finding out what's wrong
		else
			echo "AccurateRip checksum of track $tracknumber: $actual_checksum, expected $expected_checksum. OK."
		fi
	done
	
	if [ "$do_exit" = "1" ] ; then
		echo "AccurateRip checksum mismatch for at least one track!" >&2
		exit 1
	fi
}

# This genrates a .sha256 file with the SHA256-checksum of the original WAV image. We do not use the EAC CRC from the log because it is non-standard and does not cover the full WAV.
# $1 = filename of wav image (without extension)
# The SHA256 file will be placed in the $wav_jointest_subdir so it can be used for checking the checksum of the joined file
generate_checksum_of_original_wav_image_or_die() {
	echo "Generating checksum of original WAV image ..."
	
	local inputdir_absolute="$working_dir_absolute"
	local original_image_filename="$1.wav"
	local outputdir="$working_dir_absolute/$wav_jointest_subdir"
	local output_sha256="$outputdir/$1.sha256" # TODO: make a global variable or pass this through since we also need it in test_checksum_of_rejoined_wav_image_or_die
	
	if ! mkdir -p "$outputdir" ; then
		echo "Making $outputdir subdirectory failed!" >&2
		exit 1
	fi
	
	set_working_directory_or_die "$inputdir_absolute" # We need to pass a relative filename to sha256 so the output does not contain the absolute path
	if ! sha256sum --binary "$original_image_filename" > "$output_sha256" ; then
		echo "Generating checksum of original WAV image failed!" >&2
		exit 1
	fi
	set_working_directory_or_die "$working_dir_absolute"
}

# parameters:
# $1 = filename of cue/wav/log
test_checksum_of_rejoined_wav_image_or_die() {
	echo "Joining singletrack WAV temporarily for comparing their checksum with the original image's checksum..."	
	
	local inputdir_relative="$wav_singletrack_subdir"
	local outputdir_relative="$wav_jointest_subdir"
	local original_image="$working_dir_absolute/$1.wav"
	local original_image_checksum_file="$working_dir_absolute/$outputdir_relative/$1.sha256"
	local joined_image="$working_dir_absolute/$outputdir_relative/joined.wav"
	
	set_working_directory_or_die "$working_dir_absolute"
	
	# This is not needed: It is generated in generate_checksum_of_original_wav_image_or_die already
	#if ! mkdir -p "$outputdir_relative" ; then
	#	echo "Making $outputdir_relative subdirectory failed!" >&2
	#	exit 1
	#fi
	
	# shntool syntax:
	# -D = print debugging information
	# -P type Specify progress indicator type. dot shows the progress of each operation by displaying a '.' after each 10% step toward completion.
	# -d dir Specify output directory 
	# -- = indicates that everything following it is a filename
	
	# Ideas behind parameter decisions:
	# - We specify a different progress indicator so redirecting the script output to a log file will not result in a bloated file"
	# - We join into a subdirectory because we don't need the joined file afterwards and we can just delete the subdir to get rid of it
	if ! shntool join -P dot -d "$outputdir_relative" -- "$inputdir_relative"/*.wav ; then # TODO: Store the shntool commandline in a variable and write a README to the script's output directory which tells the user that he can re-create the original image using the shntool commandline
		echo "Joining WAV failed!" >&2
		exit 1
	fi
	
	if [ "$test_damage_to_rejoined_wav_image" -eq 1 ]; then 
		echo "Deliberately damaging the joined image to test the checksum verification ..."
		echo "FAIL" >> "$joined_image"
	fi
	
	original_sum=( `cat "$original_image_checksum_file"` )	# it will also print the filename so we split the output by spaces to an array and the first slot will be the actual checksum
	
	echo "Computing checksum of joined WAV image..."
	joined_sum=( `sha256sum --binary "$joined_image"` ) # it will also print the filename so we split the output by spaces to an array and the first slot will be the actual checksum
	
	echo -e "Original checksum: \t\t${original_sum[0]}"
	echo -e "Checksum of joined image:\t${joined_sum[0]}"
	
	if [ "${original_sum[0]}" != "${joined_sum[0]}" ]; then
		echo "Checksum of joined image does not match original checksum!"
		exit 1
	fi
	
	echo "Checksum of joined image OK."
}

encode_wav_singletracks_to_flac_or_die() {
	echo "Encoding singletrack WAVs to FLAC ..."
	
	local inputdir="$working_dir_absolute/$wav_singletrack_subdir"
	local outputdir="$working_dir_absolute/$flac_singletrack_subdir"
	
	if ! mkdir -p "$outputdir" ; then
		echo "Making $outputdir subdirectory failed!" >&2
		exit 1
	fi
	
	# used flac parameters:
	# --silent	Silent mode (do not write runtime encode/decode statistics to stderr)
	# --warnings-as-errors	Treat all warnings as errors (which cause flac to terminate with a non-zero exit code).
	# --output-prefix=string	Prefix  each output file name with the given string.  This can be useful for encoding or decoding files to a different directory. 
	# TODO: do we need this => --keep-foreign-metadata	If  encoding,  save  WAVE  or  AIFF non-audio chunks in FLAC metadata. If decoding, restore any saved non-audio chunks from FLAC metadata when writing the decoded file. 
	# --verify	Verify a correct encoding by decoding the output in parallel and comparing to the original
	# --replay-gain Calculate ReplayGain values and store them as FLAC tags, similar to vorbisgain.  Title gains/peaks will be computed for each input file, and an album gain/peak will be computed for all files. 
	# --best    Highest compression.
	
	# Ideas behind parameter decisions:
	# --silent Without silent, it will print each percent-value from 0 to 100 which would bloat logfiles.
	# --warnings-as-errors	This is clear - we want perfect output.
	# --output-prefix	We use it to put files into a subdirectory. We put them into a subdirectory so we can just use "*.flac" in further processing wtihout the risk of colliding with an eventually generated FLAC image or other files.
	# --keep-foreign-metadata	We assume that it is necessary for being able to decode to bitidentical WAV files. TODO: Validate this.
	# --verify	It is always a good idea to validate the output to make sure that it is good.
	# --replay-gain	Replaygain is generally something you should want. Go read up on it. TODO: We should use EBU-R128 instead, but as of Kubuntu12.04 there seems to be no package which can do it.
	# --best	Because we do PERFECT rips, we only need to do them once in our life and can just invest the time of maximal compression.
	# TODO: proof-read option list again
	
	set_working_directory_or_die "$inputdir"	# We need input filenames to be relative for --output-prefix to work
	if ! flac --silent --warnings-as-errors --output-prefix="$outputdir/" --verify --replay-gain --best *.wav ; then
		echo "Encoding WAV to FLAC singletracks failed!" >&2
		exit 1
	fi
	set_working_directory_or_die "$working_dir_absolute"
	
	local flac_files=( "$outputdir/"*.flac )
	if [ "$test_damage_to_flac_singletracks" -eq 1 ]; then 
		echo "Deliberately damaging a FLAC singletrack to test flac --test verification..."
		echo "FAIL" > "${flac_files[0]}" # TODO: We overwrite the whole file because FLAC won't detect trailing garbage. File a bug report
	fi
}

test_flac_singletracks_or_die() {
	echo "Running flac --test on singletrack FLACs..."
	local inputdir_flac="$working_dir_absolute/$flac_singletrack_subdir"
	
	set_working_directory_or_die "$inputdir_flac"	# We need input filenames to be relative for --output-prefix to work
	local flac_files=( *.flac )
	
	if ! flac --test --silent --warnings-as-errors "${flac_files[@]}"; then
		echo "Testing FLAC singletracks failed!" >&2
		exit 1
	fi
}

test_checksums_of_decoded_flac_singletracks_or_die() {
	echo "Decoding singletrack FLACs to WAVs to validate checksums ..."
	
	local inputdir_wav="$working_dir_absolute/$wav_singletrack_subdir"
	local inputdir_flac="$working_dir_absolute/$flac_singletrack_subdir"
	local outputdir="$working_dir_absolute/$decoded_wav_singletrack_subdir"
	
	if ! mkdir -p "$outputdir" ; then
		echo "Making $outputdir subdirectory failed!" >&2
		exit 1
	fi
	
	set_working_directory_or_die "$inputdir_flac"	# We need input filenames to be relative for --output-prefix to work
	# TODO: do we need this => --keep-foreign-metadata	If  encoding,  save  WAVE  or  AIFF non-audio chunks in FLAC metadata. If decoding, restore any saved non-audio chunks from FLAC metadata when writing the decoded file. 
	if ! flac --decode --silent --warnings-as-errors --output-prefix="$outputdir/"  *.flac ; then
		echo "Decoding FLAC singletracks failed!" >&2
		exit 1
	fi
	set_working_directory_or_die "$working_dir_absolute"
	
	local wav_files=( "$outputdir/"*.wav )
	if [ "$test_damage_to_decoded_flac_singletracks" -eq 1 ]; then 
		echo "Deliberately damaging a decoded WAV singletrack to test checksum verification..."
		echo "FAIL" >> "${wav_files[0]}"
	fi

	echo "Generating checksums of original WAV files..."
	# We do NOT use absolute paths when calling sha256sum to make sure that the checksum file contains relative paths.
	# This is absolutely crucical because when validating the checksums we don't want to accidentiall check the sums of the input files instead of the output files.
	set_working_directory_or_die "$inputdir_wav"
	if ! sha256sum --binary *.wav > "checksums.sha256" ; then
		echo "Generating input checksums failed!" &> 2
		exit 1
	fi
	
	echo "Validating checksums of decoded WAV singletracks ..."
	set_working_directory_or_die "$outputdir"
	if ! sha256sum --check --strict "$inputdir_wav/checksums.sha256" ; then
		echo "Validating checksums of decoded WAV singletracks failed!" >&2
		exit 1
	else
		echo "All checksums OK."
	fi
	set_working_directory_or_die "$working_dir_absolute"
}

# parameters:
# $1 = target subdir
move_output_to_target_dir_or_die() {
	echo "Moving output to output directory..."
	
	local inputdir="$working_dir_absolute/$flac_singletrack_subdir"
	local outputdir="$working_dir_absolute/$1"
	
	if ! mkdir -p "$outputdir" ; then
		echo "Making $outputdir subdirectory failed!" >&2
		exit 1
	fi
	
	if ! mv --no-clobber "$inputdir"/*.flac "$outputdir" ; then
		echo "Moving FLAC files to output dir failed!" >&2
		exit 1
	fi
}

# parameters:
# $1 = filename of CUE/LOG/SHA256
# $2 = target subdirectory
copy_cue_log_sha256_to_target_dir_or_die() {
	echo "Copying CUE, LOG and SHA256 to output directory..."
	
	local input_files=( "$working_dir_absolute/$1.cue" "$working_dir_absolute/$1.log" "$wav_jointest_subdir/$1.sha256" )
	local outputdir="$working_dir_absolute/$2"
	
	# TODO: maybe use different filenames for cue/log?
	
	if ! cp --archive --no-clobber "${input_files[@]}" "$outputdir" ; then
		"Copying CUE, LOG and SHA256 to output directory failed!" >&2
		exit 1;
	fi
}

# parameters:
# $1 = filename of CUE/LOG/SHA256
# $2 = target subdirectory
write_readme_txt_to_target_dir_or_die() {
	# TODO: implement
	# Contents should be:
	# - "Encoded with perfect-flac-encode version $VERSION"
	# - Instructions how to re-join the original WAV image, including the exact same FLAC / shntool commandlines which we use when testing the re-joining the image. (TODO: Maybe write a perfect-flac-decode tool for this?)
	# - A statement which explains why this is a perfect rip.
	
	exit 1
}


main() {
	echo -e "\n\nperfect-flac-encode.sh Version $VERSION running ... "
	echo -e "BETA VERSION - NOT for productive use!\n\n"

	# parameters
	local rip_dir_absolute="$1"
	local input_wav_log_cue_filename="$2"
	local output_dir="$input_wav_log_cue_filename"
	
	echo "Album: $input_wav_log_cue_filename"
	
	# globals
	working_dir_absolute="$rip_dir_absolute"
	set_working_directory_or_die "$working_dir_absolute"
	
	ask_to_delete_existing_output_and_temp_dirs_or_die "$output_dir"	
	check_whether_input_is_accurately_ripped_or_die "$input_wav_log_cue_filename"
	# TODO: maybe do "shntool len" and check the "problems" column
	test_whether_the_two_eac_crcs_match "$input_wav_log_cue_filename"
	test_eac_crc_or_die "$input_wav_log_cue_filename"
	#compress_image_wav_to_image_flac_or_die "$@"	
	split_wav_image_to_singletracks_or_die "$input_wav_log_cue_filename"
	test_accuraterip_checksums_of_split_wav_singletracks_or_die "$input_wav_log_cue_filename"
	generate_checksum_of_original_wav_image_or_die "$input_wav_log_cue_filename"
	test_checksum_of_rejoined_wav_image_or_die "$input_wav_log_cue_filename"
	encode_wav_singletracks_to_flac_or_die
	# TODO: tag FLAC with eac-cue-flac-musicbrainz-pretag
	test_flac_singletracks_or_die
	test_checksums_of_decoded_flac_singletracks_or_die
	move_output_to_target_dir_or_die "$output_dir"
	copy_cue_log_sha256_to_target_dir_or_die "$input_wav_log_cue_filename" "$output_dir"
	# write_readme_txt_to_target_dir_or_die "$input_wav_log_cue_filename" "$output_dir"  # TODO: Enable once it is implemented
	# TODO: produce a perfect-flac-encode logfile and copy to output
	delete_temp_dirs
	
	echo "SUCCESS. Your FLACs are in directory \"$input_wav_log_cue_filename\""
	exit 0 # SUCCESS
}

main "$@"
