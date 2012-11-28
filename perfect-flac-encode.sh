#!/bin/bash -u
# -u : exit with error upon access of unset variable

################################################################################
# NAME: perfect-flac-encode
# WEBSITE: http://leo.bogert.de/perfect-flac-encode
# MANUAL: See Website.
#
# AUTHOR: Leo Bogert (http://leo.bogert.de)
# DONATIONS: bitcoin:1PZBKLBFnbBA5h1HdKF8PATk3JnAND91yp
# LICENSE:
#     This program is free software: you can redistribute it and/or modify
#     it under the terms of the GNU General Public License as published by
#     the Free Software Foundation, either version 3 of the License, or
#     (at your option) any later version.
# 
#     This program is distributed in the hope that it will be useful,
#     but WITHOUT ANY WARRANTY; without even the implied warranty of
#     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#     GNU General Public License for more details.
# 
#     You should have received a copy of the GNU General Public License
#     along with this program.  If not, see <http://www.gnu.org/licenses/>.
################################################################################


################################################################################
# Configuration:
################################################################################
# Those directories will be created in the output directory
# They MUST NOT contain further subdirectories because the shntool syntax does not allow it the way we use it
declare -A TEMP_DIRS # Attention: We have to explicitely declare the associative array or iteration over the keys will not work!
TEMP_DIRS[WAV_SINGLETRACK_SUBDIR]="Stage1_WAV_Singletracks_From_WAV_Image"
TEMP_DIRS[WAV_JOINTEST_SUBDIR]="Stage2_WAV_Image_Joined_From_WAV_Singletracks"
TEMP_DIRS[FLAC_SINGLETRACK_SUBDIR]="Stage3_FLAC_Singletracks_Encoded_From_WAV_Singletracks"
TEMP_DIRS[DECODED_WAV_SINGLETRACK_SUBDIR]="Stage4_WAV_Singletracks_Decoded_From_FLAC_Singletracks"

# Unit tests:
# Enabling these will damage the said files to test the checksum verification:
# If perfect-flac-encode exits with a "checksum failure" error then, the test succeeded.
# Notice that only enabling one at once makes sense because the script will terminate if ANY checksum verification fails :)
# Set to 1 to enable
declare -A UNIT_TESTS	# Attention: We have to explicitely declare the associative array or iteration over the keys will not work!
UNIT_TESTS["TEST_DAMAGE_TO_INPUT_WAV_IMAGE"]=0
UNIT_TESTS["TEST_DAMAGE_TO_SPLIT_WAV_SINGLETRACKS"]=0
UNIT_TESTS["TEST_DAMAGE_TO_REJOINED_WAV_IMAGE"]=0
UNIT_TESTS["TEST_DAMAGE_TO_FLAC_SINGLETRACKS"]=0
UNIT_TESTS["TEST_DAMAGE_TO_DECODED_FLAC_SINGLETRACKS"]=0
################################################################################
# End of configuration
################################################################################



################################################################################
# Global variables (naming convention: all globals are uppercase)
################################################################################
VERSION="BETA11"
INPUT_DIR_ABSOLUTE=""	# Directory where the input WAV/LOG/CUE are placed. The temp directories will also reside in it.
OUTPUT_DIR_ABSOLUTE=""	# Directory where the output FLACs are placed.
INPUT_CUE_LOG_WAV_BASENAME=""	# Filename of input WAV/LOG/CUE without extension.
INPUT_CUE_ABSOLUTE=""	# Full path of input CUE	# TODO: Use everywhere
INPUT_LOG_ABSOLUTE=""	# Full path of input WAV	# TODO: Use everywhere
INPUT_WAV_ABSOLUTE=""	# Full path of input LOG	# TODO: Use everywhere

# Absolute paths to the temp directories. For documentation see above in the "Configuration" section.
declare -A TEMP_DIRS_ABSOLUTE  # Attention: We have to explicitely declare the associative array or iteration over the keys will not work!
TEMP_DIRS_ABSOLUTE[WAV_SINGLETRACK_SUBDIR]=""
TEMP_DIRS_ABSOLUTE[WAV_JOINTEST_SUBDIR]=""
TEMP_DIRS_ABSOLUTE[FLAC_SINGLETRACK_SUBDIR]=""
TEMP_DIRS_ABSOLUTE[DECODED_WAV_SINGLETRACK_SUBDIR]=""
################################################################################
# End of global variables
################################################################################


# parameters: $1 = target working directory, absolute or relative to current working dir. if not specified, working directory is set to $INPUT_DIR_ABSOLUTE
set_working_directory_or_die() {	# FIXME: review all uses of the function and decide whether setting the WD to input dir makes sense
	#echo "Changing working directory to $dir..."
	if [ $# -eq 0 ] ; then
		local dir="$OUTPUT_DIR_ABSOLUTE" # We default to the output dir so the probability of accidentially damaging something is lower
	else
		local dir="$1"
	fi
	
	if ! cd "$dir" ; then
		echo "Setting working directory failed!" >&2
		exit 1
	fi
}

ask_to_delete_existing_output_and_temp_dirs_or_die() {
	# We only have to delete the output directory since the temp dirs will be subdirectories
	if [ ! -d "$OUTPUT_DIR_ABSOLUTE" ]; then
		return 0
	fi
	
	echo "Output directory: $OUTPUT_DIR_ABSOLUTE"
	
	local confirmed=n
	read -p "The output directory exists already. Delete it and ALL contained files? (y/n)" confirmed
	
	if [ "$confirmed" == "y" ]; then
		rm --preserve-root -rf "$OUTPUT_DIR_ABSOLUTE"
	else
		echo "Quitting because you want to keep the existing output." >&2
		exit 1
	fi
}

delete_temp_dirs() {
	echo "Deleting temp directories..."
	for tempdir in "${TEMP_DIRS_ABSOLUTE[@]}" ; do
		if [ ! -d "$tempdir" ]; then
			continue
		fi
		
		if ! rm --preserve-root -rf "$tempdir" ; then
			echo "Deleting the temp files failed!" >&2
			exit 1
		fi	
	done
}

create_directories_or_die() {
	local output_dir_and_temp_dirs=( "$OUTPUT_DIR_ABSOLUTE" "${TEMP_DIRS_ABSOLUTE[@]}" )
	
	echo "Creating output and temp directories..."
	for dir in "${output_dir_and_temp_dirs[@]}" ; do
		if [ -d "$dir" ]; then
			echo "Dir exists already: $dir" >&2
			exit 1
		fi
		
		if ! mkdir -p "$dir" ; then
			echo "Making directory \"$dir\" in input directory failed!" >&2
			exit 1
		fi
	done
}

check_whether_input_is_accurately_ripped_or_die() {
	echo "Checking EAC LOG for whether AccurateRip reports a perfect rip..."
	
	if ! iconv --from-code utf-16 --to-code utf-8 "$INPUT_LOG_ABSOLUTE" | grep --quiet "All tracks accurately ripped" ; then
		echo "AccurateRip reported that the disk was not ripped properly - aborting!"
		exit 1
	else
		echo "AccurateRip reports a perfect rip."
	fi
}

# Uses "shntool len" to check for any of the following problems with the input WAV:
# - Data is not CD quality
# - Data is not cut on a sector boundary
# - Data is too short to be burned
# - Header is not canonical
# - Contains extra RIFF chunks
# - Contains an ID3v2 header
# - Audio data is not block‐aligned
# - Header is inconsistent about data size and/or file size
# - File is truncated
# - File has junk appended to it
check_shntool_wav_problem_diagnosis_or_die() {
	echo "Using 'shntool len' to check the input WAV image for quality and file format problems..."
	
    #       length         expanded size                 cdr         WAVE        problems       fmt         ratio         filename
	#       54:04.55       572371004         B           ---         --          -----          wav         1.0000        Paul Weller - 1994 - Wild Wood.wav"
	# ^ \s*    \S*    \s*     \S*     \s*   \S*   \s*   (\S*)  \s*  (\S*)  \s*   (\S*)   \s*    \S*    \s*    \S*    \s*    (.*)$
	
	local regex="^\s*\S*\s*\S*\s*\S*\s*(\S*)\s*(\S*)\s*(\S*)\s*\S*\s*\S*\s*(.*)$"
	
	local len_output=$(shntool len -c -t "$INPUT_WAV_ABSOLUTE" | grep -E "$regex")

	if  [[ ! $? -eq 0  ]]; then
		echo "Regexp for getting the 'shntool len' output failed!" >&2
		exit 1
	fi
	
	local cdr_column=$(echo "$len_output" | sed -r s/"$regex"/\\1/)
	local wave_column=$(echo "$len_output" | sed -r s/"$regex"/\\2/)
	local problems_column=$(echo "$len_output" | sed -r s/"$regex"/\\3/)
	
	if [ "$cdr_column" != "---" ] ; then
		echo "CD-quality column of 'shntool len' indicates problems: $cdr_column" >&2
		exit 1
	fi
	
	if [ "$wave_column" != "--" ] ; then
		echo "WAVE column of 'shntool len' shows problems: $wave_column" >&2
		exit 1
	fi
	
	if [ "$problems_column" != "-----" ] ; then
		echo "Problems column of 'shntool len' shows problems: $problems_column" >&2
		exit 1
	fi
}

# parameters:
# $1 = path of EAC LOG
# $2 = "test" or "copy" = which crc to get, EAC provides 2
get_eac_crc_or_die() {
	local eac_log_path="$1"

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
	iconv --from-code utf-16 --to-code utf-8 "$eac_log_path" | grep -E "$regex" | sed -r s/"$regex"/\\3/
	
	if  [[ ! $? -eq 0  ]]; then
		echo "Regexp for getting the EAC CRC failed!" >&2
		exit 1
	fi
}

test_whether_the_two_eac_crcs_match() {
	local test_crc=`get_eac_crc_or_die "$INPUT_LOG_ABSOLUTE" "test"`
	local copy_crc=`get_eac_crc_or_die "$INPUT_LOG_ABSOLUTE" "copy"`
	
	echo "Checking whether EAC Test CRC matches EAC Copy CRC..."
	if [ "$test_crc" != "$copy_crc" ] ; then
		echo "EAC Test CRC does not match EAC Copy CRC!" >&2
		exit 1
	fi
	echo "Test and Copy CRC match."
}

test_eac_crc_or_die() {
	echo "Comparing EAC CRC from EAC LOG to CRC of the input WAV image..."
	
	if [ ${UNIT_TESTS["TEST_DAMAGE_TO_INPUT_WAV_IMAGE"]} -eq 1 ]; then 
		echo "Deliberately damaging the input WAV image (original is renamed to *.original) to test the EAC checksum verification ..."
		
		if ! mv --no-clobber "$INPUT_WAV_ABSOLUTE" "$INPUT_WAV_ABSOLUTE.original" ; then
			echo "Renaming the original WAV image failed!" >&2
			exit 1
		fi
		
		local input_wav_without_extension_absolute=$(basename "$INPUT_WAV_ABSOLUTE" ".wav")
		# We replace it with a silent WAV so we don't have to damage the original input image
		if ! shntool gen -l 1:23 -a "$input_wav_without_extension_absolute"; then 	# .wav must not be in -a
			echo "Generating silent WAV file failed!"
			exit 1
		fi
	fi
	
	local expected_crc=`get_eac_crc_or_die "$INPUT_LOG_ABSOLUTE" "copy"`
	
	echo "Computing CRC of WAV image..."
	local actual_crc=`~/eac-crc "$INPUT_WAV_ABSOLUTE"` # TODO: as soon as a packaged version is available, use the binary from the package
	echo "Expected EAC CRC: $expected_crc"
	echo "Actual CRC: $actual_crc"
	
	if [ "$actual_crc" != "$expected_crc" ] ; then
		echo "EAC CRC mismatch!" >&2
		exit 1
	fi
	
	echo "EAC CRC of input WAV image is OK."
}

split_wav_image_to_singletracks_or_die() {
	echo "Splitting WAV image to singletrack WAVs..."
	
	local wav_singletracks_dir_absolute="$INPUT_DIR_ABSOLUTE/${TEMP_DIRS[WAV_SINGLETRACK_SUBDIR]}"
	
	# shntool syntax:
	# -P type Specify progress indicator type. dot shows the progress of each operation by displaying a '.' after each 10% step toward completion.
	# -d dir Specify output directory 
	# -f file Specifies a file from which to read split point data.  If not given, then split points are read from the terminal.
	# -m str Specifies  a  character  manipulation  string for filenames generated from CUE sheets.  
	# -n fmt Specifies the file count output format.  The default is %02d, which gives two‐digit zero‐padded numbers (01, 02, 03, ...).
	# -t fmt Name output files in user‐specified format based on CUE sheet fields. %t Track title, %n Track number
	# -- = indicates that everything following it is a filename
	
	# TODO: ask someone to proof read options. i did proof read them again already.
	# TODO: shntool generates a "00 - pregap.wav" for HTOA. Decide what to do about this and check MusicBrainz for what they prefer. Options are: Keep as track 0? Merge with track 1? Shift all tracks by 1?
	
	# Ideas behind parameter decisions:
	# - We specify a different progress indicator so redirecting the script output to a log file will not result in a bloated file"
	# - We do NOT let shntool encode the FLAC files on its own. While testing it has shown that the error messages of FLAC are not printed. Further, because we want this script to be robust, we only use the core features of each tool and not use fancy stuff which they were not primarily designed for.
	# - We split the tracks into a subdirectory so when encoding the files we can just encode "*.wav", we don't need any mechanism for excluding the image WAV
	# - We replace Windows' reserved filename characters with "_". We do this because we recommend MusicBrainz Picard for tagging and it does the same. List of reserved characters was taken from http://msdn.microsoft.com/en-us/library/windows/desktop/aa365247%28v=vs.85%29.aspx
	# - We prefix the filename with the maximal amount of zeroes required to get proper sorting for the maximal possible trackcount on a CD which is 99. We do this because cuetag requires proper sort order of the input files and we just use "*.flac" for finding the input files

	# For making the shntool output more readable we don't use absolute paths but changed the working directory
	set_working_directory_or_die
	if ! shntool split -P dot -d "${TEMP_DIRS[WAV_SINGLETRACK_SUBDIR]}" -f "$INPUT_CUE_LOG_WAV_BASENAME.cue" -m '<_>_:_"_/_\_|_?_*_' -n %02d -t "%n - %t" -- "$INPUT_CUE_LOG_WAV_BASENAME.wav" ; then
		echo "Splitting WAV image to singletracks failed!" >&2
		exit 1
	fi
	
	if [ ${UNIT_TESTS["TEST_DAMAGE_TO_SPLIT_WAV_SINGLETRACKS"]} -eq 1 ]; then 
		echo "Deliberately damaging a singletrack to test the AccurateRip checksum verification ..."
		
		local wav_singletracks=( "$wav_singletracks_dir_absolute"/*.wav )
		
		# accurateripchecksum will ignore trailing garbage in a WAV file and adding leading garbage would make it an invalid WAV which would cause the checksum computation to not even happen
		# Luckily, while reading the manpage of shntool I saw that it is able to generate silent WAV files. So we just replace it with a silent file as "damage":
		set_working_directory_or_die "$wav_singletracks_dir_absolute"
		if ! shntool gen -l 1:23 ; then 
			echo "Generating silent WAV file failed!"
			exit 1
		fi
		if ! mv "silence.wav" "${wav_singletracks[0]}" ; then
			echo "Overwriting track 0 with silence failed!"
			exit 1
		fi
		set_working_directory_or_die
	fi
}

# parameters:
# $1 = tracknumber
# $2 = accuraterip version, 1 or 2
get_accuraterip_checksum_of_singletrack_or_die() {
	local tracknumber="$1"
	local accuraterip_version="$2"
	tracknumber=`echo "$tracknumber" | sed 's/^[0]//'`	# remove leading zero (we use 2-digit tracknumbers)
	
	if [ "$accuraterip_version" != "1" -a "$accuraterip_version" != "2" ] ; then
		echo "Invalid AccurateRip version: $accuraterip_version!" >&2
		exit 1
	fi
	
	local regex="^Track( {1,2})($tracknumber)( {2})accurately ripped \\(confidence ([[:digit:]]+)\\)  \\[([0-9A-Fa-f]+)\\]  \\(AR v$accuraterip_version\\)(.*)\$"
	
	iconv --from-code utf-16 --to-code utf-8 "$INPUT_LOG_ABSOLUTE" | grep -E "$regex" | sed -r s/"$regex"/\\5/
}

# parameters:
# $1 = filename with extension
get_tracknumber_of_singletrack() {
	local filename="$1"
	local regex='^([[:digit:]]{2}) - (.+)([.])(.+)$'
	
	echo "$filename" | grep -E "$regex" | sed -r s/"$regex"/\\1/
}


# parameters:
# $1 = full path of cuesheet
get_total_tracks_without_hiddentrack() {
	cueprint -d '%N' "$1"
}

test_accuraterip_checksums_of_split_wav_singletracks_or_die() {
	echo "Comparing AccurateRip checksums of split WAV singletracks to AccurateRip checksums from EAC LOG..."
	
	local inputdir_wav="$INPUT_DIR_ABSOLUTE/${TEMP_DIRS[WAV_SINGLETRACK_SUBDIR]}"
	local wav_singletracks=( "$inputdir_wav"/*.wav )
	local hidden_track="$inputdir_wav/00 - pregap.wav"
	local totaltracks=`get_total_tracks_without_hiddentrack "$INPUT_CUE_ABSOLUTE"`
	
	if [ -f "$hidden_track" ] ; then
		echo "Hidden track one audio found."
		local hidden_track_excluded_message=" (excluding hidden track)"
		
		# TODO: evaluate what musicbrainz says about joined hidden track vs hidden track as track0
		#shntool join "$inputdir_wav/00 - pregap.wav" "$inputdir_wav/01"*.wav
		#mv "joined.wav" "$inputdir_wav/01"*.wav
	else
		echo "Hidden track one audio not found."
		local hidden_track_excluded_message=""
	fi
	
	local do_exit="0"
	echo "Total tracks$hidden_track_excluded_message: $totaltracks"
	for filename in "${wav_singletracks[@]}"; do
		local filename_without_path=`basename "$filename"`
		local tracknumber=`get_tracknumber_of_singletrack "$filename_without_path"`
		
		if  [ "$tracknumber" = "00" ] ; then
			echo "Skipping tracknumber 0 as this is a hidden track, EAC won't list AccurateRip checksums of hidden track one audio"
			continue
 		fi
		
		local expected_checksums[1]=`get_accuraterip_checksum_of_singletrack_or_die "$tracknumber" "1"`
		local expected_checksums[2]=`get_accuraterip_checksum_of_singletrack_or_die "$tracknumber" "2"`
		
		if [ "${expected_checksums[2]}" != "" ] ; then
			local accuraterip_version="2"
		elif [ "${expected_checksums[1]}" != "" ] ; then
			local accuraterip_version="1"
		else
			echo "AccurateRip checksum not found in LOG!" >&2
			exit 1
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
# The SHA256 file will be placed in the ${TEMP_DIRS[WAV_JOINTEST_SUBDIR]} so it can be used for checking the checksum of the joined file
generate_checksum_of_original_wav_image_or_die() {
	echo "Generating checksum of original WAV image ..."

	local original_image_filename="$INPUT_CUE_LOG_WAV_BASENAME.wav"
	local output_sha256="$INPUT_DIR_ABSOLUTE/${TEMP_DIRS[WAV_JOINTEST_SUBDIR]}/$INPUT_CUE_LOG_WAV_BASENAME.sha256" # TODO: make a global variable or pass this through since we also need it in test_checksum_of_rejoined_wav_image_or_die
	
	set_working_directory_or_die # We need to pass a relative filename to sha256 so the output does not contain the absolute path
	if ! sha256sum --binary "$original_image_filename" > "$output_sha256" ; then
		echo "Generating checksum of original WAV image failed!" >&2
		exit 1
	fi
}

test_checksum_of_rejoined_wav_image_or_die() {
	echo "Joining singletrack WAVs temporarily for comparing their checksum with the original image's checksum..."
	
	local inputdir_relative="${TEMP_DIRS[WAV_SINGLETRACK_SUBDIR]}"
	local outputdir_relative="${TEMP_DIRS[WAV_JOINTEST_SUBDIR]}"
	local original_image_checksum_file_absolute="$INPUT_DIR_ABSOLUTE/$outputdir_relative/$INPUT_CUE_LOG_WAV_BASENAME.sha256"
	local joined_image_absolute="$INPUT_DIR_ABSOLUTE/$outputdir_relative/joined.wav"

	# shntool syntax:
	# -D = print debugging information
	# -P type Specify progress indicator type. dot shows the progress of each operation by displaying a '.' after each 10% step toward completion.
	# -d dir Specify output directory 
	# -- = indicates that everything following it is a filename
	
	# Ideas behind parameter decisions:
	# - We specify a different progress indicator so redirecting the script output to a log file will not result in a bloated file"
	# - We join into a subdirectory because we don't need the joined file afterwards and we can just delete the subdir to get rid of it
	set_working_directory_or_die
	if ! shntool join -P dot -d "$outputdir_relative" -- "$inputdir_relative"/*.wav ; then 
		echo "Joining WAV failed!" >&2
		exit 1
	fi
	
	if [ ${UNIT_TESTS["TEST_DAMAGE_TO_REJOINED_WAV_IMAGE"]} -eq 1 ]; then 
		echo "Deliberately damaging the joined image to test the checksum verification ..."
		echo "FAIL" >> "$joined_image_absolute"
	fi
	
	local original_sum=( `cat "$original_image_checksum_file_absolute"` )	# it will also print the filename so we split the output by spaces to an array and the first slot will be the actual checksum
	
	echo "Computing checksum of joined WAV image..."
	local joined_sum=( `sha256sum --binary "$joined_image_absolute"` ) # it will also print the filename so we split the output by spaces to an array and the first slot will be the actual checksum
	
	echo -e "Original checksum: \t\t${original_sum[0]}"
	echo -e "Checksum of joined image:\t${joined_sum[0]}"
	
	# TODO: make sure the checksum strings are not empty
	
	if [ "${original_sum[0]}" != "${joined_sum[0]}" ]; then
		echo "Checksum of joined image does not match original checksum!"
		exit 1
	fi
	
	echo "Checksum of joined image OK."
}

encode_wav_singletracks_to_flac_or_die() {
	echo "Encoding singletrack WAVs to FLAC ..."
	
	local inputdir="$INPUT_DIR_ABSOLUTE/${TEMP_DIRS[WAV_SINGLETRACK_SUBDIR]}"
	local outputdir="$INPUT_DIR_ABSOLUTE/${TEMP_DIRS[FLAC_SINGLETRACK_SUBDIR]}"
	
	# used flac parameters:
	# --silent	Silent mode (do not write runtime encode/decode statistics to stderr)
	# --warnings-as-errors	Treat all warnings as errors (which cause flac to terminate with a non-zero exit code).
	# --output-prefix=string	Prefix  each output file name with the given string.  This can be useful for encoding or decoding files to a different directory. 
	# --verify	Verify a correct encoding by decoding the output in parallel and comparing to the original
	# --replay-gain Calculate ReplayGain values and store them as FLAC tags, similar to vorbisgain.  Title gains/peaks will be computed for each input file, and an album gain/peak will be computed for all files. 
	# --best    Highest compression.
	
	# Ideas behind parameter decisions:
	# --silent Without silent, it will print each percent-value from 0 to 100 which would bloat logfiles.
	# --warnings-as-errors	This is clear - we want perfect output.
	# --output-prefix	We use it to put files into a subdirectory. We put them into a subdirectory so we can just use "*.flac" in further processing wtihout the risk of colliding with an eventually generated FLAC image or other files.
	# --verify	It is always a good idea to validate the output to make sure that it is good.
	# --replay-gain	Replaygain is generally something you should want. Go read up on it. TODO: We should use EBU-R128 instead, but as of Kubuntu12.04 there seems to be no package which can do it.
	# --best	Because we do PERFECT rips, we only need to do them once in our life and can just invest the time of maximal compression.
	# TODO: proof-read option list again
	
	set_working_directory_or_die "$inputdir"	# We need input filenames to be relative for --output-prefix to work
	if ! flac --silent --warnings-as-errors --output-prefix="$outputdir/" --verify --replay-gain --best *.wav ; then
		echo "Encoding WAV to FLAC singletracks failed!" >&2
		exit 1
	fi
	set_working_directory_or_die
	
	local flac_files=( "$outputdir/"*.flac )
	if [ ${UNIT_TESTS["TEST_DAMAGE_TO_FLAC_SINGLETRACKS"]} -eq 1 ]; then 
		echo "Deliberately damaging a FLAC singletrack to test flac --test verification..."
		truncate --size=-1 "${flac_files[0]}" # We truncate the file instead of appending garbage because FLAC won't detect trailing garbage. TODO: File a bug report
	fi
}

# Because cuetools is bugged and won't print the catalog number we read it on our own
#
# parameters:
# $1: path of cue
cue_get_catalog() {
	local regexp="^(CATALOG )(.+)\$"
	# The tr will convert CRLF to LF and prevend trainling CR on the output catalog value
	cat "$1" | tr -d '\r' | grep -E "$regexp" | sed -r s/"$regexp"/\\2/
}

# This function was inspired by the cuetag script of cuetools, taken from https://github.com/svend/cuetools
# It's license is GPL so this function is GPL as well. 
#
# parameters:
# $1 = full path of FLAC file
# $2 = track number of FLAC file
pretag_singletrack_flac_from_cue_or_die()
{
	local flac_file="$1"
	local trackno="$2"

	# REASONS OF THE DECISIONS OF MAPPING CUE TAGS TO FLAC TAGS:
	#
	# Mapping CUE tag names to FLAC tag names is diffcult:
	# - CUE is not standardized. The tags it provides are insufficient to represent all tags of common types of music.Their meaning is not well-defined due to lag of standardization. Therefore, we only use the CUE fields which are physically stored on the CD.
	# - FLAC does provide a standard list of tags but it is as well insufficient. (http://www.xiph.org/vorbis/doc/v-comment.html) Therefore, we needed a different one
	#
	# Because we recommend MusicBrainz for tagging AND they are so kind to provide a complex list of standard tag names for each common audio file format including FLAC, we decided to use the MusicBrainz FLAC tag names. 
	# The "pre" means that tagging from a CUE is NEVER sufficient. CUE does not provide enough tags!
	#
	# Conclusion:
	# - The semantics of the CUE fields which EAC uses is taken from <TODO>
	# - The mapping between CUE tag names and cueprint fields is taken from the manpage of cueprint and by checking with an EAC CUE which uses ALL tags EAC will ever use (TODO: find one and actually do this)
	# - The target FLAC tag names are taken from http://musicbrainz.org/doc/MusicBrainz_Picard/Tags/Mapping
	#
	
	## From cueprint manpage:
	##   Character   Conversion         Character   Conversion
	##   ────────────────────────────────────────────────────────────────
	##   A           album arranger     a           track arranger
	##   C           album composer     c           track composer
	##   G           album genre        g           track genre
	##                                  i           track ISRC
	##   M           album message      m           track message
	##   N           number of tracks   n           track number
	##   P           album performer    p           track performer
	##   S           album songwriter
	##   T           album title        t           track title
	##   U           album UPC/EAN      u           track ISRC (CD-TEXT)

	# The following are the mappings from CUEPRINT to FLAC tags. The list was created by reading each entry of the above cueprint manpage and trying to find a tag which fits it in the musicbrainz tag mapping table http://musicbrainz.org/doc/MusicBrainz_Picard/Tags/Mapping
	# bash variable name == FLAC tag names
	# sorting of the variables is equal to cueprint manpage
	# TODO: find out the exact list of CUE-tags which cueprint CANNOT read and decide what to do about them
	# TODO: do a reverse check of the mapping list: read the musicbrainz tag mapping table and try to find a proper CUE-tag for each musicbrainz tag. ideally, as the CUE-tag-table, do not use the cueprint manpage but a list of all CUE tags which EAC will ever generate
	# TODO: when no per-track information is available, it might be a good idea to fallback to the album information. check whether cueprint does this. if not, do it manually maybe. think about possible side effects of falling back.

	# We only use the fields which are actually stored on the disc.
	# TODO: find out whether this is actually everything which is stored on a CD
	
	local -A fields	# Attention: We have to explicitely declare the associative array or iteration over the keys will not work!
	# disc tags
	fields["CATALOGNUMBER"]=`cue_get_catalog "$INPUT_CUE_ABSOLUTE"`						# album UPC/EAN. Debbuging showed that cueprint's %U is broken so we use our function.
	fields["ENCODEDBY"]="perfect-flac-encode $VERSION with `flac --version`"	# own version :)
	fields["TRACKTOTAL"]='%N'													# number of tracks
	fields["TOTALTRACKS"]="${fields['TRACKTOTAL']}"								# musicbrainz lists both TRACKTOAL and TOTALTRACKS and for track count.

	# track tags
	fields["ISRC"]='%i'			# track ISRC
	fields["COMMENT"]='%m'		# track message. TODO: is this stored on the CD?
	fields["TRACKNUMBER"]='%n'	# %n = track number
	
	# We use our own homebrew regexp for obtaining the CATALOG from the CUE so we should be careful
	if [ "${fields['CATALOGNUMBER']}" = "" ]; then
		echo "Obtaining CATALOG failed!" >&2
		exit 1
	fi
	
	for field in "${!fields[@]}"; do
		# remove pre-existing tags. we do not use --remove-all-tags because it would remove the replaygain info. and besides it is also cleaner to only remove stuff we know about
		if ! metaflac --remove-tag="$field" "$flac_file" ; then
			echo "Removing existing tag $field failed!" >&2
			exit 1
		fi
		
		local conversion="${fields[$field]}"
		local value=`cueprint -n $trackno -t "$conversion\n" "$INPUT_CUE_ABSOLUTE"`
		
		if [ -z "$value" ] ; then
			continue	# Skip empty field
		fi
		
		if ! echo "$field=$value" | metaflac --import-tags-from=- "$flac_file" ; then
			echo "Setting tag $field=$value failed!" >&2
			exit 1
		fi
	done
}

# This function was inspired by the cuetag script of cuetools, taken from https://github.com/svend/cuetools
# It's license is GPL so this function is GPL as well. 
pretag_singletrack_flacs_from_cue_or_die()
{
	echo "Pre-tagging the singletrack FLACs with information from the CUE which is physically stored on the CD. Please use MusicBrainz Picard for the rest of the tags..."
	
	local inputdir_flac="$INPUT_DIR_ABSOLUTE/${TEMP_DIRS[FLAC_SINGLETRACK_SUBDIR]}"
	local flac_files=( "$inputdir_flac/"*.flac )
	
	for file in "${flac_files[@]}"; do
		local filename_without_path=`basename "$file"`
		local tracknumber=`get_tracknumber_of_singletrack "$filename_without_path"`

		if ! pretag_singletrack_flac_from_cue_or_die "$file" "$tracknumber" ; then
			echo "Tagging $file failed!" >&2
			exit 1
		fi
	done
}

test_flac_singletracks_or_die() {
	echo "Running flac --test on singletrack FLACs..."
	local inputdir_flac="$INPUT_DIR_ABSOLUTE/${TEMP_DIRS[FLAC_SINGLETRACK_SUBDIR]}"
	local flac_files=( "$inputdir_flac"/*.flac )
	
	if ! flac --test --silent --warnings-as-errors "${flac_files[@]}"; then
		echo "Testing FLAC singletracks failed!" >&2
		exit 1
	fi
}

test_checksums_of_decoded_flac_singletracks_or_die() {
	echo "Decoding singletrack FLACs to WAVs to validate checksums ..."
	
	local inputdir_wav="$INPUT_DIR_ABSOLUTE/${TEMP_DIRS[WAV_SINGLETRACK_SUBDIR]}"
	local inputdir_flac="$INPUT_DIR_ABSOLUTE/${TEMP_DIRS[FLAC_SINGLETRACK_SUBDIR]}"
	local outputdir="$INPUT_DIR_ABSOLUTE/${TEMP_DIRS[DECODED_WAV_SINGLETRACK_SUBDIR]}"
	
	set_working_directory_or_die "$inputdir_flac"	# We need input filenames to be relative for --output-prefix to work
	if ! flac --decode --silent --warnings-as-errors --output-prefix="$outputdir/" *.flac ; then
		echo "Decoding FLAC singletracks failed!" >&2
		exit 1
	fi
	set_working_directory_or_die
	
	local wav_files=( "$outputdir/"*.wav )
	if [ ${UNIT_TESTS["TEST_DAMAGE_TO_DECODED_FLAC_SINGLETRACKS"]} -eq 1 ]; then 
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
	set_working_directory_or_die
}

move_output_to_target_dir_or_die() {
	echo "Moving FLACs to output directory..."
	
	local inputdir="$INPUT_DIR_ABSOLUTE/${TEMP_DIRS[FLAC_SINGLETRACK_SUBDIR]}"
	
	if ! mv --no-clobber "$inputdir"/*.flac "$OUTPUT_DIR_ABSOLUTE" ; then
		echo "Moving FLAC files to output dir failed!" >&2
		exit 1
	fi
}

copy_cue_log_sha256_to_target_dir_or_die() {
	echo "Copying CUE, LOG and SHA256 to output directory..."
	
	local input_files=( "$INPUT_CUE_ABSOLUTE" "$INPUT_LOG_ABSOLUTE" "$INPUT_DIR_ABSOLUTE/${TEMP_DIRS[WAV_JOINTEST_SUBDIR]}/$INPUT_CUE_LOG_WAV_BASENAME.sha256" )
	
	# TODO: maybe use different filenames for cue/log? also update the README if we do so
	
	if ! cp --archive --no-clobber "${input_files[@]}" "$OUTPUT_DIR_ABSOLUTE" ; then
		"Copying CUE, LOG and SHA256 to output directory failed!" >&2
		exit 1;
	fi
}

# Prints the README to stdout.
print_readme_or_die() {
	local e="echo"
	
	$e "About the quality of this CD copy:" &&
	$e "----------------------------------" &&
	$e "These audio files were produced with perfect-flac-encode version $VERSION, using `flac --version`."  &&
	$e "They are stored in \"FLAC\" format, which is lossless. This means that they can have the same quality as an audio CD." &&
	$e "This is much better than MP3 for example: MP3 leaves out some tones because some people cannot hear them." &&
	$e "" &&
	$e "The used prefect-flac-encode is a program which converts good Exact Audio Copy CD copies to FLAC audio files." &&
	$e "The goal of perfect-flac-encode is to produce CD copies with the best quality possible." &&
	$e "This is NOT only about the quality of the audio: It also means that the files can be used as a perfect backup of your CDs. The author of the software even trusts them for digital preservation for ever." &&
	$e "For allowing this, the set of files which you received were designed to make it possible to burn a disc which is absolutely identical to the original one in case your original disc is destroyed." &&
	$e "Therefore, please do not delete any of the contained files!" &&
	$e "For instructions on how to restore the original disc, please visit the website of perfect-flac-decode. You can find the address below." &&
	$e "" &&
	$e "" &&
	$e "Explanation of the purpose of the files you got:" &&
	$e "------------------------------------------------" &&
	$e "\"$INPUT_CUE_LOG_WAV_BASENAME.cue\"" &&
	$e "This file contains the layout of the original disc. It will be the file which you load with your CD burning software if you want to burn a backup of the disc. Please remember: Before burning it you have to decompress the audio with perfect-flac-decode. If you don't do this, burning the 'cue' will not work." &&
	$e "" &&
	$e "\"$INPUT_CUE_LOG_WAV_BASENAME.sha56\"" &&
	$e "This contains a so-called checksum of the original, uncompressed disc image. If you want to burn the disc to a CD, you will have to decompress the FLAC files to a WAV image with perfect-flac-decode. The checksum file allows perfect-flac-decode to validate that the decompression did not produce any errors." &&
	$e "" &&
	$e "\"$INPUT_CUE_LOG_WAV_BASENAME.log\"" &&
	$e "This file is a 'proof of quality'. It contains the output of Exact Audio Copy and perfect-flac-encode as well as their versions. It allows you to see the conditions of the copying. You can check it to see that there were no errors. Further, if someone finds bugs in the future in certain versions of the involved software you will be able to check whether your audio files are affected." &&
	$e "" &&
	$e "" &&
	$e "Websites:" &&
	$e "---------" &&
	$e "perfect-flac-encode: http://leo.bogert.de/perfect-flac-encode" &&
	$e "perfect-flac-decode: http://leo.bogert.de/perfect-flac-decode" &&
	$e "FLAC: http://flac.sourceforge.net/" &&
	$e "Exact Audio Copy: http://www.exactaudiocopy.de/"
}

write_readme_txt_to_target_dir_or_die() {
	echo "Generating README.txt ..."

	# We wrap at 80 characters so the full file will fit into a standard Windows Notepad window. TODO: Find out the actual line width of default Notepad. I don't have Windows at hand right now
	# We use Windows linebreaks since they will work on any plattform. Unix linebreaks would not wrap the line with many Windows editors.
	if ! print_readme_or_die |
		fold --spaces --width=80 | 	
		( while read line; do echo -n -e "$line\r\n"; done ) \
		> "$OUTPUT_DIR_ABSOLUTE/README.txt"	
	then
		echo "Generating README.txt failed!"
		exit 1
	fi
}

die_if_unit_tests_failed() {
	for test in "${!UNIT_TESTS[@]}"; do
		if [ "${UNIT_TESTS[$test]}" != "0" ] ; then
			echo "Unit test $test failed: perfect-flac-encode should have indicated checksum failure due to the deliberate damage of the unit test but did not do so!" >&2
			exit 1
		fi
	done
}

main() {
	echo -e "\n\nperfect-flac-encode.sh Version $VERSION running ... "
	echo -e "BETA VERSION - NOT for productive use!\n\n"
	
	# obtain parameters
	local original_working_dir="$(pwd)"	# store the working directory in case the parameters are relative paths
	local original_cue_log_wav_basename="$1"
	local original_input_dir="$2"
	local original_output_dir="$3"
	
	echo "Album: $original_cue_log_wav_basename"
	echo "Input directory: $original_input_dir"
	echo "Output directory: $original_output_dir"
	
	# initialize globals
	INPUT_CUE_LOG_WAV_BASENAME="$original_cue_log_wav_basename"
	# make the directories absolute if they are not
	[[ "$original_input_dir" = /* ]] && INPUT_DIR_ABSOLUTE="$original_input_dir" || INPUT_DIR_ABSOLUTE="$original_working_dir/$original_input_dir"
	[[ "$original_output_dir" = /* ]] && OUTPUT_DIR_ABSOLUTE="$original_output_dir/$INPUT_CUE_LOG_WAV_BASENAME" || OUTPUT_DIR_ABSOLUTE="$original_working_dir/$original_output_dir/$INPUT_CUE_LOG_WAV_BASENAME"
	# TODO: strip trailing slash
	
	INPUT_CUE_ABSOLUTE="$INPUT_DIR_ABSOLUTE/$INPUT_CUE_LOG_WAV_BASENAME.cue"
	INPUT_LOG_ABSOLUTE="$INPUT_DIR_ABSOLUTE/$INPUT_CUE_LOG_WAV_BASENAME.log"
	INPUT_WAV_ABSOLUTE="$INPUT_DIR_ABSOLUTE/$INPUT_CUE_LOG_WAV_BASENAME.wav"
	
	for tempdir in "${!TEMP_DIRS[@]}" ; do
		TEMP_DIRS_ABSOLUTE[$tempdir]="$OUTPUT_DIR_ABSOLUTE/${TEMP_DIRS[$tempdir]}"
	done
	
	set_working_directory_or_die
	ask_to_delete_existing_output_and_temp_dirs_or_die
	create_directories_or_die
	check_whether_input_is_accurately_ripped_or_die
	check_shntool_wav_problem_diagnosis_or_die
	test_whether_the_two_eac_crcs_match
	test_eac_crc_or_die
	exit 1	# FIXME: apply planned changes of this branch to all following functions
	split_wav_image_to_singletracks_or_die
	test_accuraterip_checksums_of_split_wav_singletracks_or_die
	generate_checksum_of_original_wav_image_or_die
	test_checksum_of_rejoined_wav_image_or_die
	encode_wav_singletracks_to_flac_or_die
	pretag_singletrack_flacs_from_cue_or_die
	test_flac_singletracks_or_die
	test_checksums_of_decoded_flac_singletracks_or_die
	move_output_to_target_dir_or_die
	copy_cue_log_sha256_to_target_dir_or_die
	write_readme_txt_to_target_dir_or_die
	# TODO: Check whether we can safely append the perfect-flac encode log to the EAC log and do so if we can. EAC adds a checksum to the end of its log, We should check whether the checksum validation tools allow us to add content to the file. If they don't, maybe we should just add another checksum to the end. If we do NOT implement merging of the log files, write our log to a separate file and upate the code which produces the README to reflect that change.
	delete_temp_dirs
	die_if_unit_tests_failed
	
	echo "SUCCESS."
	exit 0 # SUCCESS
}

main "$@"
