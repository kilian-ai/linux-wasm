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

# Build variant. One of {wasm32,wasm64}_{nommu,mmu}. Beware that 64-bit and/or MMU comes with a runtime cost.
: "${LW_VARIANT:=wasm32_nommu}"

# Internal variables derived from the user-settable ones.
LW_ARCH="${LW_VARIANT%%_*}"

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

        # Due to a bug in LLVM only the compiler-rt belonging to the
        # LLVM_DEFAULT_TARGET_TRIPLE in use will be built. Build for wasm64 too.
        # This is only needed when building the user space parts for wasm64 and
        # can be skipped in case you want to only build wasm32 busybox/programs.
        rm -rf "$LW_BUILD/compiler-rt-wasm64" && mkdir -p "$LW_BUILD/compiler-rt-wasm64"
        cmake -G Ninja \
            "-DCMAKE_INSTALL_PREFIX=$LW_INSTALL/llvm" \
            "-B$LW_BUILD/compiler-rt-wasm64" \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_C_COMPILER="$LW_INSTALL/llvm/bin/clang" \
            -DCMAKE_AR="$LW_INSTALL/llvm/bin/llvm-ar" \
            -DCMAKE_NM="$LW_INSTALL/llvm/bin/llvm-nm" \
            -DCMAKE_RANLIB="$LW_INSTALL/llvm/bin/llvm-ranlib" \
            -DLLVM_CONFIG_PATH="$LW_INSTALL/llvm/bin/llvm-config" \
            -DCOMPILER_RT_BAREMETAL_BUILD=Yes \
            -DCOMPILER_RT_BUILD_CRT=No \
            -DCOMPILER_RT_HAS_FPIC_FLAG=No \
            -DCOMPILER_RT_DEFAULT_TARGET_ONLY=Yes \
            -DCMAKE_C_COMPILER_TARGET="wasm64-unknown-unknown" \
            "-DCOMPILER_RT_INSTALL_LIBRARY_DIR=$LW_INSTALL/llvm/lib/clang/18/lib" \
            "$LW_SRC/llvm/compiler-rt/lib/builtins"
        cmake --build "$LW_BUILD/compiler-rt-wasm64"
        cmake --install "$LW_BUILD/compiler-rt-wasm64"
    handled=1;;&

    "build-kernel"|"all-kernel"|"build"|"all"|"build-os")
        mkdir -p "$LW_BUILD/kernel-$LW_VARIANT"
        # Note: LLVM=/blah/ MUST start AND END with a trailing slash, or it will be interpreted as LLVM=1 (which looks for system clang etc.)!
        # Unfortunately this means the value cannot be escaped in 'single quotes', which means the path cannot contain spaces...
        # Note: kernel docs often show setting CC=clang but don't do this (or you will get system clang due to the above).
        # Another similar problem is that O= does not work with 'single quote' escaping either in recent kernel versions.
        LW_KERNEL_MAKE="make"
        LW_KERNEL_MAKE+=" O=$LW_BUILD/kernel-$LW_VARIANT"
        LW_KERNEL_MAKE+=" ARCH=wasm"
        LW_KERNEL_MAKE+=" LLVM=$LW_ROOT/tools/fake-llvm/"
        LW_KERNEL_MAKE+=" REAL_LLVM=$LW_INSTALL/llvm/bin/"
        LW_KERNEL_MAKE+=" CROSS_COMPILE=wasm32-unknown-unknown-"
        LW_KERNEL_MAKE+=" HOSTCC=gcc"
        LW_KERNEL_CONFIG="./scripts/config --file $LW_BUILD/kernel-$LW_VARIANT/.config"
        (
            cd "$LW_SRC/kernel"

            if [ "$LW_REBUILD_KERNEL_DEFCONFIG" = "1" ]; then
                # This creates a useful Wasm defconfig from scratch using tinyconfig.
                $LW_KERNEL_MAKE tinyconfig

                $LW_KERNEL_CONFIG --disable CONFIG_SLUB_TINY
                $LW_KERNEL_CONFIG --disable CONFIG_CC_OPTIMIZE_FOR_SIZE
                $LW_KERNEL_CONFIG --enable CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE
                $LW_KERNEL_CONFIG --enable CONFIG_BLK_DEV_INITRD
                $LW_KERNEL_CONFIG --enable CONFIG_BINFMT_SCRIPT
                $LW_KERNEL_CONFIG --enable CONFIG_BINFMT_WASM
                $LW_KERNEL_CONFIG --enable CONFIG_TTY
                $LW_KERNEL_CONFIG --enable CONFIG_HVC_WASM
                $LW_KERNEL_CONFIG --enable CONFIG_NO_HZ_FULL
                $LW_KERNEL_CONFIG --enable CONFIG_PROC_FS
                $LW_KERNEL_CONFIG --enable CONFIG_SYSFS
                $LW_KERNEL_CONFIG --enable CONFIG_BLOCK
                $LW_KERNEL_CONFIG --enable CONFIG_MULTIUSER
                $LW_KERNEL_CONFIG --enable CONFIG_POSIX_TIMERS
                $LW_KERNEL_CONFIG --enable CONFIG_PRINTK
                $LW_KERNEL_CONFIG --enable CONFIG_BUG
                $LW_KERNEL_CONFIG --enable CONFIG_FUTEX
                $LW_KERNEL_CONFIG --enable CONFIG_EPOLL
                $LW_KERNEL_CONFIG --enable CONFIG_SIGNALFD
                $LW_KERNEL_CONFIG --enable CONFIG_TIMERFD
                $LW_KERNEL_CONFIG --enable CONFIG_EVENTFD
                $LW_KERNEL_CONFIG --enable CONFIG_ADVISE_SYSCALLS

                if [ "$LW_ARCH" = "wasm64" ]; then
                    $LW_KERNEL_CONFIG --enable CONFIG_64BIT
                fi

                # Fixup dependencies as config --enable only sets direct values.
                $LW_KERNEL_MAKE olddefconfig

                # For inspection. Any changes should ideally go into this script.
                #$LW_KERNEL_MAKE menuconfig
                # Don't forget to save the .config to arch/wasm/configs when done.
            else
                echo "Generating .config from ${LW_VARIANT}_defconfig"
                $LW_KERNEL_MAKE "${LW_VARIANT}_defconfig"
            fi

            $LW_KERNEL_MAKE -j $LW_JOBS_KERNEL_COMPILE V=1
            $LW_KERNEL_MAKE headers_install
        )
        mkdir -p "$LW_INSTALL/kernel-$LW_VARIANT/include"
        cp -R "$LW_BUILD/kernel-$LW_VARIANT/usr/include/." "$LW_INSTALL/kernel-$LW_VARIANT/include"
        cp "$LW_BUILD/kernel-$LW_VARIANT/vmlinux" "$LW_INSTALL/kernel-$LW_VARIANT/vmlinux.wasm"
    handled=1;;&

    "build-musl"|"all-musl"|"build"|"all"|"build-os")
        mkdir -p "$LW_BUILD/musl-$LW_VARIANT"
        (
            cd "$LW_BUILD/musl-$LW_VARIANT"

            # Needed not only by configure, but also make, and make install!
            export REAL_LLVM="$LW_INSTALL/llvm/bin"

            # LIBCC is set mostly to something non-empty, which is needed for the build to succeed.
            # Note how we build --disable-shared (i.e. disable dynamic linking by musl) but with -fPIC and -shared.
            CROSS_COMPILE="$LW_ROOT/tools/fake-llvm/llvm-" \
            CC="$LW_ROOT/tools/fake-llvm/clang" \
            CFLAGS="--target=wasm-linux-musl -march=$LW_ARCH -fPIC -Wl,-shared" \
            LIBCC="--rtlib=compiler-rt" \
            "$LW_SRC/musl/configure" --target=wasm --prefix=/ --disable-shared "--srcdir=$LW_SRC/musl"
            make -j $LW_JOBS_MUSL_COMPILE

            # NOTE: do not forget destdir or you may ruin the host system!!!
            # We set --prefix to / as include/lib dirs are auto picked up by LLVM then (using --sysroot).
            mkdir -p "$LW_INSTALL/musl-$LW_VARIANT"
            DESTDIR="$LW_INSTALL/musl-$LW_VARIANT" make install
        )
    handled=1;;&

    "build-busybox-kernel-headers"|"all-busybox-kernel-headers"|"build"|"all"|"build-os")
        rm -rf "$LW_INSTALL/busybox-kernel-headers-$LW_VARIANT"
        mkdir -p "$LW_INSTALL/busybox-kernel-headers-$LW_VARIANT"
        cp -R "$LW_INSTALL/kernel-$LW_VARIANT/include/." "$LW_INSTALL/busybox-kernel-headers-$LW_VARIANT"
        (
            cd "$LW_INSTALL/busybox-kernel-headers-$LW_VARIANT"
            patch -p1 --no-backup < "$LW_ROOT/patches/busybox-kernel-headers/busybox-kernel-headers-for-musl.patch"
        )
    handled=1;;&

    "build-busybox"|"all-busybox"|"build"|"all"|"build-os")
        mkdir -p "$LW_BUILD/busybox-$LW_VARIANT"
        mkdir -p "$LW_INSTALL/busybox-$LW_VARIANT"
        (
            cd "$LW_SRC/busybox"
            for CMD in "wasm_defconfig" "-j $LW_JOBS_BUSYBOX_COMPILE" "install"
            do # make wasm_defconfig, make, make install (CONFIG_PREFIX is set below for install path).
                # The path escaping is a bit tricky but this seems to work... somehow...
                REAL_LLVM="$LW_INSTALL/llvm/bin" make "O=$LW_BUILD/busybox-$LW_VARIANT" ARCH=wasm "CONFIG_PREFIX=$LW_INSTALL/busybox-$LW_VARIANT" \
                    "CROSS_COMPILE=$LW_ROOT/tools/fake-llvm/" "CONFIG_SYSROOT=$LW_INSTALL/musl-$LW_VARIANT" \
                    CONFIG_EXTRA_CFLAGS="$CFLAGS --target=wasm-linux-musl -march=$LW_ARCH -isystem '$LW_INSTALL/busybox-kernel-headers-$LW_VARIANT' -D__linux__ -fPIC" \
                    CONFIG_EXTRA_LDFLAGS="-m$LW_ARCH -shared" \
                    $CMD
            done
        )
    handled=1;;&

    "build-initramfs"|"all-initramfs"|"build"|"all"|"build-os")
        mkdir -p "$LW_INSTALL/initramfs-$LW_VARIANT"

        # First, create the base by copying a template with some device files.
        # This base is created by tools/make-initramfs-base.sh but requires root to run.
        cp "$LW_ROOT/patches/initramfs/initramfs-base.cpio" "$LW_INSTALL/initramfs-$LW_VARIANT/initramfs.cpio"

        # Then copy BusyBox into it.
        (
            cd "$LW_INSTALL/busybox-$LW_VARIANT"
            # The below command must run in the directory of the archive (i.e. read "find .").
            find . -print0 | cpio --null -ov --format=newc -A -O "$LW_INSTALL/initramfs-$LW_VARIANT/initramfs.cpio"
        )

        # And copy a simple init too.
        (
            cd "$LW_ROOT/patches/initramfs/"
            # The below command must run in the same directory as the root of the files it will copy.
            echo "./init" | cpio -ov --format=newc -A -O "$LW_INSTALL/initramfs-$LW_VARIANT/initramfs.cpio"
        )

        # Finally we should zip it up so that it takes less space. This is the file to distribute.
        rm -f "$LW_INSTALL/initramfs-$LW_VARIANT/initramfs.cpio.gz"
        gzip "$LW_INSTALL/initramfs-$LW_VARIANT/initramfs.cpio"
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
        echo "LW_VARIANT=$LW_VARIANT"
        echo "---------------"
        exit 1
    handled=1;;&
esac

if ! [ "$handled" = 1 ]; then
    # *) would not work above as ;;& would redirect all cases to *)
    echo "Unknown action parameter: $1"
    exit 1
fi
