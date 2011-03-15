#!/bin/bash

BUILD_STATUS=0

build_openssl() {
	local TARGET_DIR="$1"
	local LIBNAME=$2
	local DISTDIR="`pwd`/dist-$LIBNAME"
	local PLATFORM="$3"
	local SDKPATH="$4"

	echo "Building binary for iPhone $LIBNAME $PLATFORM to $DISTDIR"

	case $LIBNAME in
		${LIBNAME_DEVICE})  ARCH="armv6";ASSEMBLY="no-asm";;
		*)	   ARCH="i386";ASSEMBLY="";;
	esac

	cd "${TARGET_DIR}"

	echo Patching crypto/ui/ui_openssl.c
	echo From: `fgrep 'intr_signal;' crypto/ui/ui_openssl.c`
	perl -pi.bak \
		-e 's/static volatile sig_atomic_t intr_signal;/static volatile int intr_signal;/;' \
		crypto/ui/ui_openssl.c
	echo To: `fgrep 'intr_signal;' crypto/ui/ui_openssl.c`

	# Compile a version for the device...

	PATH="${PLATFORM}"/Developer/usr/bin:$OPATH
	export PATH

	mkdir "${DISTDIR}"

	./config --openssldir="${DISTDIR}" ${ASSEMBLY}

	perl -pi.bak \
		-e "s#CC= cc#CC=${PLATFORM}/Developer/usr/bin/gcc# ;" \
		-e "s#CFLAG= #CFLAG=-arch ${ARCH} -isysroot ${SDKPATH} # ;" \
		-e "s#-arch i386#-arch ${ARCH}# ;" \
		Makefile

	case $LIBNAME in
		${LIBNAME_SIMULATOR})
			perl -pi.bak \
				-e 'if (/LIBDEPS=/) { s/\)}";/\)} -L.";/; }' \
					Makefile.shared
			(cd apps; ln -s "${SDKPATH}"/usr/lib/crt1.10.5.o crt1.10.6.o);
			(cd test; ln -s "${SDKPATH}"/usr/lib/crt1.10.5.o crt1.10.6.o);
			;;
	esac

	# using && means the next command only runs if the previous commands all succeeded
	# use -j (with # of CPUs) for parallel, fast build
	echo "# Building clean first"
	make -j `/usr/bin/hwprefs cpu_count` clean
	echo "# Building libraries (only)"
	make -j `/usr/bin/hwprefs cpu_count` build_libs && make install
	BUILD_STATUS=$?
	cd -
}

extract_tarball() {
	local tarball="$1"
	local dir="${tarball%%.tar.gz}"
	if [ -d "${dir}" ]; then
		echo Removing previous tarball directory: ${dir}
		/bin/rm -rf ${dir}
	fi
	echo Extracting tarball ${tarball}
	tar zxf ${tarball}
}

clean_dir() {
	local dir="$1"
	if [ $BUILD_STATUS = 0 ]; then
		echo Cleaning up "${DIR}"
		/bin/rm -rf ${DIR}
	else
		echo "Build failed ($BUILD_STATUS)"
		exit 1
	fi
}

latest_sdk() {
	# set SDK to the last SDK in directory $1 (sorted lexically)
	local dir="$1"
	pushd "$dir"
	local sdk_list=(*)
	local sdk_count=${#sdk_list[*]}
	local last_sdk_index=$sdk_count
	((last_sdk_index--))
	LATEST_SDK="${dir}/${sdk_list[$last_sdk_index]}"
	popd
}

# use getopt to get command-line options
args=`getopt d:t: $*`; errcode=$?; set -- $args

if [ $errcode != 0 ]; then
	echo <<EOF
Usage: $0 [-d dir] [-t tb.tar.gz]
	-d dir -- build already-extracted tarball in dir
	-t tb.tar.gz -- use specified tarball
You should specify **either** the tarball or the directory, but not both.	
EOF
	exit 1
fi

for i; do
	echo "i is $i [$*]"
	case "$i"
	in
		-d) echo "target_dir $2"; TARGET_DIR="$2"; shift;;
		-t) echo "target $2"; TARGET="$2"; shift;;
		--) shift; break;;
	esac
done

if [ ${#TARGET} -gt 0 -a ${#TARGET_DIR} -gt 0 ]; then
	echo "Only specify *either* the target directory or the tarball"
	exit 1
fi
if [ ${#TARGET} = 0 -a ${#TARGET_DIR} = 0 ]; then
	echo "Please specify either the target directory or the tarball"
	exit 1
fi

if [ ${#TARGET} ]; then
	TARGET_DIR="${TARGET%%.tar.gz}"
fi

setup_vars() {
	# use whatever name you want for the libraries
	LIBNAME_DEVICE=device
	LIBNAME_SIMULATOR=simulator

	# don't touch anything below

	# if you want to change the "current" Xcode, use "sudo xcode-select switch <path>"
	XCODE=`xcode-select -print-path`
	PLATFORMS="${XCODE}"/Platforms

	MAC_PLATFORM="${PLATFORMS}"/MacOSX.platform
	IOS_PLATFORM="${PLATFORMS}"/iPhoneOS.platform
	IOS_SIMULATOR_PLATFORM="${PLATFORMS}"/iPhoneSimulator.platform

	MAC_SDK_DIR="$MAC_PLATFORM/Developer/SDKs"
	IOS_SDK_DIR="$IOS_PLATFORM/Developer/SDKs"
	IOS_SIMULATOR_SDK_DIR="$IOS_SIMULATOR_PLATFORM/Developer/SDKs"

	OPATH=$PATH

	# latest_sdk() sets "LATEST_SDK" to the latest one (why can't functions return values? *sigh)
	latest_sdk "$IOS_SDK_DIR"
	IOS_SDK="$LATEST_SDK"
	latest_sdk "$IOS_SIMULATOR_SDK_DIR"
	IOS_SIMULATOR_SDK="$LATEST_SDK"

}

setup_vars

# build device library
[ ${#TARGET} -gt 0 ] && extract_tarball "${TARGET}"
build_openssl "$TARGET_DIR" "${LIBNAME_DEVICE}" "$IOS_PLATFORM" "$IOS_SDK"
if [ ${#TARGET} -gt 0 ]; then
	clean_dir "${TARGET%%.tar.gz}"
	extract_tarball "${TARGET}"
else
	build_clean "$TARGET_DIR" "${LIBNAME_DEVICE}" "$IOS_PLATFORM" "$IOS_SDK"
fi

# build simulator library
build_openssl "$TARGET_DIR" "${LIBNAME_SIMULATOR}" "$IOS_SIMULATOR_PLATFORM" "$IOS_SIMULATOR_SDK"
clean_dir "${TARGET%%.tar.gz}"

# then, combine them into one..
echo "Creating combined binary into directory 'dist'"
[ -d dist ] && /bin/rm -rf dist
mkdir dist
(cd dist-${LIBNAME_DEVICE}; tar cf - . ) | (cd dist; tar xf -)

for i in crypto ssl
do
	lipo \
		-create dist-${LIBNAME_DEVICE}/lib/lib$i.a dist-${LIBNAME_SIMULATOR}/lib/lib$i.a \
		-o dist/lib/lib$i.a
done

/bin/rm -rf dist-${LIBNAME_SIMULATOR} dist-${LIBNAME_DEVICE}

echo "Now package is ready in 'dist' directory'"
