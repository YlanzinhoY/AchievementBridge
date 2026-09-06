"""Resolve a GTA V Enhanced native hash in a running process.

Research-only helper based on the open-source Enhanced Native Trainer's
InitNativeTables technique. It creates a short-lived scratch scrProgram in the
target process, asks the game's own resolver to populate one handler pointer,
reads the result, and frees the scratch allocation. It never calls the native.
"""

from __future__ import annotations

import argparse
import ctypes
import struct
import sys
from ctypes import wintypes
from pathlib import Path

import pefile
from capstone import CS_ARCH_X86, CS_MODE_64, Cs

sys.path.insert(0, str(Path(__file__).resolve().parent))
from inspect_socialclub_memory import modules, read_memory  # noqa: E402


PROCESS_CREATE_THREAD = 0x0002
PROCESS_QUERY_INFORMATION = 0x0400
PROCESS_VM_OPERATION = 0x0008
PROCESS_VM_READ = 0x0010
PROCESS_VM_WRITE = 0x0020
MEM_COMMIT = 0x1000
MEM_RESERVE = 0x2000
MEM_RELEASE = 0x8000
PAGE_READWRITE = 0x04
WAIT_OBJECT_0 = 0

INIT_NATIVE_TABLES_SIGNATURE = bytes.fromhex("EB 2A 0F 1F 40 00 48 8B 54 17 10")
INIT_NATIVE_TABLES_BACK_OFFSET = 0x2A
SCR_PROGRAM_SIZE = 0x80
NATIVE_COUNT_OFFSET = 0x2C
NATIVE_OFFSET_POINTER_OFFSET = 0x40

kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
kernel32.OpenProcess.restype = wintypes.HANDLE
kernel32.VirtualAllocEx.argtypes = [
    wintypes.HANDLE,
    ctypes.c_void_p,
    ctypes.c_size_t,
    wintypes.DWORD,
    wintypes.DWORD,
]
kernel32.VirtualAllocEx.restype = ctypes.c_void_p
kernel32.VirtualFreeEx.argtypes = [
    wintypes.HANDLE,
    ctypes.c_void_p,
    ctypes.c_size_t,
    wintypes.DWORD,
]
kernel32.WriteProcessMemory.argtypes = [
    wintypes.HANDLE,
    ctypes.c_void_p,
    ctypes.c_void_p,
    ctypes.c_size_t,
    ctypes.POINTER(ctypes.c_size_t),
]
kernel32.WriteProcessMemory.restype = wintypes.BOOL
kernel32.CreateRemoteThread.argtypes = [
    wintypes.HANDLE,
    ctypes.c_void_p,
    ctypes.c_size_t,
    ctypes.c_void_p,
    ctypes.c_void_p,
    wintypes.DWORD,
    ctypes.POINTER(wintypes.DWORD),
]
kernel32.CreateRemoteThread.restype = wintypes.HANDLE
kernel32.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
kernel32.WaitForSingleObject.restype = wintypes.DWORD
kernel32.CloseHandle.argtypes = [wintypes.HANDLE]


def write_memory(handle: int, address: int, data: bytes) -> None:
    buffer = ctypes.create_string_buffer(data)
    count = ctypes.c_size_t()
    if not kernel32.WriteProcessMemory(
        handle,
        ctypes.c_void_p(address),
        buffer,
        len(data),
        ctypes.byref(count),
    ) or count.value != len(data):
        raise ctypes.WinError(ctypes.get_last_error())


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("pid", type=int)
    parser.add_argument("hash", type=lambda value: int(value, 0))
    parser.add_argument("--disassemble", type=lambda value: int(value, 0), default=0)
    args = parser.parse_args()

    rights = (
        PROCESS_CREATE_THREAD
        | PROCESS_QUERY_INFORMATION
        | PROCESS_VM_OPERATION
        | PROCESS_VM_READ
        | PROCESS_VM_WRITE
    )
    handle = kernel32.OpenProcess(rights, False, args.pid)
    if not handle:
        raise ctypes.WinError(ctypes.get_last_error())

    allocation = 0
    try:
        loaded = modules(handle)
        main_base, main_path = loaded[0]
        pe = pefile.PE(str(main_path), fast_load=True)
        image = read_memory(handle, main_base, pe.OPTIONAL_HEADER.SizeOfImage)
        matches = []
        cursor = 0
        while True:
            cursor = image.find(INIT_NATIVE_TABLES_SIGNATURE, cursor)
            if cursor < 0:
                break
            matches.append(cursor)
            cursor += 1
        if len(matches) != 1:
            raise SystemExit(f"expected one InitNativeTables signature, found {len(matches)}")
        init_native_tables = main_base + matches[0] - INIT_NATIVE_TABLES_BACK_OFFSET

        allocation_size = SCR_PROGRAM_SIZE + 8
        allocation = int(
            kernel32.VirtualAllocEx(
                handle,
                None,
                allocation_size,
                MEM_COMMIT | MEM_RESERVE,
                PAGE_READWRITE,
            )
            or 0
        )
        if not allocation:
            raise ctypes.WinError(ctypes.get_last_error())

        program = bytearray(allocation_size)
        struct.pack_into("<I", program, NATIVE_COUNT_OFFSET, 1)
        struct.pack_into(
            "<Q", program, NATIVE_OFFSET_POINTER_OFFSET, allocation + SCR_PROGRAM_SIZE
        )
        struct.pack_into("<Q", program, SCR_PROGRAM_SIZE, args.hash)
        write_memory(handle, allocation, bytes(program))

        thread_id = wintypes.DWORD()
        thread = kernel32.CreateRemoteThread(
            handle,
            None,
            0,
            ctypes.c_void_p(init_native_tables),
            ctypes.c_void_p(allocation),
            0,
            ctypes.byref(thread_id),
        )
        if not thread:
            raise ctypes.WinError(ctypes.get_last_error())
        try:
            wait = kernel32.WaitForSingleObject(thread, 10_000)
            if wait != WAIT_OBJECT_0:
                raise SystemExit(f"native resolver thread did not finish: wait=0x{wait:x}")
        finally:
            kernel32.CloseHandle(thread)

        handler = struct.unpack(
            "<Q", read_memory(handle, allocation + SCR_PROGRAM_SIZE, 8)
        )[0]
        owner = (
            main_path.name
            if main_base <= handler < main_base + pe.OPTIONAL_HEADER.SizeOfImage
            else "outside main module"
        )
        print(f"game={main_path}")
        print(f"InitNativeTables=0x{init_native_tables:x}")
        print(f"hash=0x{args.hash:016X}")
        print(f"handler=0x{handler:x} owner={owner}")
        if args.disassemble:
            code = read_memory(handle, handler, args.disassemble)
            disassembler = Cs(CS_ARCH_X86, CS_MODE_64)
            print("disassembly:")
            for instruction in disassembler.disasm(code, handler):
                print(
                    f"  0x{instruction.address:x} (+0x{instruction.address - main_base:x}) "
                    f"{instruction.mnemonic:8} {instruction.op_str}"
                )
    finally:
        if allocation:
            kernel32.VirtualFreeEx(handle, ctypes.c_void_p(allocation), 0, MEM_RELEASE)
        kernel32.CloseHandle(handle)


if __name__ == "__main__":
    main()
