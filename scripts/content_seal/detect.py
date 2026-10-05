#!/usr/bin/env python3
"""Local, experimental detection for Meta's open-source VideoSeal v1.0."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import sys

SCOPE = (
    "Checks only the open-source VideoSeal v1.0 watermark. This does not detect all "
    "Meta-generated images and does not verify Meta's proprietary production watermark. "
    "A negative result does not establish authenticity or exclude AI generation. "
    "Blind watermark presence detection is not validated; known-message matching requires the original payload."
)


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def compare_message(bits, expected_bits, threshold=None):
    if threshold is not None and (not math.isfinite(threshold) or not 0 < threshold < 1):
        raise ValueError('Threshold must be strictly between 0 and 1')
    if expected_bits is None:
        if threshold is not None:
            raise ValueError('A threshold requires --expected-message; channel zero is diagnostic only')
        return {'status': 'inconclusive', 'bit_match_fraction': None}
    if len(expected_bits) != 256 or set(expected_bits) - {'0', '1'}:
        raise ValueError('Expected message must contain exactly 256 binary digits')
    if len(bits) != 256 or set(bits) - {'0', '1'}:
        raise ValueError('Decoded message must contain exactly 256 binary digits')
    fraction = sum(a == b for a, b in zip(bits, expected_bits)) / 256
    status = 'inconclusive'
    if threshold is not None:
        status = 'known_message_match' if fraction >= threshold else 'known_message_not_matched'
    return {'status': status, 'bit_match_fraction': fraction}


def summarize(predictions, torch):
    # Upstream versions expose either pooled [B, 1+K] or spatial [B, 1+K, H, W].
    if isinstance(predictions, dict):
        predictions = predictions['preds']
    if predictions.ndim not in (2, 4) or predictions.shape[:2] != (1, 257):
        raise ValueError('Expected one VideoSeal v1.0 prediction with 256 message bits')
    if not torch.isfinite(predictions).all().item():
        raise ValueError('Model returned non-finite predictions')
    pooled = predictions.mean(dim=(-2, -1)) if predictions.ndim == 4 else predictions
    score = pooled[0, 0].sigmoid().item()
    bits = ''.join('1' if value > 0 else '0' for value in pooled[0, 1:].tolist())
    return score, bits


def detect(image_path, checkpoint, threshold=None, expected_message=None):
    import torch
    from PIL import Image, ImageOps
    source_hash = sha256(image_path)
    checkpoint_hash = sha256(checkpoint)
    with Image.open(image_path) as image:
        if getattr(image, 'n_frames', 1) != 1:
            raise ValueError('Only single-frame images are supported')
        if image.mode not in ('RGB', 'L'):
            raise ValueError('Prototype supports opaque RGB/grayscale images; convert other formats explicitly')
        image = ImageOps.exif_transpose(image).convert('RGB')
        width, height = image.size
        # No additional resize or color correction: model owns inference resizing.
        tensor = torch.frombuffer(bytearray(image.tobytes()), dtype=torch.uint8)
        tensor = tensor.reshape(height, width, 3).permute(2, 0, 1).unsqueeze(0).float() / 255
    model = torch.jit.load(str(checkpoint), map_location='cpu').eval()
    with torch.inference_mode():
        score, bits = summarize(model.detect(tensor, is_video=False), torch)
    if sha256(image_path) != source_hash or sha256(checkpoint) != checkpoint_hash:
        raise ValueError('Image or checkpoint changed during detection; rerun')
    return {
        'schema_version': 2,
        'analyzer': 'open-source-videoseal-v1.0',
        'source_sha256': source_hash,
        'checkpoint_sha256': checkpoint_hash,
        'input_representation': 'decoded_original',
        'preprocessing': 'EXIF orientation applied; RGB [0,1]; model-owned resizing; no ICC transform',
        'pixel_dimensions': [width, height],
        **compare_message(bits, expected_message, threshold),
        'diagnostic_channel_zero_score': score,
        'score_method': 'sigmoid of averaged channel-zero logit; not a validated presence score',
        'expected_message_bits': expected_message,
        'threshold': threshold,
        'threshold_validated': False,
        'decoded_message_bits': bits,
        'scope_notice': SCOPE,
        'limitations': [
            'Blind watermark presence detection is not validated; channel zero cannot produce a verdict.',
            'Known-message matching is experimental and requires the original 256-bit payload.',
            'Decoded bits alone do not establish watermark presence or identify the creator.',
            'Cropping, compression and other edits can affect detection.',
        ],
        'runtime': {'torch': torch.__version__, 'device': 'cpu'},
    }


def main():
    parser = argparse.ArgumentParser(description=SCOPE)
    parser.add_argument('image', type=Path)
    parser.add_argument('--checkpoint', required=True, type=Path,
                        help='Local official VideoSeal v1.0 y_256b_img.jit file')
    parser.add_argument('--threshold', type=float,
                        help='Experimental known-message bit-match threshold; requires --expected-message')
    parser.add_argument('--expected-message', help='Known original 256-bit binary payload')
    args = parser.parse_args()
    print(SCOPE, file=sys.stderr)
    try:
        compare_message('0' * 256, args.expected_message, args.threshold)
        result = detect(args.image, args.checkpoint, args.threshold, args.expected_message)
    except Exception as error:
        print(json.dumps({'schema_version': 2, 'status': 'failed',
                          'error': str(error), 'scope_notice': SCOPE}), file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2, allow_nan=False))
    return 0


if __name__ == '__main__':
    sys.exit(main())
