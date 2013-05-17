perfect-flac-decode
===================

A tool to decode FLACs which were encoded with perfect-flac-encode. It will decode to a WAV full disc image which allows burning of a CD which is absolutely identical to the original disc.

# Installation:
This script was written & tested on Ubuntu 12.10 x86_64. It should work on any Ubuntu or Debian-based distribution.
To obtain its dependancies, do the following:

* Install these packages:
	* cuetools
	* flac
	* shntool
* Obtain the ["accuraterip-checksum" source code](https://github.com/leo-bogert/accuraterip-checksum) and compile it. Put the binary into a directory which is in $PATH. You need version 1.4 at least.
* Obtain the ["eac-crc" script](https://github.com/leo-bogert/eac-crc) and put it into a directory which is in $PATH. You need version 1.2 at least. Don't forget to install its required packages.

# Return value:
The script will exit with exit code 0 upon success and exit code > 0 upon failure.

# Output:
Please make sure you know the parameters and their names from the Syntax section before reading on.

# Author:
[Leo Bogert](http://leo.bogert.de)

# Version:
BETA

# Donations:
[bitcoin:1PZBKLBFnbBA5h1HdKF8PATk3JnAND91yp](bitcoin:1PZBKLBFnbBA5h1HdKF8PATk3JnAND91yp)
	
# License:
GPLv3
