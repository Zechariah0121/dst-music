import sys
sys.path.insert(0, str(__import__('pathlib').Path(__file__).parent.parent / 'helper'))
import importlib.util
import json
import os
from pathlib import Path
import unittest
import tempfile
import struct
from PIL import Image, ImageChops
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location('lyric_glyphs', Path(__file__).parent.parent / 'helper/lyric-glyphs.py')
glyph = importlib.util.module_from_spec(spec)
spec.loader.exec_module(glyph)


class Masks(unittest.TestCase):
    def font(self, image, packed=0, channel=15):
        return {'image': image, 'common': {'packed': str(packed), 'base': '24'},
                'info': {'size': '30'}, 'chars': {ord('O'): {
                    'x': '0', 'y': '0', 'width': str(image.width), 'height': str(image.height),
                    'xoffset': '0', 'yoffset': '0', 'xadvance': '20', 'chnl': str(channel)}}}

    def test_packed_channels_are_bmfont_bgra_bitmask_not_alpha(self):
        image = Image.new('RGBA', (2, 2), (17, 66, 133, 219))
        for channel, expected in [(1, 133), (2, 66), (4, 17), (8, 219)]:
            _, mask = glyph.glyph_mask(self.font(image, 1, channel), 'O')
            self.assertEqual(mask.getpixel((0, 0)), expected)

    def test_cpu_premultiply_exhaustive_integer_rounding(self):
        image = Image.new('RGBA', (256, 256))
        image.putdata([(c, 255-c, (c*17)%256, a) for a in range(256) for c in range(256)])
        actual = glyph.premultiply_rgba(image)
        for source, result in zip(image.getdata(), actual.getdata()):
            a = source[3]
            self.assertEqual(result, tuple((c*a+127)//255 for c in source[:3])+(a,))

    def test_raw_ktex_full_gradient_and_independent_packed_channels(self):
        ktech = 'missing-should-not-run'
        with tempfile.TemporaryDirectory() as folder:
            png, tex = Path(folder)/'gradient.png', Path(folder)/'gradient.tex'
            image = Image.new('RGBA', (256, 2))
            image.putdata([(255,255,255,a) for a in range(256)] + [(17,66,133,a) for a in range(256)])
            image.save(png)
            glyph.encode_ktex(png, tex, ktech)
            data = tex.read_bytes()
            self.assertEqual(data[:4],b'KTEX')
            header = struct.unpack_from('<I',data,4)[0]
            self.assertEqual((header>>4)&31,4)
            self.assertEqual((header>>13)&31,1)
            self.assertEqual(struct.unpack_from('<HHHI',data,8),(256,2,1024,2048))
            # Inspect GPU-facing bytes directly, independently of PNG decoding.
            pixels = list(Image.frombytes('RGBA',(256,2),data[18:]).getdata())
            for a in range(256):
                self.assertEqual(pixels[256+a],(a,a,a,a))
                self.assertEqual(pixels[a],tuple((c*a+127)//255 for c in (17,66,133))+(a,))
            self.assertEqual(ImageChops.difference(Image.open(png),image).getbbox(),None)
            # Use a true independent-channel texture, including RGB under A=0.
            fixture = Image.new('RGBA',(256,2))
            fixture.putdata([(17,66,133,a) for a in range(256)] + [(201,57,9,255-a) for a in range(256)])
            tex.write_bytes(data[:18] + fixture.transpose(Image.Transpose.FLIP_TOP_BOTTOM).tobytes())
            raw = glyph.raw_rgba_ktex(tex)
            self.assertEqual(raw.tobytes(),fixture.tobytes())
            for channel, value in [(1,133),(2,66),(4,17),(8,0)]:
                _, mask = glyph.glyph_mask(self.font(raw,1,channel),'O')
                self.assertEqual(mask.getpixel((0,0)),value)

    def test_black_outline_does_not_become_white_glow(self):
        image = Image.new('RGBA', (3, 1))
        image.putdata([(0, 0, 0, 255), (255, 255, 255, 255), (128, 128, 128, 128)])
        _, mask = glyph.glyph_mask(self.font(image), 'O')
        self.assertEqual(list(mask.getdata()), [0, 255, 64])

    def test_core_samples_original_once_at_double_density(self):
        image = Image.new('RGBA', (24, 24), (255, 255, 255, 0))
        for y in range(4, 20):
            for x in range(4, 20):
                if (x + y) % 3 == 0:
                    image.putpixel((x, y), (255, 255, 255, 255))
        font = self.font(image)
        font['info']['size'] = '48'
        metrics, masks = glyph.canvas_glyph(font, 'O')
        layer = metrics['layers']['core']
        self.assertEqual(masks[0].size, (2*layer['width'], 2*layer['height']))
        source = image.getchannel('A').resize((30, 30), Image.Resampling.LANCZOS)
        # Source glyph is at baseline y=-15, and the tight core has 1px padding.
        self.assertEqual(ImageChops.difference(masks[0].crop((2, 2, 32, 32)), source).getextrema(), (0, 0))
        twice = image.getchannel('A').resize((15, 15), Image.Resampling.LANCZOS).resize((30, 30), Image.Resampling.LANCZOS)
        self.assertIsNotNone(ImageChops.difference(source, twice).getbbox())
        self.assertEqual(metrics['advance'], 12.5)

    def test_real_atlas_holes_edges_blanks_and_alignment(self):
        if not os.environ.get('LYRIC_GLYPH_TEST_INDEX'):
            self.skipTest('Real atlas supplied by Node integration test')
        data = json.loads(Path(os.environ['LYRIC_GLYPH_TEST_INDEX']).read_text())
        metadata = data['metadata']
        atlas = Image.open(os.environ['LYRIC_GLYPH_TEST_PNG']).convert('RGBA')
        raw = glyph.raw_rgba_ktex(os.environ['LYRIC_GLYPH_TEST_TEX'])
        for channel in ('R','G','B','A'):
            self.assertEqual(ImageChops.difference(raw.getchannel(channel),atlas.getchannel('A')).getextrema(),(0,0))
        if os.environ.get('LYRIC_GLYPH_TEST_DECODED'):
            decoded = Image.open(os.environ['LYRIC_GLYPH_TEST_DECODED']).convert('RGBA')
            self.assertEqual(decoded.size, atlas.size)
            self.assertEqual(ImageChops.difference(atlas.getchannel('A'), decoded.getchannel('A')).getextrema(), (0, 0))
        for mode in ('mono', 'smooth'):
            fonts = metadata['fonts'][mode]
            self.assertEqual(fonts['baseSize'], 30)
            for char, g in fonts['glyphs'].items():
                for layer in ('core', 'near', 'far'):
                    r = metadata['elements'][g[layer]]
                    tile = atlas.crop((r['x'], r['y'], r['x']+r['width'], r['y']+r['height']))
                    a = tile.getchannel('A')
                    logical = g['layers'][layer]
                    density = 2 if layer == 'core' else 1
                    self.assertEqual(tile.size, (logical['width']*density, logical['height']*density))
                    # No rectangular alpha fringe; blank glyphs never emit light.
                    for p in [(0,0), (tile.width-1,0), (0,tile.height-1), (tile.width-1,tile.height-1)]:
                        self.assertEqual(a.getpixel(p), 0)
                    self.assertIsNone(a.crop((0,0,tile.width,1)).getbbox())
                    self.assertIsNone(a.crop((0,tile.height-1,tile.width,tile.height)).getbbox())
                    self.assertIsNone(a.crop((0,0,1,tile.height)).getbbox())
                    self.assertIsNone(a.crop((tile.width-1,0,tile.width,tile.height)).getbbox())
                    if char == ' ':
                        self.assertIsNone(a.getbbox())
                    if char == 'O' and layer == 'core':
                        box = a.getbbox()
                        self.assertIsNotNone(box)
                        self.assertEqual(a.getpixel(((box[0]+box[2])//2, (box[1]+box[3])//2)), 0)
                        self.assertEqual(a.getextrema()[1], 255)
                self.assertEqual(g['width'], g['layers']['core']['width'])
                self.assertEqual(g['height'], g['layers']['core']['height'])
                self.assertGreater(g['layers']['far']['width'],g['layers']['near']['width']) if char != ' ' else None
                # All layers map their source glyph to the same baseline origin.
                if char != ' ':
                    centers = []
                    for layer in ('core','near','far'):
                        r = metadata['elements'][g[layer]]
                        a = atlas.crop((r['x'],r['y'],r['x']+r['width'],r['y']+r['height'])).getchannel('A')
                        l = g['layers'][layer]
                        total = sum(a.getdata())
                        cx = sum(v*(i % a.width+.5) for i,v in enumerate(a.getdata()))/total/l['pixelScale']
                        cy = sum(v*(i // a.width+.5) for i,v in enumerate(a.getdata()))/total/l['pixelScale']
                        centers.append((cx+l['offsetX']-l['width']/2, l['offsetY']+l['height']/2-cy))
                    for cx,cy in centers[1:]:
                        self.assertLess(abs(cx-centers[0][0]),1.2)
                        self.assertLess(abs(cy-centers[0][1]),1.2)

    def test_real_250_cjk_budget_and_halo_reach(self):
        if not os.environ.get('LYRIC_GLYPH_TEST_SOURCE'):
            self.skipTest('Real source supplied by Node integration test')
        fonts = {}
        for name in glyph.SOURCES:
            folder = next(Path(os.environ['LYRIC_GLYPH_TEST_SOURCE']).glob(name+'-*'))
            tree = ET.parse(folder/'font.fnt').getroot()
            fonts[name] = {'info':tree.find('info').attrib,'common':tree.find('common').attrib,
                           'chars':{int(c.get('id')):dict(c.attrib) for c in tree.findall('./chars/char')},
                           'image':Image.open(folder/('font.raw-rgba-v2.png' if int(tree.find('common').get('packed',0)) else 'font.straight-v3-pillow.png')).convert('RGBA')}
            if int(tree.find('common').get('packed',0)):
                data = (folder/'font.tex').read_bytes()
                word = struct.unpack_from('<I',data,4)[0]
                self.assertEqual((word>>4)&31,4)
                self.assertEqual((word>>13)&31,1)
                w,h,pitch,length = struct.unpack_from('<HHHI',data,8)
                self.assertEqual(pitch,w*4)
                self.assertEqual(len(data),18+length)
                # Compare each cached packed channel directly with GPU payload,
                # with the vertical orientation specified by the KTEX format.
                expected = Image.frombytes('RGBA',(w,h),data[18:]).transpose(Image.Transpose.FLIP_TOP_BOTTOM)
                for channel in ('R','G','B','A'):
                    self.assertEqual(ImageChops.difference(fonts[name]['image'].getchannel(channel),expected.getchannel(channel)).getextrema(),(0,0))
                self.assertIsNotNone(ImageChops.difference(expected.getchannel('R'),expected.getchannel('A')).getbbox())
        chars = [chr(c) for c in range(0x4e00,0x9fff) if c in fonts['fallback_full_packed']['chars']][:250]
        self.assertEqual(len(chars),250)
        atlas, metadata = glyph.compile_glyphs(fonts, chars + list('ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 !?.,'))
        self.assertLessEqual(atlas.width,2048)
        metrics, masks = glyph.canvas_glyph(fonts['fallback_full_packed'],'雨')
        self.assertEqual(metrics['source']['size'],28)
        # The far halo follows the glyph with substantially wider reach, and
        # the clear boundary leaves room for bilinear sampling without a seam.
        near, far = masks[1:]
        nb, fb = near.getbbox(), far.getbbox()
        self.assertGreater(fb[2]-fb[0], nb[2]-nb[0]+12)
        self.assertGreater(fb[3]-fb[1], nb[3]-nb[1]+12)
        self.assertEqual(fb[0],2)
        self.assertEqual(fb[1],2)
        self.assertEqual(far.width-fb[2],2)
        self.assertEqual(far.height-fb[3],2)
        self.assertGreater(far.getextrema()[1],200)
        self.assertGreater(near.getextrema()[1],150)


if __name__ == '__main__':
    unittest.main()
