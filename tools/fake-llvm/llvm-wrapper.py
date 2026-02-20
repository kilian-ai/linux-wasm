#!/usr/bin/env python3
import sys
import os
from pathlib import Path


def rewrite_triple(original_args):
    # A default -march is needed as some kbuild parts only sets the triple.
    # initramfs_data in an example and this (hopefully) works as it's data only.
    march = "wasm32"
    for arg in original_args:
        if arg.startswith("-march="):
            # The last one wins if multiple.
            march = arg[len("-march=") :]

    if march not in ("wasm32", "wasm64"):
        raise RuntimeError(f"unknown -march= specified: {march}")

    args = []
    for arg in original_args:
        if arg.startswith("--target="):
            args.append(f"--target={march}-unknown-unknown")

        elif arg.startswith("-march="):
            pass  # Drop any -march=*.

        else:
            args.append(arg)

    return args


def rewrite_clang(original_args):
    args = rewrite_triple(original_args)

    # These flags are needed so that wasm-ld can be run with --shared-memory.
    for feature in ("atomics", "bulk-memory"):
        args += f"-Xclang -target-feature -Xclang +{feature}".split(" ")

    args.append("-D__builtin_return_address=")

    # Prevent s128/u128 in the kernel, which depends on compiler-rt builtins.
    args.append("-U__SIZEOF_INT128__")

    return args


def rewrite_lld(original_args):
    args = []
    group = None
    for arg in original_args:
        if arg in ("-v", "--version"):
            # Abort our looping, and just run the original version check.
            return original_args[:]

        if group is not None:
            if arg == "--end-group":
                # Workaround: we add it twice, which hopefully is enough.
                args.extend(group)
                args.extend(group)
                group = None
            elif arg.startswith("-"):
                raise RuntimeError(f"argument inside --start/end-group: {arg}")
            else:
                group.append(arg)
                continue

        elif arg == "--start-group":
            if group is not None:
                raise RuntimeError("nested --start-group not allowed")
            group = []

        elif arg == "--end-group":
            # Positive cases should be handled in the flow above instead (to avoid self-trigger).
            raise RuntimeError("stray --end-group without start")

        elif arg.startswith("--build-id="):
            # Tracked in LLVM D107662.
            # Drop for now.
            pass

        else:
            args.append(arg)

    args.append("--error-limit=0")

    # Only add these for the final link, i.e. not at relocatable pre-link stages.
    if not "-r" in args:
        args.extend(
            [
                "-no-gc-sections",  # No idea why this was written with only one -dash.
                "--no-merge-data-segments",
                "--no-entry",
                "--export-all",
                "--import-memory",
                "--shared-memory",
                f"--max-memory={1<<32}",  # TODO: What to use for 64-bit?
                "--import-undefined",
            ]
        )

    return args


def rewrite_objcopy(original_args):
    args = []
    section_flags = False
    for arg in original_args:
        if arg == "--set-section-flags":
            section_flags = True
            continue

        elif section_flags and arg != "":
            section_flags = False
            if arg != ".modinfo=noload":
                raise RuntimeError(
                    "--set-section-flags not supported - normally suppressed, but unknown arg {arg}"
                )
            continue

        elif arg == "--strip-unneeded-symbol=__mod_device_table__*":
            continue

        args.append(arg)

    return args


def main():
    real_bin_dir = os.environ.get("REAL_LLVM")
    if not real_bin_dir:
        raise RuntimeError("REAL_LLVM is not set")

    args = sys.argv[1:]
    tool = Path(sys.argv[0]).name
    if tool == "clang":
        args = rewrite_clang(args)
    elif tool == "ld.lld":
        tool = "wasm-ld"
        args = rewrite_lld(args)
    elif tool == "llvm-objcopy":
        args = rewrite_objcopy(args)
    else:
        pass  # Passthrough other parts of the toolchain.

    real_tool = Path(real_bin_dir) / tool
    if not real_tool.exists():
        raise RuntimeError(f"real tool not found: {real_tool}")
    if real_tool.resolve() == Path(__file__).resolve():
        raise RuntimeError("wrapper resolves to itself")

    print(f"{tool} -> {real_tool}:", args, file=sys.stderr)

    os.execv(str(real_tool), [str(real_tool)] + args)


if __name__ == "__main__":
    main()
