"""Extract the supplied GIF frame for Workshop preview and KTEX icon."""
from pathlib import Path
import argparse
import hashlib
import json
import sys
from PIL import Image, ImageOps
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'helper'))
from ktex import encode, decode

def square(image, size):
    fitted = ImageOps.contain(image, (size, size), Image.Resampling.LANCZOS)
    canvas = Image.new('RGBA', (size, size), image.getpixel((0, 0))[:3] + (255,))
    canvas.alpha_composite(fitted, ((size-fitted.width)//2, (size-fitted.height)//2))
    return canvas

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--frame', type=int, default=0)
    args = parser.parse_args()
    out = ROOT / 'release/workshop'
    source = out / 'artwork-source.gif'
    with Image.open(source) as gif:
        count = gif.n_frames
        source_size = gif.size
        if not 0 <= args.frame < count:
            raise ValueError('Frame index outside GIF')
        rgba_frames, durations, bounds = [], [], []
        for index in range(count):
            gif.seek(index)
            durations.append(gif.info.get('duration', 30))
            frame = gif.convert('RGBA')
            rgba_frames.append(frame)
            visible = frame.getchannel('A').getbbox()
            if visible:
                bounds.append(visible)
        loop = gif.info.get('loop', 0)
    if not bounds:
        raise ValueError('GIF has no visible content')
    # One union crop for the whole animation: remove transparent-only margins,
    # never a visible edge or a moving part of the character in another frame.
    crop = (min(b[0] for b in bounds), min(b[1] for b in bounds),
            max(b[2] for b in bounds), max(b[3] for b in bounds))
    side = max(crop[2]-crop[0], crop[3]-crop[1])
    opaque_frames = [square(frame.crop(crop), side) for frame in rgba_frames]
    original = opaque_frames[args.frame]
    # Converting a transparent RGBA pixel directly to RGB retains its hidden
    # black colour. Composite first, then quantize the fully opaque RGB frame.
    frames = [frame.convert('RGB').quantize(colors=128, method=Image.Quantize.MEDIANCUT,
              dither=Image.Dither.NONE) for frame in opaque_frames]
    frames[0].save(out/'modpreview.gif', save_all=True, append_images=frames[1:],
                   duration=durations, loop=loop, disposal=2, optimize=True)
    assert (out/'modpreview.gif').stat().st_size < 1_000_000, 'Steam preview GIF must stay below 1 MB'
    with Image.open(out/'modpreview.gif') as check:
        assert check.n_frames == count
        assert sum(check.seek(i) or check.info.get('duration', 0) for i in range(count)) == sum(durations)
    preview = square(original, 512)
    preview.save(out/'preview.png')
    preview.save(out/'modpreview.png')
    icon = square(original, 128)
    icon.save(out/'modicon.png')
    encode(icon, ROOT/'mod/modicon.tex')
    (ROOT/'mod/modicon.xml').write_text('<Atlas><Texture filename="modicon.tex"/><Elements><Element name="modicon.tex" u1="0" u2="1" v1="0" v2="1"/></Elements></Atlas>\n', encoding='utf-8')
    assert decode(ROOT/'mod/modicon.tex').tobytes() == icon.tobytes()
    metadata = {
        'source':'artwork-source.gif', 'sourceSha256':hashlib.sha256(source.read_bytes()).hexdigest(),
        'providedBy':'Zcc', 'originalFileName':'dangomusic.gif', 'sourceSize':list(source_size),
        'frames':count, 'selectedFrame':args.frame, 'previewSize':[512,512], 'modiconSize':[128,128],
        'visibleUnionCrop':list(crop), 'animationSize':[side,side],
        'processing':'Crop only margins transparent in every frame; composite onto opaque source-red square; no visible content removed.',
        'animatedPreview':f'{count} frames and original timings preserved; 128-color quantization to fit below 1 MB.',
        'license':'User-supplied artwork; not automatically covered by the project code license.',
    }
    (out/'ARTWORK.json').write_text(json.dumps(metadata,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')
    print('Original GIF preserved; optimized animated preview:',(out/'modpreview.gif').stat().st_size,'bytes; frame',args.frame,'KTEX round trip passed.')

if __name__=='__main__':
    main()
