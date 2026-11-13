"""Private bridge image compiler. Inputs/outputs are supplied by game-assets.mjs.

No network access; never receives account cookies. Pillow handles raster decoding,
QR modules, deterministic UI geometry and the portable KTEX encoder.
"""
import json
import sys
from io import BytesIO
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter, ImageOps
from ktex import encode as write_ktex

Image.MAX_IMAGE_PIXELS = 16_777_216


def cover(source, target):
    with Image.open(source) as original:
        if original.width > 8192 or original.height > 8192 or original.width * original.height > Image.MAX_IMAGE_PIXELS:
            raise ValueError('Image dimensions exceed limit')
        image = ImageOps.fit(ImageOps.exif_transpose(original).convert('RGB'), (512, 512), method=Image.Resampling.LANCZOS)
        image.save(target, 'PNG')


def qr(source, target):
    modules = json.loads(Path(source).read_text(encoding='utf-8'))
    n = len(modules)
    if not 21 <= n <= 177 or any(len(row) != n for row in modules):
        raise ValueError('Invalid QR matrix')
    # Integer module scaling and four-module quiet zone preserve scan quality.
    scale = 512 // (n + 8)
    image = Image.new('RGB', (512, 512), 'white')
    draw = ImageDraw.Draw(image)
    margin = (512 - n * scale) // 2
    for y, row in enumerate(modules):
        for x, value in enumerate(row):
            if value:
                a, b = margin + x * scale, margin + y * scale
                draw.rectangle((a, b, a + scale - 1, b + scale - 1), fill='black')
    image.save(target, 'PNG')


def qr_image(target):
    max_bytes = 1024 * 1024
    source = sys.stdin.buffer.read(max_bytes + 1)
    if len(source) > max_bytes:
        raise ValueError('QR image exceeds byte limit')
    with Image.open(BytesIO(source), formats=['PNG']) as original:
        if not (32 <= original.width <= 1024 and 32 <= original.height <= 1024):
            raise ValueError('QR image dimensions out of range')
        if getattr(original, 'is_animated', False):
            raise ValueError('Expected a static QR image')
        white = Image.new('RGBA', original.size, 'white')
        pixels = Image.alpha_composite(white, original.convert('RGBA')).convert('L')
        pixels = pixels.point(lambda value: 0 if value < 128 else 255).convert('RGB')
        # Preserve the source quiet zone and scale small images by whole pixels.
        scale = 480 // max(pixels.size)
        if scale:
            pixels = pixels.resize((pixels.width * scale, pixels.height * scale), Image.Resampling.NEAREST)
        else:
            pixels = ImageOps.contain(pixels, (480, 480), method=Image.Resampling.NEAREST)
        image = Image.new('RGB', (512, 512), 'white')
        image.paste(pixels, ((512 - pixels.width) // 2, (512 - pixels.height) // 2))
        image.save(target, 'PNG')


def ui(target):
    import math
    size = 2048
    atlas = Image.new('RGBA', (size, size))
    regions = {}

    def place(name, x, y, im):
        atlas.alpha_composite(im, (x, y))
        regions[name + '.tex'] = (x, y, im.width, im.height)

    def glass(w, h, radius, color, glows=(), border=0):
        # Render shape and its border at double resolution for clean corners.
        f = 2
        mask = Image.new('L', (w*f, h*f))
        d = ImageDraw.Draw(mask)
        d.rounded_rectangle((2*f, 2*f, (w-2)*f-1, (h-2)*f-1), radius=radius*f, fill=255)
        mask = mask.resize((w,h), Image.Resampling.LANCZOS)
        layer = Image.new('RGBA', (w,h), color)
        for cx, cy, rx, ry, rgb, opacity in glows:
            glow = Image.new('RGBA', (w,h))
            gd = ImageDraw.Draw(glow)
            gd.ellipse((cx-rx, cy-ry, cx+rx, cy+ry), fill=(*rgb,opacity))
            glow = glow.filter(ImageFilter.GaussianBlur(max(8, min(rx,ry)//2)))
            layer = Image.alpha_composite(layer, glow)
        layer.putalpha(Image.composite(layer.getchannel('A'), Image.new('L',(w,h)), mask))
        if border:
            edge = Image.new('RGBA', (w*f, h*f))
            ed = ImageDraw.Draw(edge)
            ed.rounded_rectangle((2*f, 2*f, (w-2)*f-1, (h-2)*f-1),
                                 radius=radius*f, outline=(255,255,255,border), width=f)
            layer.alpha_composite(edge.resize((w,h),Image.Resampling.LANCZOS))
        return layer

    # Neutral masks are tinted at runtime by the active music provider.
    white = (255, 255, 255)
    place('shell', 0, 0, glass(1190, 660, 30, (182,182,182,246),
                             [(176,62,270,142,white,162), (1000,628,292,144,white,84)]))
    place('sidebar', 1200, 0, glass(204, 640, 22, (190,190,190,224),
                                    [(10,56,94,136,white,150)], 120))
    place('player', 0, 670, glass(915, 76, 16, (198,198,198,232),
                                  [(460,4,440,20,white,128)], 130))
    place('ambient', 0, 756, glass(915, 76, 16, (255,255,255,0),
                                   [(440,26,355,31,white,153)]))
    place('selected', 920, 670, glass(204, 36, 12, (255,255,255,212)))
    place('glass_card', 920, 716, glass(360, 200, 15, (255,255,255,233)))
    place('glass_button', 1290, 650, glass(192, 48, 10, (255,255,255,255)))
    place('glass_pill', 1290, 708, glass(160, 40, 20, (255,255,255,255)))
    place('shell_rim', 0, 1388, glass(1190, 660, 30, (255,255,255,0), border=255))
    # The specular layer has clear margins so its travel remains inside the rim.
    place('sheen', 1200, 1340, glass(800, 524, 72, (255,255,255,0),
          [(216,160,134,64,white,210), (548,350,120,48,white,88)]))
    def white_mask(w, h, radius):
        im = Image.new('RGBA', (w*4,h*4)); d = ImageDraw.Draw(im)
        d.rounded_rectangle((8,8,(w-2)*4-1,(h-2)*4-1), radius=radius*4, fill='white')
        return im.resize((w,h),Image.Resampling.LANCZOS)
    place('card',0,1250,white_mask(256,128,14))
    place('button',266,1250,white_mask(192,64,12))
    place('pill',468,1250,white_mask(192,48,24))
    place('circle',1460,708,white_mask(64,64,32))
    place('square',1534,708,Image.new('RGBA',(64,64),'white'))
    # Legacy tintable primitives retain their original semantics.
    for name, wh, ellipse, outline in [('panel',(256,256),False,False),('outline',(192,64),False,True),('circle_outline',(128,128),True,True),('shadow',(256,128),False,False)]:
        w,h=wh; im=Image.new('RGBA',(w*4,h*4)); d=ImageDraw.Draw(im); box=(8,8,(w-2)*4,(h-2)*4)
        if name=='shadow':
            d.rounded_rectangle((64,96,(w-16)*4,(h-24)*4),radius=80,fill='white'); im=im.filter(ImageFilter.GaussianBlur(36))
        elif ellipse: d.ellipse(box,outline='white',width=8)
        elif outline: d.rounded_rectangle(box,radius=48,outline='white',width=8)
        else: d.rounded_rectangle(box,radius=88,fill='white')
        coords={'panel':(0,850),'outline':(266,850),'circle_outline':(468,850),'shadow':(606,850)}[name]
        place(name,*coords,im.resize((w,h),Image.Resampling.LANCZOS))

    def icon(name):
        f=4; im=Image.new('RGBA',(256,256)); d=ImageDraw.Draw(im)
        def line(points,width=3): d.line([(int(x*f),int(y*f)) for x,y in points],fill='white',width=width*f,joint='curve')
        def ellipse(box,width=3,fill=None): d.ellipse(tuple(int(v*f) for v in box),outline='white' if fill is None else None,fill=fill,width=width*f)
        if name=='home': line([(13,30),(32,14),(51,30),(47,30),(47,49),(35,49),(35,37),(28,37),(28,49),(17,49),(17,30)])
        elif name=='charts':
            for y in (21,32,43): line([(17,y),(47,y)],2)
            line([(13,18),(13,46)],2)
        elif name=='music': line([(27,42),(27,20),(46,16),(46,37)],3); ellipse((18,40,28,47),fill='white'); ellipse((37,35,47,42),fill='white')
        elif name=='list':
            for y in (21,32,43): line([(23,y),(49,y)],2); ellipse((14,y-1,17,y+2),fill='white')
        elif name=='settings':
            ellipse((19,19,45,45),3); ellipse((27,27,37,37),2)
            for i in range(8):
                a=i*math.pi/4; line([(32+14*math.cos(a),32+14*math.sin(a)),(32+19*math.cos(a),32+19*math.sin(a))],3)
        elif name=='search': ellipse((14,14,40,40),3); line([(38,38),(50,50)],3)
        elif name in ('previous','next','play'):
            pts={'previous':[(18,32),(42,18),(42,46)],'next':[(46,32),(22,18),(22,46)],'play':[(22,16),(47,32),(22,48)]}[name]; d.polygon([(x*f,y*f) for x,y in pts],fill='white')
            if name!='play': line([(16 if name=='previous' else 48,18),(16 if name=='previous' else 48,46)],3)
        elif name=='pause':
            d.rounded_rectangle((20*f,17*f,26*f,47*f),radius=2*f,fill='white'); d.rounded_rectangle((38*f,17*f,44*f,47*f),radius=2*f,fill='white')
        elif name=='volume': line([(14,27),(23,27),(32,19),(32,45),(23,37),(14,37),(14,27)],3); d.arc((27*f,19*f,49*f,45*f),-65,65,fill='white',width=3*f)
        elif name=='shuffle': line([(14,20),(23,20),(41,44),(49,44)],3); line([(44,39),(50,44),(44,49)],3); line([(14,44),(23,44),(41,20),(49,20)],3); line([(44,15),(50,20),(44,25)],3)
        elif name=='repeat': line([(15,27),(15,21),(45,21),(50,26)],3); line([(44,16),(50,21),(44,26)],3); line([(49,37),(49,43),(19,43),(14,38)],3); line([(20,38),(14,43),(20,48)],3)
        elif name=='close': line([(19,19),(45,45)],3); line([(45,19),(19,45)],3)
        return im.resize((64,64),Image.Resampling.LANCZOS)
    names=['home','charts','music','list','settings','search','previous','play','pause','next','volume','shuffle','repeat','close']
    for i,name in enumerate(names): place('icon_'+name, i*74, 1120, icon(name))
    glow = Image.new('RGBA', (128,128), (255,255,255,0))
    alpha = Image.new('L', (128,128))
    alpha.putdata([round(255 * max(0, (math.exp(-((x-63.5)**2+(y-63.5)**2)/(2*(128*.18)**2))-math.exp(-(.5/.18)**2/2))/(1-math.exp(-(.5/.18)**2/2)))) for y in range(128) for x in range(128)])
    glow.putalpha(alpha)
    place('lyric_glow', 1050, 1120, glow)
    atlas.save(target, 'PNG')
    xml=['<Atlas><Texture filename="ui.tex"/><Elements>']
    for name,(x,y,w,h) in regions.items():
        xml.append(f'<Element name="{name}" u1="{x/size:.8f}" u2="{(x+w)/size:.8f}" v1="{1-(y+h)/size:.8f}" v2="{1-y/size:.8f}"/>')
    xml.append('</Elements></Atlas>')
    Path(target).with_suffix('.xml').write_text('\n'.join(xml),encoding='utf-8')


if __name__ == '__main__':
    mode = sys.argv[1]
    if mode == 'encode-ktex':
        with Image.open(sys.argv[2]) as image:
            write_ktex(image, sys.argv[3], mode=sys.argv[4])
    elif mode == 'ui':
        ui(sys.argv[2])
    elif mode in ('cover', 'qr'):
        globals()[mode](sys.argv[2], sys.argv[3])
    elif mode == 'qr-image':
        qr_image(sys.argv[2])
    else:
        raise ValueError('Unknown image mode')


