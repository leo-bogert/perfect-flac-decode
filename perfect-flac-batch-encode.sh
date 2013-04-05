#!/bin/bash
if ! source "lib-bash-leo.sh" ; then
	echo 'lib-bash-leo.sh is missing in PATH!'
	exit 1
fi

INPUT_DIR_ABSOLUTE=''
OUTPUT_DIR_ABSOLUTE=''


encode() {
	album="$(basename "$1")"
	
	set_working_directory_or_die "$1"
	for wav in *.wav ; do
		stdout ""
		stdout ""
		stdout "Encoding: $wav"

		local disc
		disc="$(basename "$wav" ".wav")"

		if ! perfect-flac-encode.sh "$disc" "$1" "$OUTPUT_DIR_ABSOLUTE" ; then
			stderr "Encoding failed for: $album"
		fi
	done
}

encode_all() {
	for album in "$INPUT_DIR_ABSOLUTE"/* ; do
		if ! [ -d "$album" ] ; then
			stderr "Skipping non-directory: $album"
			continue
		fi
		
		local -a wavs=( "$album"/*.wav )

		if (( ${#wavs[@]} > 0 )) ; then
			encode "$album"
		elif [ "$(find "$album" -iname '*.wav' -printf '1' -quit)" = '1' ] ; then
			die "Found Wavs in subdirectories or with uppercase file extension, please move them to the parent directory and fix their file extension: $album"
		else
			stdout "No Wavs in: $album"
		fi
	done
}

main() {
	obtain_two_parameters_as_inputdir_output_dir "$@"

	stderr "WARNING: perfect-flac-batch-encode is not designed to be as robust as perfect-flac-encode. Use it at your own risk!"

	if [ -e "$OUTPUT_DIR_ABSOLUTE" ] ; then
		die "Output dir exists already!"
	fi
	mkdir -p -- "$OUTPUT_DIR_ABSOLUTE"

	encode_all

	echo "SUCCESS."
	exit 0 # SUCCESS
}

main "$@"
