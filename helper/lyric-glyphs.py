"""Private, local-only BMFont raster compiler; no installed game files are changed.

The original font/license files remain in state/font-source with provenance.
All returned metrics use 30px nominal type and a baseline origin, y upwards.
"""
import io
import json
import math
import os
from pathlib import Path
import struct
import sys
import uuid
import zipfile
import xml.etree.ElementTree as ET
from PIL import Image, ImageChops, ImageFilter
from ktex import encode as write_ktex, decode as read_ktex

SIZE = 30
CORE_DENSITY = 2
HALO_SIGMAS = (2.5, 7.0)
HALO_GAINS = {'near': 1.2, 'far': 2.8}
SOURCES = ('ptmono32', 'opensans50', 'fallback', 'fallback_full_packed')


def rgba_ktex_layout(data):
    """Validate uncompressed RGBA 2D KTEX, returning first mip bounds.

    Layout checked against ktools src/common/ktex/{specs.cpp,ktex.cpp}:
    https://github.com/nsimplex/ktools/tree/master/src/common/ktex
    A header word follows magic; all 10-byte mip descriptors precede pixels.
    """
    if len(data) < 18 or data[:4] != b'KTEX':
        raise ValueError('LYRIC_GLYPH_TEX_INVALID')
    header = struct.unpack_from('<I', data, 4)[0]
    count = (header >> 13) & 31
    if (header >> 4) & 31 != 4 or (header >> 9) & 15 != 1 or not count:
        raise ValueError('LYRIC_GLYPH_TEX_FORMAT_UNSUPPORTED')
    offset = 8 + 10 * count
    if offset > len(data):
        raise ValueError('LYRIC_GLYPH_TEX_INVALID')
    first = None
    for i in range(count):
        width, height, pitch, length = struct.unpack_from('<HHHI', data, 8 + 10*i)
        if not width or not height or pitch != width*4 or length != width*height*4:
            raise ValueError('LYRIC_GLYPH_TEX_INVALID')
        if first is None:
            first = (width, height, offset, length, count)
        offset += length
    if offset != len(data):
        raise ValueError('LYRIC_GLYPH_TEX_INVALID')
    return first


def raw_rgba_ktex(path):
    data = Path(path).read_bytes()
    width, height, offset, length, _ = rgba_ktex_layout(data)
    # KTEX scanlines are bottom-up. Packed BMFont channels are independent masks,
    # so neither premultiplication nor demultiplication is valid for these bytes.
    return Image.frombytes('RGBA', (width, height), data[offset:offset+length]).transpose(Image.Transpose.FLIP_TOP_BOTTOM)


def premultiply_rgba(image):
    # Pillow's integer RGBa conversion is exhaustively checked against
    # (channel * alpha + 127) // 255 for all 65,536 channel/alpha pairs.
    return Image.merge('RGBA', image.convert('RGBa').split())


def encode_ktex(png, tex, ktech=None):
    with Image.open(png) as image:
        write_ktex(image, tex)


def atomic_write(path, data):
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex + '.tmp')
    try:
        temporary.write_bytes(data)
        publish_source(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def publish_source(temporary, path):
    # Cache members are immutable. Another process may have committed the same
    # complete file and opened it on Windows, which then forbids replacement.
    if path.exists():
        return
    try:
        os.replace(temporary, path)
    except PermissionError:
        if not path.exists():
            raise


def source_fonts(archive, cache, ktech=None):
    result = {}
    with zipfile.ZipFile(archive) as outer:
        for name in SOURCES:
            member = 'fonts/' + name + '.zip'
            info = outer.getinfo(member)
            folder = Path(cache) / (name + '-' + format(info.CRC, '08x'))
            folder.mkdir(parents=True, exist_ok=True)
            with zipfile.ZipFile(io.BytesIO(outer.read(member))) as inner:
                # Only known filenames are extracted; never trust ZIP paths.
                for file in ('font.fnt', 'font.tex', 'license.txt'):
                    if file in inner.namelist() and not (folder / file).exists():
                        atomic_write(folder / file, inner.read(file))
            provenance = {'archive': str(Path(archive).resolve()), 'member': member,
                          'crc32': format(info.CRC, '08x'), 'use': 'Private local game rendering; not redistributed'}
            atomic_write(folder / 'provenance.json', json.dumps(provenance, indent=2).encode('utf8'))
            tree = ET.parse(folder / 'font.fnt').getroot()
            packed = int(tree.find('common').get('packed', 0))
            # Versioned names prevent an old demultiplied packed cache from
            # poisoning new builds. Original font/license and old caches survive.
            png = folder / ('font.raw-rgba-v2.png' if packed else 'font.straight-v3-pillow.png')
            if not png.exists():
                # Multiple helper processes may share this cache. A decoded PNG
                # becomes visible only after the decoder closes its unique output.
                temporary = folder / ('font.' + uuid.uuid4().hex + '.png')
                try:
                    if packed:
                        raw_rgba_ktex(folder / 'font.tex').save(temporary)
                    else:
                        read_ktex(folder / 'font.tex', demultiply=True).save(temporary)
                    publish_source(temporary, png)
                finally:
                    temporary.unlink(missing_ok=True)
            result[name] = {'info': tree.find('info').attrib, 'common': tree.find('common').attrib,
                            'chars': {int(c.get('id')): dict(c.attrib) for c in tree.findall('./chars/char')},
                            'image': Image.open(png).convert('RGBA')}
    return result


def glyph_mask(font, char):
    c = font['chars'][ord(char)]
    x, y, w, h = (int(c[k]) for k in ('x', 'y', 'width', 'height'))
    crop = font['image'].crop((x, y, x + w, y + h))
    if int(font['common'].get('packed', 0)):
        channel = {1: 'B', 2: 'G', 4: 'R', 8: 'A'}.get(int(c['chnl']))
        if channel is None:
            raise ValueError('LYRIC_GLYPH_CHANNEL_INVALID')
        mask = crop.getchannel(channel)
    else:
        # White letter fill and black outline share alpha in outlined OpenSans.
        # Multiplying the fill color by alpha removes that outline without erosion.
        rgb = ImageChops.lighter(ImageChops.lighter(crop.getchannel('R'), crop.getchannel('G')), crop.getchannel('B'))
        mask = ImageChops.multiply(rgb, crop.getchannel('A'))
    return c, mask


def canvas_glyph(font, char):
    c, mask = glyph_mask(font, char)
    scale = SIZE / abs(int(font['info']['size']))
    advance = round(int(c['xadvance']) * scale, 4)
    x = int(c['xoffset']) * scale
    y = (int(c['yoffset']) - int(font['common']['base'])) * scale
    blank = char.isspace()
    # Each layer has its own baseline-relative bounds. Core samples the original
    # BMFont directly at nominal 60px; never enlarge a previously reduced 30px
    # mask. A low-resolution fallback source cannot gain detail this way, but
    # avoids a second lossy resample. Halos remain 1x to bound atlas memory.
    layers, masks = {}, []
    for name, density, sigma in [('core', CORE_DENSITY, 0),
                                  ('near', 1, HALO_SIGMAS[0]),
                                  ('far', 1, HALO_SIGMAS[1])]:
        pad = math.ceil(3.5 * sigma) + 1 if sigma else 1
        left, top = math.floor(x) - pad, math.floor(y) - pad
        right = math.ceil(x + mask.width * scale) + pad
        bottom = math.ceil(y + mask.height * scale) + pad
        if blank:
            left = top = 0
            right = bottom = 1
        width, height = right - left, bottom - top
        canvas = Image.new('L', (width * density, height * density))
        if not blank:
            resized = mask.resize((max(1, round(mask.width * scale * density)),
                                   max(1, round(mask.height * scale * density))), Image.Resampling.LANCZOS)
            canvas.paste(resized, (round((x-left)*density), round((y-top)*density)))
            if sigma:
                canvas = canvas.filter(ImageFilter.GaussianBlur(sigma))
                gain = HALO_GAINS[name]
                canvas = canvas.point([min(255, round(value * gain)) for value in range(256)])
                # Trim only transparent pixels after gain. Retain two clear
                # pixels for bilinear sampling, and move the baseline anchor
                # with the crop so differently sized layers still coincide.
                box = canvas.getbbox()
                if box:
                    crop = (max(0, box[0]-2), max(0, box[1]-2),
                            min(canvas.width, box[2]+2), min(canvas.height, box[3]+2))
                    canvas = canvas.crop(crop)
                    left, top = left + crop[0], top + crop[1]
                    right, bottom = left + canvas.width, top + canvas.height
                    width, height = canvas.size
        layers[name] = {'width': width, 'height': height,
                        'offsetX': (left + right) / 2, 'offsetY': -(top + bottom) / 2,
                        'pixelScale': density}
        masks.append(canvas)
    return {**layers['core'], 'advance': advance, 'blank': blank,
            'layers': layers, 'source': {'size': abs(int(font['info']['size'])),
                                      'width': mask.width, 'height': mask.height}}, masks


def pack(items, size):
    x = y = row = 0
    placements = []
    # Similar-height rows avoid wasting 2x core rows on small Latin/space tiles.
    for name, mask in sorted(items, key=lambda item: (-item[1].height, -item[1].width, item[0])):
        w, h = mask.size
        if x + w + 2 > size:
            x, y, row = 0, y + row, 0
        if y + h + 2 > size:
            return None
        placements.append((name, mask, x + 1, y + 1))
        x += w + 2
        row = max(row, h + 2)
    return placements


def compile_glyphs(fonts, chars):
    output = {'fonts': {}, 'missing': [], 'elements': {}}
    items, shared = [], {}
    for mode, primary in [('mono', 'ptmono32'), ('smooth', 'opensans50')]:
        glyphs = {}
        output['fonts'][mode] = {'size': SIZE, 'baseSize': SIZE, 'lineHeight': SIZE,
                                 'baseline': 24, 'glyphs': glyphs}
        for char in chars:
            source = next((name for name in (primary, 'fallback', 'fallback_full_packed')
                           if ord(char) in fonts[name]['chars']), None)
            if source is None:
                if char not in output['missing']:
                    output['missing'].append(char)
                continue
            identity = (source, char)
            if identity not in shared:
                metrics, masks = canvas_glyph(fonts[source], char)
                prefix = 'g' + str(len(shared))
                for suffix, mask in zip(('core', 'near', 'far'), masks):
                    element = prefix + '_' + suffix + '.tex'
                    metrics[suffix] = element
                    items.append((element, mask))
                shared[identity] = metrics
            glyphs[char] = shared[identity]
    for size in (1024, 2048):
        placements = pack(items, size)
        if placements is not None:
            break
    else:
        raise ValueError('LYRIC_GLYPH_ATLAS_FULL')
    atlas = Image.new('RGBA', (size, size), (255, 255, 255, 0))
    for name, mask, x, y in placements:
        tile = Image.new('RGBA', mask.size, 'white')
        tile.putalpha(mask)
        atlas.paste(tile, (x, y))
        output['elements'][name] = {'x': x, 'y': y, 'width': mask.width, 'height': mask.height}
    output['atlasSize'] = size
    return atlas, output


def main():
    if sys.argv[1] == '--encode-ktex':
        encode_ktex(*sys.argv[2:])
        return
    archive, ktech, cache, request, png, result = sys.argv[1:]
    chars = json.loads(Path(request).read_text(encoding='utf8'))
    fonts = source_fonts(archive, cache, ktech)
    atlas, descriptor = compile_glyphs(fonts, chars)
    atlas.save(png)
    Path(result).write_text(json.dumps(descriptor, ensure_ascii=True), encoding='utf8')


if __name__ == '__main__':
    try:
        main()
    except ValueError as error:
        # The caller surfaces only fixed codes, never private text or font output.
        sys.stderr.write(str(error) if str(error).startswith('LYRIC_GLYPH_') else 'LYRIC_GLYPH_COMPILE_FAILED')
        sys.exit(1)
