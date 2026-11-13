"""Small KTEX codec for local bridge assets, implemented with stdlib and Pillow.

KTEX stores scanlines bottom-up. Raw packed-font channels are independent masks.
Only callers rendering ordinary color textures should request demultiplication.
"""
import io
import struct
from pathlib import Path
from PIL import Image


def layout(data):
    if len(data) < 18 or data[:4] != b'KTEX':
        raise ValueError('LYRIC_GLYPH_TEX_INVALID')
    word = struct.unpack_from('<I', data, 4)[0]
    compression, kind, count = (word >> 4) & 31, (word >> 9) & 15, (word >> 13) & 31
    if compression not in (2, 4, 5) or kind != 1 or not count:
        raise ValueError('LYRIC_GLYPH_TEX_FORMAT_UNSUPPORTED')
    offset = 8 + count * 10
    if offset > len(data):
        raise ValueError('LYRIC_GLYPH_TEX_INVALID')
    first = None
    for index in range(count):
        width, height, pitch, length = struct.unpack_from('<HHHI', data, 8 + index * 10)
        channels = 4 if compression == 4 else 3
        expected_pitch = ((width + 3) // 4) * 16 if compression == 2 else width * channels
        expected_length = expected_pitch * ((height + 3) // 4 if compression == 2 else height)
        if not width or not height or pitch != expected_pitch or length != expected_length:
            raise ValueError('LYRIC_GLYPH_TEX_INVALID')
        if first is None:
            first = (width, height, offset, length, count)
        offset += length
    if offset != len(data):
        raise ValueError('LYRIC_GLYPH_TEX_INVALID')
    return compression, first


def encode(image, target, mode='RGBA', premultiply=True):
    if mode not in ('RGBA', 'RGB'):
        raise ValueError('LYRIC_GLYPH_TEX_FORMAT_UNSUPPORTED')
    image = image.convert(mode)
    if mode == 'RGBA' and premultiply:
        image = Image.merge('RGBA', image.convert('RGBa').split())
    width, height = image.size
    pitch = width * len(mode)
    if not width or not height or width > 65535 or height > 65535 or pitch > 65535:
        raise ValueError('LYRIC_GLYPH_TEX_INVALID')
    pixels = image.transpose(Image.Transpose.FLIP_TOP_BOTTOM).tobytes()
    # Platform 0, 2D texture 1, one mip, flags 0. Unused high bits are ones,
    # matching the game container convention.
    header = 0xfffc0000 | ((4 if mode == 'RGBA' else 5) << 4) | (1 << 9) | (1 << 13)
    Path(target).write_bytes(b'KTEX' + struct.pack('<IHHHI', header, width, height, pitch, len(pixels)) + pixels)


def decode(source, demultiply=False):
    data = Path(source).read_bytes()
    compression, (width, height, offset, length, _) = layout(data)
    payload = data[offset:offset + length]
    if compression == 2:
        # DDS legacy DXT5 header, one mip. Pillow owns BC3 decompression.
        header = struct.pack('<7I', 124, 0x81007, height, width, length, 0, 0)
        header += bytes(44)
        header += struct.pack('<II4s5I', 32, 4, b'DXT5', 0, 0, 0, 0, 0)
        header += struct.pack('<5I', 0x1000, 0, 0, 0, 0)
        with Image.open(io.BytesIO(b'DDS ' + header + payload)) as dds:
            image = dds.convert('RGBA')
    else:
        image = Image.frombytes('RGBA' if compression == 4 else 'RGB', (width, height), payload).convert('RGBA')
    image = image.transpose(Image.Transpose.FLIP_TOP_BOTTOM)
    if demultiply:
        # Match ktools' nearest demultiplication with half ties down, including
        # its alpha-zero handling. Packed channel masks never take this branch.
        image.putdata([(min(255, (r * 255 + (a - 1) // 2) // a), min(255, (g * 255 + (a - 1) // 2) // a),
                        min(255, (b * 255 + (a - 1) // 2) // a), a) if a else (r, g, b, a)
                       for r, g, b, a in image.getdata()])
    return image
