#!/bin/bash

# This is a very simple file that can be divided into two phases for each inherent software: fetching and building.
# Fetching happens first, then building. You can "fetch" all, "build" all, or do "all" which does both. You may also
# specify a specific piece of software and fetch or build just that, but keep in mind dependencies between them.
#
# Fetching means: download and patch.
# Building means: configure, compile and install (to separate folder).
# By default everything ends up in a folder named workspace/ but you can change that by specifying LW_WORKSPACE=...
# This script can be run in any directory, it should not pollute the current working directory, but just in case you
# may want to create an empty scratch directory. It's hard to validate that all components' build systems behave...

set -e

LW_ROOT="$(realpath -s "$(dirname "$0")")"

# (All paths below are resolved as absolute. This is required for the other parts of the script to work properly.)

# Path to workspace (will set LW_SRC, LW_BUILD, LW_INSTALL ... paths).
: "${LW_WORKSPACE:=$LW_ROOT/workspace}"
LW_WORKSPACE="$(realpath -sm "$LW_WORKSPACE")"

# Path to where sources will be downloaded and patched.
: "${LW_SRC:=$LW_WORKSPACE/src}"
LW_SRC="$(realpath -sm "$LW_SRC")"

# Path to where each software component will be built.
: "${LW_BUILD:=$LW_WORKSPACE/build}"
LW_BUILD="$(realpath -sm "$LW_BUILD")"

# Path to where each software component will be installed.
: "${LW_INSTALL:=$LW_WORKSPACE/install}"
LW_INSTALL="$(realpath -sm "$LW_INSTALL")"

# Parallel build jobs. Unfortunately not as simple as one number in reality.
: "${LW_JOBS_LLVM_LINK:=2}"
: "${LW_JOBS_LLVM_COMPILE:=16}"
: "${LW_JOBS_KERNEL_COMPILE:=16}"
: "${LW_JOBS_MUSL_COMPILE:=16}"
: "${LW_JOBS_BUSYBOX_COMPILE:=16}"

handled=0
case "$1" in # note use of ;;& meaning that each case is re-tested (can hit multiple times)!
    "fetch-llvm"|"all-llvm"|"fetch"|"all")
        mkdir -p "$LW_SRC/llvm"
        git clone -b wasm-18.1.2 --shallow-exclude=llvmorg-18.1.2 --single-branch --no-tags https://github.com/joelseverin/llvm.git "$LW_SRC/llvm"
        git -C "$LW_SRC/llvm" fetch --deepen=1 --no-tags
    handled=1;;&

    "fetch-kernel"|"all-kernel"|"fetch"|"all")
        mkdir -p "$LW_SRC/kernel"
        git clone -b wasm-6.19.3 --shallow-exclude=v6.19.3 --single-branch --no-tags https://github.com/joelseverin/linux.git "$LW_SRC/kernel"
        git -C "$LW_SRC/kernel" fetch --deepen=1 --no-tags
    handled=1;;&

    "fetch-musl"|"all-musl"|"fetch"|"all")
        mkdir -p "$LW_SRC/musl"
        git clone -b v1.2.5 --depth 1 --single-branch --no-tags https://git.musl-libc.org/git/musl "$LW_SRC/musl"
        git -C "$LW_SRC/musl" am < "$LW_ROOT/patches/musl/0001-NOMERGE-Hacks-to-get-Linux-Wasm-to-compile-minimal-a.patch"
    handled=1;;&

    "fetch-busybox-kernel-headers"|"all-busybox-kernel-headers"|"fetch"|"all")
        # There is not really much to do here, the kernel needs to be built first. See build-busybox-kernel-headers.
    handled=1;;&

    "fetch-busybox"|"all-busybox"|"fetch"|"all")
        mkdir -p "$LW_SRC/busybox"
        git clone -b 1_36_1 --depth 1 --single-branch --no-tags https://git.busybox.net/busybox "$LW_SRC/busybox"
        git -C "$LW_SRC/busybox" am < "$LW_ROOT/patches/busybox/0001-NOMERGE-Hacks-to-build-Wasm-Linux-arch-minimal-and-i.patch"
    handled=1;;&

    "fetch-initramfs"|"all-initramfs"|"fetch"|"all")
        # Nothing to do here.
        # We already have patches/initramfs/initramfs-base.cpio pre-built by toos/make-initramfs-base.sh in the repo.
    handled=1;;&

    "build-llvm"|"all-llvm"|"build"|"all"|"build-tools")
        mkdir -p "$LW_BUILD/llvm"
        # (LLVM_DEFAULT_TARGET_TRIPLE is needed to build compiler-rt, which is needed by musl.)
        # The extra indented lines are to build compiler-rt for Wasm, you may remove all of them to skip it.
        cmake -G Ninja \
            "-DCMAKE_INSTALL_PREFIX=$LW_INSTALL/llvm" \
            "-B$LW_BUILD/llvm" \
            -DCMAKE_BUILD_TYPE=Release \
            -DLLVM_TARGETS_TO_BUILD="WebAssembly" \
            -DLLVM_ENABLE_PROJECTS="clang;lld" \
                -DLLVM_ENABLE_RUNTIMES="compiler-rt" \
                -DCOMPILER_RT_BAREMETAL_BUILD=Yes \
                -DCOMPILER_RT_BUILD_XRAY=No \
                -DCOMPILER_RT_INCLUDE_TESTS=No \
                -DCOMPILER_RT_HAS_FPIC_FLAG=No \
                -DCOMPILER_RT_ENABLE_IOS=No \
                -DCOMPILER_RT_BUILD_CRT=No \
                -DCOMPILER_RT_BUILD_BUILTINS=No \
                -DCOMPILER_RT_DEFAULT_TARGET_ONLY=Yes \
                -DLLVM_DEFAULT_TARGET_TRIPLE="wasm32-unknown-unknown" \
            -DLLVM_ENABLE_ASSERTIONS=1 \
            -DLLVM_PARALLEL_LINK_JOBS=$LW_JOBS_LLVM_LINK \
            -DLLVM_PARALLEL_COMPILE_JOBS=$LW_JOBS_LLVM_COMPILE \
            "$LW_SRC/llvm/llvm"

        cmake --build "$LW_BUILD/llvm"
        cmake --install "$LW_BUILD/llvm"
    handled=1;;&

    "build-kernel"|"all-kernel"|"build"|"all"|"build-os")
        mkdir -p "$LW_BUILD/kernel"
        # Note: LLVM=/blah/ MUST start AND END with a trailing slash, or it will be interpreted as LLVM=1 (which looks for system clang etc.)!
        # Unfortunately this means the value cannot be escaped in 'single quotes', which means the path cannot contain spaces...
        # Note: kernel docs often show setting CC=clang but don't do this (or you will get system clang due to the above).
        # Another similar problem is that O= does not work with 'single quote' escaping either in recent kernel versions.
        LW_KERNEL_MAKE="make"
        LW_KERNEL_MAKE+=" O=$LW_BUILD/kernel"
        LW_KERNEL_MAKE+=" ARCH=wasm"
        LW_KERNEL_MAKE+=" LLVM=$LW_INSTALL/llvm/bin/"
        LW_KERNEL_MAKE+=" CROSS_COMPILE=wasm32-unknown-unknown-"
        LW_KERNEL_MAKE+=" HOSTCC=gcc"
        (
            cd "$LW_SRC/kernel"
            #$LW_KERNEL_MAKE menuconfig
            #exit 1

            $LW_KERNEL_MAKE defconfig
            $LW_KERNEL_MAKE -j $LW_JOBS_KERNEL_COMPILE V=1
            $LW_KERNEL_MAKE headers_install
        )
        mkdir -p "$LW_INSTALL/kernel/include"
        cp -R "$LW_BUILD/kernel/usr/include/." "$LW_INSTALL/kernel/include"
        cp "$LW_BUILD/kernel/vmlinux" "$LW_INSTALL/kernel/vmlinux.wasm"
    handled=1;;&

    "build-musl"|"all-musl"|"build"|"all"|"build-os")
        mkdir -p "$LW_BUILD/musl"
        (
            cd "$LW_BUILD/musl"

            # LIBCC is set mostly to something non-empty, which is needed for the build to succeed.
            # Note how we build --disable-shared (i.e. disable dynamic linking by musl) but with -fPIC and -shared.
            CROSS_COMPILE="$LW_INSTALL/llvm/bin/llvm-" \
    	    CC="$LW_INSTALL/llvm/bin/clang" \
    	    CFLAGS="--target=wasm32-unknown-unknown -Xclang -target-feature -Xclang +atomics -Xclang -target-feature -Xclang +bulk-memory -fPIC -Wl,-shared" \
	        LIBCC="--rtlib=compiler-rt" \
	        "$LW_SRC/musl/configure" --target=wasm --prefix=/ --disable-shared "--srcdir=$LW_SRC/musl"
            make -j $LW_JOBS_MUSL_COMPILE 

            # NOTE: do not forget destdir or you may ruin the host system!!!
            # We set --prefix to / as include/lib dirs are auto picked up by LLVM then (using --sysroot).
            mkdir -p "$LW_INSTALL/musl"
            DESTDIR="$LW_INSTALL/musl" make install
        )
    handled=1;;&

    "build-busybox-kernel-headers"|"all-busybox-kernel-headers"|"build"|"all"|"build-os")
        rm -rf "$LW_INSTALL/busybox-kernel-headers"
        mkdir -p "$LW_INSTALL/busybox-kernel-headers"
        cp -R "$LW_INSTALL/kernel/include/." "$LW_INSTALL/busybox-kernel-headers"
        (
            cd "$LW_INSTALL/busybox-kernel-headers"
            patch -p1 --no-backup < "$LW_ROOT/patches/busybox-kernel-headers/busybox-kernel-headers-for-musl.patch"
        )
    handled=1;;&

    "build-busybox"|"all-busybox"|"build"|"all"|"build-os")
        mkdir -p "$LW_BUILD/busybox"
        mkdir -p "$LW_INSTALL/busybox"
        cd "$LW_SRC/busybox"
        for CMD in "wasm_defconfig" "-j $LW_JOBS_BUSYBOX_COMPILE" "install"
        do # make wasm_defconfig, make, make install (CONFIG_PREFIX is set below for install path).
            # The path escaping is a bit tricky but this seems to work... somehow...
            make "O=$LW_BUILD/busybox" ARCH=wasm "CONFIG_PREFIX=$LW_INSTALL/busybox" \
                "CROSS_COMPILE=$LW_INSTALL/llvm/bin/" "CONFIG_SYSROOT=$LW_INSTALL/musl" \
                CONFIG_EXTRA_CFLAGS="$CFLAGS -isystem '$LW_INSTALL/busybox-kernel-headers' -D__linux__ -fPIC" \
                $CMD
        done
    handled=1;;&

    "build-initramfs"|"all-initramfs"|"build"|"all"|"build-os")
        mkdir -p "$LW_INSTALL/initramfs"

        # First, create the base by copying a template with some device files.
        # This base is created by tools/make-initramfs-base.sh but requires root to run.
        cp "$LW_ROOT/patches/initramfs/initramfs-base.cpio" "$LW_INSTALL/initramfs/initramfs.cpio"

        # Then copy BusyBox into it.
        (
            cd "$LW_INSTALL/busybox"
            # The below command must run in the directory of the archive (i.e. read "find .").
            find . -print0 | cpio --null -ov --format=newc -A -O "$LW_INSTALL/initramfs/initramfs.cpio"
        )

        # And copy a simple init too.
        (
            cd "$LW_ROOT/patches/initramfs/"
            # The below command must run in the same directory as the root of the files it will copy.
            echo "./init" | cpio -ov --format=newc -A -O "$LW_INSTALL/initramfs/initramfs.cpio"
        )

        # Finally we should zip it up so that it takes less space. This is the file to distribute.
        rm -f "$LW_INSTALL/initramfs/initramfs.cpio.gz"
        gzip "$LW_INSTALL/initramfs/initramfs.cpio"
    handled=1;;&

    ""|"help")
        echo "Usage: $0 [action]"
        echo "  where action is one of:"
        echo "    all          -- Fetch and build everything."
        echo "    fetch        -- Fetch everything."
        echo "    build        -- Build everything (no fetching)."
        echo "    all-xxx      -- Fetch and build component xxx."
        echo "    fetch-xxx    -- Fetch component xxx."
        echo "    build-xxx    -- Build component xxx (no fetching)."
        echo "    build-tools  -- Build all build tool components (llvm)."
        echo "    build-os     -- Build all OS software (excluding build tools)."
        echo "  and components include (in order): llvm, kernel, musl, busybox-kernel-headers, busybox, initramfs."
        echo ""
        echo "Fetch will download and patch the source. Build will configure, compile and install (to a folder in the workspace)."
        echo ""
        echo "To clean, simply delete the files in the src, build or install folders. Incremental re-building is possible."
        echo ""
        echo "The following variables are currently used. They can be overridden using environment variables with the same name."
        echo "Paths are commonly automatically made absolute. If a relative path is given, it is evaluated in relation to the CWD."
        echo "---------------"
        echo "LW_WORKSPACE=$LW_WORKSPACE"
        echo "LW_SRC=$LW_SRC"
        echo "LW_BUILD=$LW_BUILD"
        echo "LW_INSTALL=$LW_INSTALL"
        echo "---------------"
        exit 1
    handled=1;;&
esac

if ! [ "$handled" = 1 ]; then
    # *) would not work above as ;;& would redirect all cases to *)
    echo "Unknown action parameter: $1"
    exit 1
fi
