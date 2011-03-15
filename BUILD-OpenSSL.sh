#!/bin/bash

build_openssl() {
	local LIBNAME=$1
	local DISTDIR="`pwd`/dist-$LIBNAME"
	local PLATFORM="$2"
	local SDKPATH="$3"

	echo "Building binary for iPhone $LIBNAME $PLATFORM to $DISTDIR"

	echo Removing ${TARGET}
	/bin/rm -rf ${TARGET}
	echo Extracting ${TARGET}
	tar zxf ${TARGET}.tar.gz

	case $LIBNAME in
		device)  ARCH="armv6";ASSEMBLY="no-asm";;
		*)	   ARCH="i386";ASSEMBLY="";;
	esac

	cd ${TARGET}

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
		simulator)
			perl -pi.bak \
				-e 'if (/LIBDEPS=/) { s/\)}";/\)} -L.";/; }' \
					Makefile.shared
			(cd apps; ln -s "${SDKPATH}"/usr/lib/crt1.10.5.o crt1.10.6.o);
			(cd test; ln -s "${SDKPATH}"/usr/lib/crt1.10.5.o crt1.10.6.o);
			;;
	esac

	# using && means the next command only runs if the previous commands all succeeded
	# use -j (with # of CPUs) for parallel, fast build
	make -j `/usr/bin/hwprefs cpu_count` && make install
	cd ..
	echo Cleaning up "${TARGET}"
	/bin/rm -rf ${TARGET}
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

TARGET=openssl-1.0.0d
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

build_openssl "device" "$IOS_PLATFORM" "$IOS_SDK"
build_openssl "simulator" "$IOS_SIMULATOR_PLATFORM" "$IOS_SIMULATOR_SDK"

### Then, combine them into one..

echo "Creating combined binary into directory 'dist'"
/bin/rm -rf dist
mkdir dist
(cd dist-device; tar cf - . ) | (cd dist; tar xf -)

for i in crypto ssl
do
	lipo \
		-create dist-device/lib/lib$i.a dist-simulator/lib/lib$i.a \
		-o dist/lib/lib$i.a
done

/bin/rm -rf dist-simulator dist-device

echo "Now package is ready in 'dist' directory'"
