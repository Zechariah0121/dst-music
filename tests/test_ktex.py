import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent.parent / 'helper'))
import struct
import tempfile
import unittest
from PIL import Image
import ktex


class Codec(unittest.TestCase):
    def test_raw_channels_orientation_and_exact_premultiplication(self):
        image = Image.new('RGBA', (256, 2))
        image.putdata([(17, 66, 133, a) for a in range(256)] +
                      [(201, 57, 9, 255-a) for a in range(256)])
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'image.tex'
            ktex.encode(image, path, premultiply=False)
            self.assertEqual(ktex.decode(path).tobytes(), image.tobytes())
            self.assertEqual(path.read_bytes()[18:18+4], bytes(image.getpixel((0, 1))))
            ktex.encode(image, path)
            pixels = list(ktex.decode(path).getdata())
            self.assertEqual(pixels, [tuple((c*a+127)//255 for c in rgb)+(a,)
                                     for *rgb, a in image.getdata()])
            ktex.encode(image, path, mode='RGB')
            self.assertEqual(ktex.layout(path.read_bytes())[0], 5)
            self.assertEqual(ktex.decode(path).convert('RGB').tobytes(), image.convert('RGB').tobytes())

    def test_dxt5_block_and_bottom_up_orientation(self):
        # Two BC3 blocks with constant alpha and distinct red/blue endpoints.
        red = bytes([128, 128]) + bytes(6) + struct.pack('<HHI', 0xf800, 0, 0)
        blue = bytes([255, 255]) + bytes(6) + struct.pack('<HHI', 0x001f, 0, 0)
        data = b'KTEX' + struct.pack('<IHHHI', 0xfffc2220, 4, 8, 16, 32) + red + blue
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'blocks.tex'
            path.write_bytes(data)
            image = ktex.decode(path)
            self.assertEqual(image.getpixel((0, 0)), (0, 0, 255, 255))
            self.assertEqual(image.getpixel((0, 7)), (255, 0, 0, 128))

    def test_invalid_containers_fail_closed(self):
        valid = b'KTEX' + struct.pack('<IHHHI', 0xfffc2240, 1, 1, 4, 4) + bytes(4)
        for invalid in (b'', valid[:-1], valid + b'x', valid[:12] + bytes(2) + valid[14:]):
            with self.assertRaises(ValueError):
                ktex.layout(invalid)

    def test_demultiply_half_ties_down_and_zero_alpha(self):
        image = Image.new('RGBA', (3, 1))
        image.putdata([(8, 8, 8, 48), (82, 85, 82, 164), (17, 66, 133, 0)])
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'masks.tex'
            ktex.encode(image, path, premultiply=False)
            self.assertEqual(list(ktex.decode(path, demultiply=True).getdata()),
                             [(42, 42, 42, 48), (127, 132, 127, 164), (17, 66, 133, 0)])


if __name__ == '__main__':
    unittest.main()
