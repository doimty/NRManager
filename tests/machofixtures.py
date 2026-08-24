#!/usr/bin/env python3
"""Synthesised Mach-O images for host tests.

Not a test module -- the discovery pattern is ``test*.py``, so this is only ever
imported.

Two callers need Mach-O bytes for different reasons, and they had drifted apart:
``test_package_end_to_end`` only needed a file whose magic satisfies
``is_macho_file``, while the preference-bundle cell-class gate reads real
``__TEXT`` sections. A four-byte stub silently became "not a Mach-O image" the
moment a second consumer appeared, so the fixture lives in one place and is
structurally valid for both.
"""

from __future__ import annotations

import struct
from typing import Iterable, Sequence, Tuple


MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
CPU_TYPE_ARM64 = 0x0100000C
LC_SEGMENT_64 = 0x19

# mach_header_64, segment_command_64, section_64. Pinned by size assertion below,
# because getting section_64 wrong by its trailing reserved field shifts every
# offset and the resulting garbage reads as "no strings found" -- a fixture bug
# indistinguishable from a passing gate.
HEADER_FORMAT = "<IiiIIIII"
SEGMENT_FORMAT = "<II16sQQQQiiII"
SECTION_FORMAT = "<16s16sQQIIIIIIII"

assert struct.calcsize(HEADER_FORMAT) == 32
assert struct.calcsize(SEGMENT_FORMAT) == 72
assert struct.calcsize(SECTION_FORMAT) == 80

_SLICE_ALIGNMENT = 4096


def _pad16(name: bytes) -> bytes:
    return name.ljust(16, b"\0")


def macho_slice(sections: Sequence[Tuple[bytes, bytes]], segment: bytes = b"__TEXT") -> bytes:
    """One 64-bit Mach-O image carrying a single LC_SEGMENT_64 of ``sections``."""
    segment_size = (struct.calcsize(SEGMENT_FORMAT)
                    + struct.calcsize(SECTION_FORMAT) * len(sections))
    payload_start = struct.calcsize(HEADER_FORMAT) + segment_size
    body = b""
    entries = []
    for name, content in sections:
        entries.append((name, payload_start + len(body), len(content)))
        body += content
    image = struct.pack(
        HEADER_FORMAT, MH_MAGIC_64, CPU_TYPE_ARM64, 0, 6, 1, segment_size, 0, 0
    )
    image += struct.pack(
        SEGMENT_FORMAT,
        LC_SEGMENT_64, segment_size, _pad16(segment),
        0, payload_start + len(body), payload_start, len(body), 7, 5,
        len(sections), 0,
    )
    for name, offset, size in entries:
        image += struct.pack(
            SECTION_FORMAT, _pad16(name), _pad16(segment),
            offset, size, offset, 0, 0, 0, 0, 0, 0, 0,
        )
    return image + body


def fat_macho(images: Sequence[bytes], subtypes: Sequence[int] = (0, 2)) -> bytes:
    """A fat wrapper. Default subtypes are arm64 and arm64e, the shipped pair."""
    header = struct.pack(">II", FAT_MAGIC, len(images))
    entries = b""
    body = b""
    offset = _SLICE_ALIGNMENT
    for index, image in enumerate(images):
        subtype = subtypes[index] if index < len(subtypes) else 0
        entries += struct.pack(">IIIII", CPU_TYPE_ARM64, subtype, offset, len(image), 14)
        body += image.ljust(_SLICE_ALIGNMENT, b"\0")
        offset += _SLICE_ALIGNMENT
    return (header + entries).ljust(_SLICE_ALIGNMENT, b"\0") + body


def c_strings(values: Iterable[str]) -> bytes:
    """The byte layout of a __cstring or __objc_classname section."""
    return b"".join(value.encode() + b"\0" for value in values)


def preference_bundle_binary(
    class_names: Sequence[str],
    string_literals: Sequence[str] = (),
    slices: int = 2,
) -> bytes:
    """A stand-in for the preference bundle: classes defined, literals chosen.

    ``class_names`` land in __objc_classname, which is where the runtime records
    every class an image defines. ``string_literals`` land in __cstring, which is
    where an NSString literal's bytes live -- that is the distinction the
    cell-class gate turns on.
    """
    image = macho_slice((
        (b"__objc_classname", c_strings(class_names)),
        (b"__cstring", c_strings(string_literals)),
    ))
    return fat_macho([image] * slices) if slices > 1 else image
