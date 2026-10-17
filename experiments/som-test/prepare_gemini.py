"""Reconstruct exact historical thumbnails offline; never modify the baseline."""
import base64
import hashlib
import io
import json
from pathlib import Path

from PIL import Image, ImageOps
from evaluation import truth_masks
from realism import atomic_json, degrade, payload_sha256
from segmentation import HERE, ROOT, SCENES


def load(path):
    return json.loads(Path(path).read_text())


def sha(data):
    return hashlib.sha256(data).hexdigest()


def prepare(out=HERE / 'out_gemini'):
    rows = []
    for campaign in ('c_astra_tracking', 'c_astra_stress'):
        for plan in sorted((HERE / 'out_realism' / campaign).glob('*/*/*/run_1/plan.json')):
            run = plan.parent
            if not (run / 'latency.json').exists():
                continue
            scene = run.relative_to(HERE / 'out_realism' / campaign).parts[0]
            meta = load(run.parent / 'transform.json')
            source = ROOT / 'Camera/assets' / SCENES[scene][0]
            truth = load(HERE / 'out' / scene / 'ground_truth.json')
            assert sha(source.read_bytes()) == meta['source_sha256'], f'{scene}: source changed'
            assert sha(json.dumps(truth, sort_keys=True).encode()) == meta['truth_sha256'], f'{scene}: truth changed'
            image = ImageOps.exif_transpose(Image.open(source)).convert('RGB')
            changed, _, _, generated = degrade(image, truth_masks(truth, image.size), meta['kind'], meta['seed'])
            assert all(generated[k] == meta[k] for k in generated), f'{run}: transform changed'
            full = io.BytesIO()
            changed.save(full, format='PNG')
            assert sha(full.getvalue()) == load(run / 'adapter_config.json')['input_hash'], f'{run}: prepared image hash mismatch'
            changed.thumbnail((768, 768), Image.Resampling.LANCZOS)
            buf = io.BytesIO()
            changed.save(buf, format='PNG')
            data = buf.getvalue()
            req = load(run / 'parts_request/request.json')
            signature = {'model': req['model'], 'input': [{'role': 'user', 'content': [
                {'type': 'input_text', 'text': req['prompt']},
                {'type': 'input_image', 'image_url': 'data:image/png;base64,' + base64.b64encode(data).decode(), 'detail': 'high'}]}],
                'text': {'format': {'type': 'json_schema', 'name': 'variant_c_parts', 'strict': True, 'schema': req['schema']}},
                'reasoning': {'effort': req['reasoning_effort']}, 'truncation': 'disabled'}
            assert payload_sha256(signature) == load(run / 'parts_request/request_hash.json')['request_hash'], f'{run}: historical request hash mismatch'
            if (run / 'input.png').exists():
                assert data == (run / 'input.png').read_bytes()
            key = f'{campaign}/{scene}/{meta["kind"]}'
            dest = out / 'inputs' / key / 'input.png'
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(data)
            rows.append({'key': key, 'scene': scene, 'kind': meta['kind'],
                         'baseline': str(run.relative_to(HERE)), 'input': str(dest.relative_to(HERE)),
                         'sha256': sha(data), 'historical_request_hash_verified': True,
                         'existing_thumbnail_verified': (run / 'input.png').exists()})
    if len(rows) != 22:
        raise ValueError(f'Expected 22 completed baseline frames, got {len(rows)}')
    atomic_json(out / 'frames.json', rows)
    return rows


if __name__ == '__main__':
    print(f'Verified {len(prepare())} historical thumbnails; no API calls')
