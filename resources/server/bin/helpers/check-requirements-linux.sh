#!/usr/bin/env sh
#
# Copyright (c) Microsoft Corporation. All rights reserved.
#

set -e

# Do not remove this check.
# Provides a way to skip the server requirements check from
# outside the install flow. A system process can create this
# file before the server is downloaded and installed.
#
# This check is duplicated between code-server-linux.sh and here
# since remote container calls into this script directly quite early
# before the usual server startup flow.
if [ -f "/tmp/vscode-skip-server-requirements-check" ]; then
	echo "!!! WARNING: Skipping server pre-requisite check !!!"
	echo "!!! Server stability is not guaranteed. Proceed at your own risk. !!!"
	exit 0
fi

ARCH=$(uname -m)
found_required_glibc=0
found_required_glibcxx=0

# Extract the ID value from /etc/os-release
if [ -f /etc/os-release ]; then
    OS_ID="$(cat /etc/os-release | grep -Eo 'ID=([^"]+)' | sed -n '1s/ID=//p')"
    if [ "$OS_ID" = "nixos" ]; then
        echo "Warning: NixOS detected, skipping GLIBC check"
        exit 0
    fi
fi

# Based on https://github.com/bminor/glibc/blob/520b1df08de68a3de328b65a25b86300a7ddf512/elf/cache.c#L162-L245
case $ARCH in
	x86_64) LDCONFIG_ARCH="x86-64";;
	armv7l | armv8l) LDCONFIG_ARCH="hard-float";;
	arm64 | aarch64)
        BITNESS=$(getconf LONG_BIT)
		if [ "$BITNESS" = "32" ]; then
			# Can have 32-bit userland on 64-bit kernel
			LDCONFIG_ARCH="hard-float"
		else
			LDCONFIG_ARCH="AArch64"
		fi
		;;
esac

if [ "$OS_ID" != "alpine" ]; then
    if [ -f /sbin/ldconfig ]; then
        # Look up path
        libstdcpp_paths=$(/sbin/ldconfig -p | grep 'libstdc++.so.6')

        if [ "$(echo "$libstdcpp_paths" | wc -l)" -gt 1 ]; then
            libstdcpp_path=$(echo "$libstdcpp_paths" | grep "$LDCONFIG_ARCH" | awk '{print $NF}')
        else
            libstdcpp_path=$(echo "$libstdcpp_paths" | awk '{print $NF}')
        fi
    fi
fi

if [ -z "$libstdcpp_path" ]; then
    if [ -f /usr/lib/libstdc++.so.6 ]; then
	    # Typical path
	    libstdcpp_path='/usr/lib/libstdc++.so.6'
    elif [ -f /usr/lib64/libstdc++.so.6 ]; then
	    # Typical path
	    libstdcpp_path='/usr/lib64/libstdc++.so.6'
    else
	    echo "Warning: Can't find libstdc++.so or ldconfig, can't verify libstdc++ version"
    fi
fi

while [ -n "$libstdcpp_path" ]; do
    libstdcpp_path_line=$(echo "$libstdcpp_path" | head -n1)
    libstdcpp_real_path=$(readlink -f "$libstdcpp_path_line")
    libstdcpp_version=$(grep -ao 'GLIBCXX_[0-9]*\.[0-9]*\.[0-9]*' "$libstdcpp_real_path" | sort -V | tail -1)
    libstdcpp_version_number=$(echo "$libstdcpp_version" | sed 's/GLIBCXX_//')
    if [ "$(printf '%s\n' "3.4.24" "$libstdcpp_version_number" | sort -V | head -n1)" = "3.4.24" ]; then
        found_required_glibcxx=1
        break
    fi
    libstdcpp_path=$(echo "$libstdcpp_path" | tail -n +2)    # remove first line
done
if [ "$found_required_glibcxx" = "0" ]; then
    echo "Warning: Missing GLIBCXX >= 3.4.25! from $libstdcpp_real_path"
fi

if [ "$OS_ID" = "alpine" ]; then
    MUSL_RTLDLIST="/lib/ld-musl-aarch64.so.1 /lib/ld-musl-x86_64.so.1"
    for rtld in ${MUSL_RTLDLIST}; do
        if [ -x $rtld ]; then
            musl_version=$("$rtld" --version 2>&1 | grep "Version" | awk '{print $NF}')
            break
        fi
    done
    if [ "$(printf '%s\n' "1.2.3" "$musl_version" | sort -V | head -n1)" != "1.2.3" ]; then
        echo "Error: Unsupported alpine distribution. Please refer to our supported distro section https://aka.ms/vscode-remote/linux for additional information."
        exit 99
    fi
    found_required_glibc=1
elif [ -z "$(ldd --version 2>&1 | grep 'musl libc')" ]; then
    if [ -f /sbin/ldconfig ]; then
        # Look up path
        libc_paths=$(/sbin/ldconfig -p | grep 'libc.so.6')

        if [ "$(echo "$libc_paths" | wc -l)" -gt 1 ]; then
            libc_path=$(echo "$libc_paths" | grep "$LDCONFIG_ARCH" | awk '{print $NF}')
        else
            libc_path=$(echo "$libc_paths" | awk '{print $NF}')
        fi
    elif [ -f /usr/lib/libc.so.6 ]; then
        # Typical path
        libc_path='/usr/lib/libc.so.6'
    elif [ -f /usr/lib64/libc.so.6 ]; then
        # Typical path
        libc_path='/usr/lib64/libc.so.6'
    else
        echo "Warning: Can't find libc.so or ldconfig, can't verify libc version"
    fi

    while [ -n "$libc_path" ]; do
		# Rather than trusting the output of ldd --version (which is not always accurate)
		# we instead use the version of the cached libc.so.6 file itself.
        libc_path_line=$(echo "$libc_path" | head -n1)
        libc_real_path=$(readlink -f "$libc_path_line")
        libc_version=$(cat "$libc_real_path" | sed -n 's/.*release version \([0-9]\+\.[0-9]\+\).*/\1/p')
        if [ "$(printf '%s\n' "2.28" "$libc_version" | sort -V | head -n1)" = "2.28" ]; then
            found_required_glibc=1
            break
        fi
	    libc_path=$(echo "$libc_path" | tail -n +2)    # remove first line
    done
    if [ "$found_required_glibc" = "0" ]; then
        echo "Warning: Missing GLIBC >= 2.28! from $libc_real_path"
    fi
else
    echo "Warning: musl detected, skipping GLIBC check"
    found_required_glibc=1
fi

if [ "$found_required_glibc" = "0" ] || [ "$found_required_glibcxx" = "0" ]; then
	echo "Error: Missing required dependencies. Please refer to our FAQ https://aka.ms/vscode-remote/faq/old-linux for additional information."
	# Custom exit code based on https://tldp.org/LDP/abs/html/exitcodes.html
	#exit 99
fi
