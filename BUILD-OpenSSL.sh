#!/bin/bash

BUILD_STATUS=0

build_openssl() {
	local TARGET_DIR="$1"
	local LIBNAME=$2
	local DISTDIR="`pwd`/dist-$LIBNAME"
	local PLATFORM="$3"
	local SDKPATH="$4"

	p "Building binary for iPhone $LIBNAME $PLATFORM to $DISTDIR" 

	case $LIBNAME in
		${LIBNAME_DEVICE})  ARCH="armv6";ASSEMBLY="no-asm";;
		*)	   ARCH="i386";ASSEMBLY="";;
	esac

	cd "${TARGET_DIR}"

	p Patching crypto/ui/ui_openssl.c
	p From: `fgrep 'intr_signal;' crypto/ui/ui_openssl.c`
	x perl -pi.bak \
		-e 's/static volatile sig_atomic_t intr_signal;/static volatile int intr_signal;/;' \
		crypto/ui/ui_openssl.c
	p To: `fgrep 'intr_signal;' crypto/ui/ui_openssl.c`

	# Compile a version for the device...

	PATH="${PLATFORM}"/Developer/usr/bin:$OPATH
	export PATH

	# build release and debug versions
	for dflag in "" -d; do
		# # for now *always* build debug versions
		# dflag=-d
		x mkdir "${DISTDIR}${dflag}"

		p "# configuring: $dflag $DISTDIR $ASSEMBLY" 
		x ./config ${dflag} --openssldir="${DISTDIR}${dflag}" ${ASSEMBLY}

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

		# use -j (with # of CPUs) for parallel, fast build
		p "# Building clean first"
		x make -j `/usr/bin/hwprefs cpu_count` clean
		p "# Building libraries (only)"
		# using && means the next command only runs if the previous commands all succeeded
		x make -j `/usr/bin/hwprefs cpu_count` build_libs
		BUILD_STATUS=$?
		[ $BUILD_STATUS != 0 ] && break
		p "# installing ${DISTDIR}${dflag}"
		x make install
	done
	cd -
}

extract_tarball() {
	local tarball="$1"
	local dir="${tarball%%.tar.gz}"
	if [ -d "${dir}" ]; then
		p Removing previous tarball directory: ${dir}
		/bin/rm -rf ${dir}
	fi
	p Extracting tarball ${tarball}
	x tar zxf ${tarball}
}

clean_dir() {
	local dir="$1"
	if [ $BUILD_STATUS = 0 ]; then
		p Cleaning up "${DIR}"
		/bin/rm -rf ${DIR}
	else
		p "Build failed ($BUILD_STATUS)"
		p "Output is in $OUT"
		exit 1
	fi
}

latest_sdk() {
	# set SDK to the last SDK in directory $1 (sorted lexically)
	local dir="$1"
	x pushd "$dir"
	local sdk_list=(*)
	local sdk_count=${#sdk_list[*]}
	local last_sdk_index=$sdk_count
	((last_sdk_index--))
	LATEST_SDK="${dir}/${sdk_list[$last_sdk_index]}"
	x popd
}

setup_vars() {
	# clean up old compiler output
	rm -f /tmp/buildopenssl-*
	# where verbose compiler output goes
	OUT=`mktemp /tmp/build_openssl.XXXXXX` || exit 1

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

p() {
	echo $* | tee -a $OUT 2>&1
}

x() {
	$* >> $OUT 2>&1
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
	case "$i"
	in
		-d) TARGET_DIR="$2"; shift;;
		-t) TARGET="$2"; shift;;
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

setup_vars

p "# Compiler output is in $OUT"

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
# iterate over debug and non-debug versions
for d in "" "-d"; do
	# lipo both release and debug
	[ -d dist$d ] && /bin/rm -rf dist$d
	mkdir dist$d
	# check for directories being there
	[ ! -d dist-${LIBNAME_DEVICE}$d -o ! -d dist-${LIBNAME_SIMULATOR}$d ] && continue
	p "# Creating combined binary into directory dist$d"
	(cd dist-${LIBNAME_DEVICE}$d; tar cf - . ) | (cd dist$d; tar xf -) >> $OUT 2>&1
	for i in crypto ssl; do
		x lipo \
			-create dist-${LIBNAME_DEVICE}$d/lib/lib$i.a dist-${LIBNAME_SIMULATOR}$d/lib/lib$i.a \
			-o dist$d/lib/lib$i$d.a
	done
done

# /bin/rm -rf dist-${LIBNAME_SIMULATOR} dist-${LIBNAME_DEVICE}
# /bin/rm -rf dist-${LIBNAME_SIMULATOR}-d dist-${LIBNAME_DEVICE}-d

p "Now package is ready in 'dist' directory'"
p "Verbose output is in $OUT"
