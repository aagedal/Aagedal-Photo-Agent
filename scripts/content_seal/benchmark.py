#!/usr/bin/env python3
"""Paired VideoSeal reference experiment; not a population-level calibration."""
import argparse
import csv
import json
import math
from pathlib import Path
import platform

import numpy as np
from PIL import Image, ImageOps
import torch

from detect import SCOPE, sha256, summarize


def to_tensor(image):
    return torch.from_numpy(np.array(image.convert('RGB'), copy=True)).permute(2, 0, 1).unsqueeze(0).float() / 255


def to_image(tensor):
    return Image.fromarray(tensor[0].clamp(0, 1).mul(255).round().byte().permute(1, 2, 0).numpy())


def variants(image):
    yield 'png', image, 'png', {}
    for quality in (95, 85, 60, 30):
        yield f'jpeg_q{quality}', image, 'jpg', {'quality': quality}
    w, h = image.size
    yield 'resize_half', image.resize((w // 2, h // 2), Image.Resampling.LANCZOS), 'png', {}
    yield 'resize_256', image.resize((256, 256), Image.Resampling.LANCZOS), 'png', {}
    for keep in (0.75, 0.5):
        dx, dy = int(w * (1 - keep) / 2), int(h * (1 - keep) / 2)
        yield f'crop_{int(keep*100)}pct_side', image.crop((dx, dy, w-dx, h-dy)), 'png', {}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--image', required=True, type=Path)
    parser.add_argument('--checkpoint', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--messages', type=int, default=3)
    args = parser.parse_args()
    if args.messages < 1:
        parser.error('--messages must be positive')
    args.output.mkdir(parents=True, exist_ok=False)
    torch.set_num_threads(4)
    generator = torch.Generator().manual_seed(42)
    model = torch.jit.load(str(args.checkpoint), map_location='cpu').eval()
    with Image.open(args.image) as source:
        photo = ImageOps.exif_transpose(source).convert('RGB')
    # Distinct content regimes; only one photographic scene, not independent photo samples.
    grid = np.linspace(0, 255, 512, dtype=np.uint8)
    gradient = np.stack(np.meshgrid(grid, grid) + [np.full((512,512),128,dtype=np.uint8)], axis=-1)
    noise = np.random.default_rng(42).integers(0,256,(512,512,3),dtype=np.uint8)
    sources = {'generated_market': photo, 'gradient': Image.fromarray(gradient),
               'noise': Image.fromarray(noise), 'flat': Image.new('RGB',(512,512),(128,128,128))}
    rows = []
    fixture_manifest = []
    for source_name, source in sources.items():
        original = to_tensor(source)
        for message_index in range(args.messages):
            message = torch.randint(0, 2, (1,256), generator=generator).float()
            expected = ''.join(str(int(value)) for value in message[0].tolist())
            with torch.inference_mode():
                watermarked = model.embed(original, message, is_video=False)
                _, float_bits = summarize(model.detect(watermarked, is_video=False), torch)
            float_accuracy = sum(a==b for a,b in zip(float_bits,expected)) / 256
            mse = (original - watermarked).square().mean().item()
            psnr = -10 * math.log10(mse) if mse else None
            fixture_manifest.append({'source':source_name, 'message_index':message_index,
                                     'expected_bits':expected, 'float_bit_accuracy':float_accuracy,
                                     'embedding_psnr_db':psnr})
            for label, base in [('unwatermarked',source), ('watermarked',to_image(watermarked))]:
                for variant, image, extension, options in variants(base):
                    # Controls are saved per message so every bit-match comparison is paired.
                    filename = f'{source_name}-m{message_index}-{label}-{variant}.{extension}'
                    path = args.output / filename
                    image.save(path, **options)
                    with Image.open(path) as reopened:
                        tensor = to_tensor(reopened)
                    with torch.inference_mode():
                        score, bits = summarize(model.detect(tensor, is_video=False), torch)
                    row = {'source':source_name, 'message_index':message_index, 'label':label,
                           'variant':variant, 'score':score,
                           'bit_accuracy':sum(a==b for a,b in zip(bits,expected))/256,
                           'sha256':sha256(path), 'filename':filename}
                    rows.append(row)
            print(f'{source_name} message {message_index}: float bit recovery {float_accuracy:.1%}', flush=True)
    report = {'schema_version':1, 'scope_notice':SCOPE,
              'limitations':['One generated photographic scene plus three procedural controls; not a representative dataset.',
                             'Multiple messages and transforms of the same image are correlated.',
                             'No production Meta-watermark compatibility tested; no validated threshold.'],
              'runtime':{'python':platform.python_version(),'torch':torch.__version__,
                         'pillow':Image.__version__,'numpy':np.__version__,'device':'cpu'},
              'checkpoint_sha256':sha256(args.checkpoint), 'source_sha256':sha256(args.image),
              'seed':42, 'fixtures':fixture_manifest, 'results':rows}
    (args.output/'results.json').write_text(json.dumps(report,indent=2,allow_nan=False)+'\n')
    with (args.output/'results.csv').open('w',newline='') as file:
        writer=csv.DictWriter(file,fieldnames=list(rows[0]),lineterminator="\n")
        writer.writeheader(); writer.writerows(rows)
    for source in sources:
        for variant in ('png','jpeg_q85','jpeg_q30','resize_half','crop_50pct_side'):
            subset=[r for r in rows if r['source']==source and r['variant']==variant]
            for label in ('unwatermarked','watermarked'):
                group=[r for r in subset if r['label']==label]
                print(f'{source:18} {variant:17} {label:13} score={sum(r["score"] for r in group)/len(group):.4f} bit_accuracy={sum(r["bit_accuracy"] for r in group)/len(group):.1%}')


if __name__ == '__main__':
    main()
