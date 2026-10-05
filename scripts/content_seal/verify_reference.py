"""Opt-in real-checkpoint round trip; writes fixtures only to a temporary directory."""
import argparse
from pathlib import Path
import tempfile

from detect import detect, summarize


def main():
    import torch
    from PIL import Image
    parser = argparse.ArgumentParser()
    parser.add_argument('--checkpoint', required=True, type=Path)
    args = parser.parse_args()
    torch.manual_seed(42)
    image = torch.nn.functional.interpolate(
        torch.rand(1, 3, 32, 32), size=(256, 256), mode='bilinear', align_corners=False
    )
    message = torch.randint(0, 2, (1, 256)).float()
    model = torch.jit.load(str(args.checkpoint), map_location='cpu').eval()
    with torch.inference_mode():
        watermarked = model.embed(image, message, is_video=False)
        if isinstance(watermarked, dict):
            watermarked = watermarked['imgs_w']
        _, bits = summarize(model.detect(watermarked, is_video=False), torch)
    expected = ''.join(str(int(value)) for value in message[0].tolist())
    accuracy = sum(a == b for a, b in zip(bits, expected)) / 256
    # Synthetic texture is an API smoke test, not representative robustness data.
    with tempfile.TemporaryDirectory(prefix='content-seal-fixtures-') as directory:
        for name, tensor in [('plain', image), ('watermarked', watermarked)]:
            pixels = tensor[0].clamp(0, 1).mul(255).round().byte().permute(1, 2, 0).contiguous()
            fixture = Image.frombytes('RGB', (256, 256), bytes(pixels.flatten().tolist()))
            for extension, options in [('png', {}), ('jpg', {'quality': 85})]:
                path = Path(directory) / f'{name}.{extension}'
                fixture.save(path, **options)
                result = detect(path, args.checkpoint)
                assert result['status'] == 'inconclusive'
                assert result['threshold_validated'] is False
                assert len(result['decoded_message_bits']) == 256
                print(f'{path.name}: score={result["diagnostic_channel_zero_score"]:.6f}; status={result["status"]}')
    print(f'Float round-trip bit recovery: {accuracy:.1%}; not a detector calibration')


if __name__ == '__main__':
    main()
