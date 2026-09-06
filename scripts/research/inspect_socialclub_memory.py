"""Read-only Social Club memory inspection helper for provider research.

This script intentionally does not inject code, write process memory, or change
game files.  It locates MSVC RTTI/vtables and the Social Club root singleton in
an already-running GTA process so that achievement state can be identified.
"""

from __future__ import annotations

import argparse
import ctypes
import struct
from ctypes import wintypes
from pathlib import Path

import pefile
from capstone import CS_ARCH_X86, CS_MODE_64, CS_OP_IMM, CS_OP_MEM, Cs
from capstone.x86 import X86_REG_RIP


PROCESS_QUERY_INFORMATION = 0x0400
PROCESS_VM_READ = 0x0010
LIST_MODULES_ALL = 0x03

kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
psapi = ctypes.WinDLL("psapi", use_last_error=True)

kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
kernel32.OpenProcess.restype = wintypes.HANDLE
kernel32.ReadProcessMemory.argtypes = [
    wintypes.HANDLE,
    wintypes.LPCVOID,
    wintypes.LPVOID,
    ctypes.c_size_t,
    ctypes.POINTER(ctypes.c_size_t),
]
kernel32.ReadProcessMemory.restype = wintypes.BOOL
kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
kernel32.CloseHandle.restype = wintypes.BOOL

psapi.EnumProcessModulesEx.argtypes = [
    wintypes.HANDLE,
    ctypes.POINTER(wintypes.HMODULE),
    wintypes.DWORD,
    ctypes.POINTER(wintypes.DWORD),
    wintypes.DWORD,
]
psapi.EnumProcessModulesEx.restype = wintypes.BOOL
psapi.GetModuleFileNameExW.argtypes = [
    wintypes.HANDLE,
    wintypes.HMODULE,
    wintypes.LPWSTR,
    wintypes.DWORD,
]
psapi.GetModuleFileNameExW.restype = wintypes.DWORD


def read_memory(handle: int, address: int, size: int) -> bytes:
    buffer = (ctypes.c_ubyte * size)()
    read = ctypes.c_size_t()
    if not kernel32.ReadProcessMemory(
        handle, ctypes.c_void_p(address), buffer, size, ctypes.byref(read)
    ):
        raise ctypes.WinError(ctypes.get_last_error())
    return bytes(buffer[: read.value])


def modules(handle: int) -> list[tuple[int, Path]]:
    capacity = 1024
    values = (wintypes.HMODULE * capacity)()
    needed = wintypes.DWORD()
    if not psapi.EnumProcessModulesEx(
        handle,
        values,
        ctypes.sizeof(values),
        ctypes.byref(needed),
        LIST_MODULES_ALL,
    ):
        raise ctypes.WinError(ctypes.get_last_error())

    result: list[tuple[int, Path]] = []
    count = min(needed.value // ctypes.sizeof(wintypes.HMODULE), capacity)
    for index in range(count):
        buffer = ctypes.create_unicode_buffer(32768)
        if psapi.GetModuleFileNameExW(handle, values[index], buffer, len(buffer)):
            result.append((int(values[index]), Path(buffer.value)))
    return result


def c_string(blob: bytes, offset: int, limit: int = 512) -> str | None:
    if offset < 0 or offset >= len(blob):
        return None
    end = blob.find(b"\0", offset, min(len(blob), offset + limit))
    if end < 0:
        return None
    try:
        return blob[offset:end].decode("ascii")
    except UnicodeDecodeError:
        return None


def executable_ranges(pe: pefile.PE) -> list[tuple[int, int]]:
    result = []
    for section in pe.sections:
        if section.Characteristics & 0x20000000:
            start = section.VirtualAddress
            size = max(section.Misc_VirtualSize, section.SizeOfRawData)
            result.append((start, start + size))
    return result


def is_executable(address: int, base: int, ranges: list[tuple[int, int]]) -> bool:
    rva = address - base
    return any(start <= rva < end for start, end in ranges)


def decode_col(
    image: bytes, base: int, vtable: int
) -> tuple[str, int, int] | None:
    vtable_offset = vtable - base
    if vtable_offset < 8 or vtable_offset >= len(image):
        return None
    col_address = struct.unpack_from("<Q", image, vtable_offset - 8)[0]
    col_offset = col_address - base
    if col_offset < 0 or col_offset + 24 > len(image):
        return None
    signature, object_offset, _, type_rva, _, self_rva = struct.unpack_from(
        "<6I", image, col_offset
    )
    if signature not in (0, 1) or self_rva != col_offset:
        return None
    name = c_string(image, type_rva + 16)
    if not name or not name.startswith(".?"):
        return None
    return name, object_offset, col_address


def probable_object_vtables(
    image: bytes,
    base: int,
    object_address: int,
    object_data: bytes,
    exec_ranges: list[tuple[int, int]],
) -> list[tuple[int, int, str | None, int | None, list[int]]]:
    found = []
    seen: set[int] = set()
    for offset in range(0, len(object_data) - 8, 8):
        candidate = struct.unpack_from("<Q", object_data, offset)[0]
        if candidate in seen or not (base <= candidate < base + len(image)):
            continue
        table_offset = candidate - base
        if table_offset + 32 > len(image):
            continue
        entries = list(struct.unpack_from("<4Q", image, table_offset))
        if sum(is_executable(entry, base, exec_ranges) for entry in entries) < 3:
            continue
        seen.add(candidate)
        rtti = decode_col(image, base, candidate)
        name = rtti[0] if rtti else None
        subobject_offset = rtti[1] if rtti else None
        found.append((offset, candidate, name, subobject_offset, entries))
    return found


def rtti_types_containing(image: bytes, base: int, needle: bytes) -> list[tuple[str, int, list[int]]]:
    needle_lower = needle.lower()
    results = []
    cursor = 0
    while True:
        marker = image.find(b".?", cursor)
        if marker < 0:
            break
        cursor = marker + 2
        name = c_string(image, marker)
        if not name or needle_lower not in name.lower().encode("ascii", "ignore"):
            continue
        type_rva = marker - 16
        if type_rva < 0:
            continue
        encoded_rva = struct.pack("<I", type_rva)
        vtables: list[int] = []
        ref = 0
        while True:
            ref = image.find(encoded_rva, ref)
            if ref < 0:
                break
            # pTypeDescriptor is the fourth uint32 in an x64 COL.
            col_offset = ref - 12
            ref += 1
            if col_offset < 0 or col_offset + 24 > len(image):
                continue
            signature, _, _, candidate_type_rva, _, self_rva = struct.unpack_from(
                "<6I", image, col_offset
            )
            if signature not in (0, 1) or candidate_type_rva != type_rva or self_rva != col_offset:
                continue
            col_pointer = struct.pack("<Q", base + col_offset)
            pointer_ref = 0
            while True:
                pointer_ref = image.find(col_pointer, pointer_ref)
                if pointer_ref < 0:
                    break
                vtables.append(base + pointer_ref + 8)
                pointer_ref += 1
        results.append((name, type_rva, sorted(set(vtables))))
    return results


def find_bitset_candidates(data: bytes, base_address: int) -> list[tuple[int, int]]:
    # ACH00 + ACH26, for both zero-based and one-based bit numbering.
    values = (0x04000001, 0x08000002)
    matches = []
    for value in values:
        packed = struct.pack("<I", value)
        for offset in range(0, len(data) - len(packed) + 1, 4):
            if data[offset : offset + 4] == packed:
                matches.append((base_address + offset, value))
    return matches


def achievement_strings(image: bytes) -> list[tuple[int, str]]:
    results = []
    lower = image.lower()
    cursor = 0
    while True:
        cursor = lower.find(b"achievement", cursor)
        if cursor < 0:
            break
        start = cursor
        while start > 0 and 0x20 <= image[start - 1] < 0x7F:
            start -= 1
        end = cursor
        while end < len(image) and 0x20 <= image[end] < 0x7F:
            end += 1
        value = image[start:end].decode("ascii", "replace")
        if value and (start, value) not in results:
            results.append((start, value))
        cursor = max(cursor + 1, end)
    return results


def runtime_functions(pe: pefile.PE) -> list[tuple[int, int]]:
    result = []
    try:
        for item in pe.DIRECTORY_ENTRY_EXCEPTION:
            result.append((item.struct.BeginAddress, item.struct.EndAddress))
    except AttributeError:
        pass
    return result


def containing_function(rva: int, functions: list[tuple[int, int]]) -> tuple[int, int] | None:
    # The table is sorted by BeginAddress in a normal PE image.
    low, high = 0, len(functions)
    while low < high:
        middle = (low + high) // 2
        if functions[middle][0] <= rva:
            low = middle + 1
        else:
            high = middle
    if low:
        candidate = functions[low - 1]
        if candidate[0] <= rva < candidate[1]:
            return candidate
    return None


def table_function_map(
    tables: list[tuple[int, int, str | None, int | None, list[int]]],
    image: bytes,
    base: int,
    exec_ranges: list[tuple[int, int]],
) -> dict[int, list[tuple[int, int]]]:
    result: dict[int, list[tuple[int, int]]] = {}
    for object_offset, table, _, _, _ in tables:
        table_offset = table - base
        for slot in range(128):
            entry_offset = table_offset + slot * 8
            if entry_offset + 8 > len(image):
                break
            function = struct.unpack_from("<Q", image, entry_offset)[0]
            if not is_executable(function, base, exec_ranges):
                break
            result.setdefault(function - base, []).append((object_offset, slot))
    return result


def find_achievement_xrefs(
    image: bytes,
    base: int,
    pe: pefile.PE,
    tables: list[tuple[int, int, str | None, int | None, list[int]]],
    exec_ranges: list[tuple[int, int]],
) -> list[tuple[int, int, str, tuple[int, int] | None, list[tuple[int, int]]]]:
    strings = achievement_strings(image)
    by_address = {base + rva: (rva, value) for rva, value in strings}
    functions = runtime_functions(pe)
    table_map = table_function_map(tables, image, base, exec_ranges)
    disassembler = Cs(CS_ARCH_X86, CS_MODE_64)
    disassembler.detail = True
    results = []
    seen = set()
    for start, end in exec_ranges:
        code = image[start:end]
        for instruction in disassembler.disasm(code, base + start):
            targets = []
            for operand in instruction.operands:
                if operand.type == CS_OP_MEM and operand.mem.base == X86_REG_RIP:
                    targets.append(instruction.address + instruction.size + operand.mem.disp)
                elif operand.type == CS_OP_IMM:
                    targets.append(operand.imm)
            for target in targets:
                string = by_address.get(target)
                if string is None:
                    continue
                instruction_rva = instruction.address - base
                key = (instruction_rva, target)
                if key in seen:
                    continue
                seen.add(key)
                function = containing_function(instruction_rva, functions)
                owners = table_map.get(function[0], []) if function else []
                results.append((instruction_rva, string[0], string[1], function, owners))
    return results


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("pid", type=int)
    parser.add_argument("--module", default="socialclub.dll")
    parser.add_argument("--singleton-global-rva", type=lambda x: int(x, 0), default=0x4611C0)
    parser.add_argument("--singleton-size", type=lambda x: int(x, 0), default=0xE17F8)
    parser.add_argument("--achievement-xrefs", action="store_true")
    args = parser.parse_args()

    handle = kernel32.OpenProcess(
        PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, False, args.pid
    )
    if not handle:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        loaded = modules(handle)
        selected = next(
            ((base, path) for base, path in loaded if path.name.lower() == args.module.lower()),
            None,
        )
        if selected is None:
            raise SystemExit(f"module not loaded: {args.module}")
        base, path = selected
        pe = pefile.PE(str(path), fast_load=False)
        image_size = pe.OPTIONAL_HEADER.SizeOfImage
        image = read_memory(handle, base, image_size)
        ranges = executable_ranges(pe)
        print(f"module={path} base=0x{base:x} size=0x{len(image):x}")

        print("\nRTTI names containing 'achievement':")
        types = rtti_types_containing(image, base, b"achievement")
        if not types:
            print("  (none)")
        for name, type_rva, vtables in types:
            tables = ", ".join(f"0x{value:x}" for value in vtables) or "no vtable located"
            print(f"  type_rva=0x{type_rva:x} {name} -> {tables}")

        global_address = base + args.singleton_global_rva
        object_address = struct.unpack("<Q", read_memory(handle, global_address, 8))[0]
        print(
            f"\nsingleton_global=0x{global_address:x} object=0x{object_address:x} "
            f"requested_size=0x{args.singleton_size:x}"
        )
        if object_address == 0:
            raise SystemExit("Social Club singleton has not been initialized")
        object_data = read_memory(handle, object_address, args.singleton_size)
        print(f"object_bytes_read=0x{len(object_data):x}")

        print("\nRTTI-backed vtables referenced by the singleton allocation:")
        tables = probable_object_vtables(
            image, base, object_address, object_data, ranges
        )
        if not tables:
            print("  (none)")
        for offset, vtable, name, subobject_offset, entries in tables:
            entry_text = ", ".join(f"+0x{entry - base:x}" for entry in entries)
            type_text = name or "RTTI stripped"
            subobject_text = (
                f"0x{subobject_offset:x}" if subobject_offset is not None else "unknown"
            )
            print(
                f"  object+0x{offset:x} vtable=0x{vtable:x} "
                f"subobject={subobject_text} {type_text} [{entry_text}]"
            )

        print("\nACH00 + ACH26 bitset candidates in the singleton allocation:")
        matches = find_bitset_candidates(object_data, object_address)
        if not matches:
            print("  (none)")
        for address, value in matches:
            relative = address - object_address
            start = max(0, relative - 32)
            end = min(len(object_data), relative + 48)
            context = object_data[start:end].hex(" ")
            print(f"  object+0x{relative:x} value=0x{value:08x}\n    {context}")

        if args.achievement_xrefs:
            print("\nDirect code references to achievement strings:")
            xrefs = find_achievement_xrefs(image, base, pe, tables, ranges)
            if not xrefs:
                print("  (none)")
            for instruction_rva, string_rva, value, function, owners in xrefs:
                function_text = (
                    f"function=+0x{function[0]:x}..+0x{function[1]:x}"
                    if function
                    else "function=unknown"
                )
                owner_text = ", ".join(
                    f"object+0x{offset:x}[{slot}]" for offset, slot in owners
                ) or "not in discovered singleton vtables"
                print(
                    f"  insn=+0x{instruction_rva:x} string=+0x{string_rva:x} "
                    f"{function_text} owner={owner_text}\n    {value[:180]}"
                )
    finally:
        kernel32.CloseHandle(handle)


if __name__ == "__main__":
    main()
