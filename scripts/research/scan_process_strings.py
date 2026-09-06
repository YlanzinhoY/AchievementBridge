"""Search readable regions of a Windows process without modifying it."""

from __future__ import annotations

import argparse
import ctypes
from ctypes import wintypes


PROCESS_QUERY_INFORMATION = 0x0400
PROCESS_VM_READ = 0x0010
MEM_COMMIT = 0x1000
PAGE_GUARD = 0x100
PAGE_NOACCESS = 0x01
READ_CHUNK = 4 * 1024 * 1024

kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)


class MEMORY_BASIC_INFORMATION(ctypes.Structure):
    _fields_ = [
        ("BaseAddress", ctypes.c_void_p),
        ("AllocationBase", ctypes.c_void_p),
        ("AllocationProtect", wintypes.DWORD),
        ("PartitionId", wintypes.WORD),
        ("RegionSize", ctypes.c_size_t),
        ("State", wintypes.DWORD),
        ("Protect", wintypes.DWORD),
        ("Type", wintypes.DWORD),
    ]


kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
kernel32.OpenProcess.restype = wintypes.HANDLE
kernel32.VirtualQueryEx.argtypes = [
    wintypes.HANDLE,
    ctypes.c_void_p,
    ctypes.POINTER(MEMORY_BASIC_INFORMATION),
    ctypes.c_size_t,
]
kernel32.VirtualQueryEx.restype = ctypes.c_size_t
kernel32.ReadProcessMemory.argtypes = [
    wintypes.HANDLE,
    ctypes.c_void_p,
    ctypes.c_void_p,
    ctypes.c_size_t,
    ctypes.POINTER(ctypes.c_size_t),
]
kernel32.ReadProcessMemory.restype = wintypes.BOOL
kernel32.CloseHandle.argtypes = [wintypes.HANDLE]


def readable_regions(handle: int):
    address = 0
    info = MEMORY_BASIC_INFORMATION()
    while kernel32.VirtualQueryEx(
        handle, ctypes.c_void_p(address), ctypes.byref(info), ctypes.sizeof(info)
    ):
        base = int(info.BaseAddress or 0)
        size = int(info.RegionSize)
        if (
            info.State == MEM_COMMIT
            and not info.Protect & PAGE_GUARD
            and not info.Protect & PAGE_NOACCESS
        ):
            yield base, size, int(info.Type), int(info.Protect), int(info.AllocationBase or 0)
        next_address = base + size
        if next_address <= address:
            break
        address = next_address


def read(handle: int, address: int, size: int) -> bytes:
    buffer = (ctypes.c_ubyte * size)()
    count = ctypes.c_size_t()
    if not kernel32.ReadProcessMemory(
        handle, ctypes.c_void_p(address), buffer, size, ctypes.byref(count)
    ):
        return b""
    return bytes(buffer[: count.value])


def printable_context(blob: bytes, offset: int, width: int = 96) -> str:
    start = max(0, offset - width // 2)
    end = min(len(blob), offset + width // 2)
    return "".join(chr(value) if 0x20 <= value < 0x7F else "." for value in blob[start:end])


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("pid", type=int)
    parser.add_argument("patterns", nargs="+")
    parser.add_argument("--max-per-pattern", type=int, default=30)
    parser.add_argument("--allocation-base", type=lambda value: int(value, 0))
    args = parser.parse_args()

    encoded: list[tuple[str, str, bytes]] = []
    for pattern in args.patterns:
        encoded.append((pattern, "utf8", pattern.encode("utf-8")))
        encoded.append((pattern, "utf16", pattern.encode("utf-16-le")))
    overlap = max(len(value) for _, _, value in encoded) - 1
    counts = {(name, encoding): 0 for name, encoding, _ in encoded}

    handle = kernel32.OpenProcess(
        PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, False, args.pid
    )
    if not handle:
        raise ctypes.WinError(ctypes.get_last_error())
    total_read = 0
    try:
        for region_base, region_size, region_type, protect, allocation_base in readable_regions(handle):
            if args.allocation_base is not None and allocation_base != args.allocation_base:
                continue
            previous = b""
            position = 0
            while position < region_size:
                request = min(READ_CHUNK, region_size - position)
                chunk = read(handle, region_base + position, request)
                if not chunk:
                    break
                total_read += len(chunk)
                combined = previous + chunk
                combined_base = region_base + position - len(previous)
                lower = combined.lower()
                for name, encoding, value in encoded:
                    key = (name, encoding)
                    if counts[key] >= args.max_per_pattern:
                        continue
                    needle = value.lower() if encoding == "utf8" else value
                    cursor = 0
                    while counts[key] < args.max_per_pattern:
                        cursor = lower.find(needle, cursor)
                        if cursor < 0:
                            break
                        address = combined_base + cursor
                        # Ignore a duplicate wholly contained in the overlap.
                        if address + len(needle) > region_base + position:
                            counts[key] += 1
                            context = printable_context(combined, cursor)
                            print(
                                f"{name!r} {encoding} address=0x{address:x} "
                                f"allocation=0x{allocation_base:x} type=0x{region_type:x} "
                                f"protect=0x{protect:x}\n  {context}"
                            , flush=True)
                        cursor += max(1, len(needle))
                previous = combined[-overlap:] if overlap else b""
                position += len(chunk)
    finally:
        kernel32.CloseHandle(handle)

    print(f"read={total_read / (1024 * 1024):.1f} MiB")
    for name, encoding, _ in encoded:
        print(f"{name!r} {encoding}: {counts[(name, encoding)]}")


if __name__ == "__main__":
    main()
