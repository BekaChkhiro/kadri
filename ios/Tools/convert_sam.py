"""Export pinned SAM candidates as FP16 iOS17 ML Programs, with RGB normalization."""
import argparse
from collections import Counter
import json
from pathlib import Path
import numpy as np
import torch
import coremltools as ct
from candidates import CANDIDATES, load
from sam_common import HERE


def convert(name, destination):
    torch.set_num_threads(4)
    encoder, decoder = load(name)
    if name == 'efficientsam':
        # The positional resize depends only on frozen weights and the fixed 64x64 grid.
        # Precompute it with the upstream function; Core ML has no bicubic torch op.
        from efficient_sam.efficient_sam_encoder import get_abs_pos
        image_encoder = encoder.encoder
        with torch.no_grad():
            position = get_abs_pos(image_encoder.pos_embed, True, [64, 64]).reshape(1, 4096, -1)
        del image_encoder.pos_embed
        image_encoder.register_buffer('pos_embed', position)
        image_encoder.pretrain_use_cls_token = False
    destination.mkdir(parents=True, exist_ok=True)
    image = torch.zeros(1, 3, 1024, 1024)
    box = torch.tensor([100., 100., 800., 800.])
    with torch.inference_mode():
        embedding = encoder(image)
    info = {'candidate': name, 'source': CANDIDATES[name], 'models': {}}
    for title, model, examples, names, outputs in [
        ('SAMEncoder', encoder, (image,), ['image'], ['embedding']),
        ('SAMDecoder', decoder, (embedding, box), ['embedding', 'box'], ['mask_logits', 'iou_scores']),
    ]:
        print(f'Converting {name} {title}', flush=True)
        with torch.inference_mode():
            traced = torch.jit.trace(model, examples, check_trace=False)

        converted = ct.convert(
            traced, convert_to='mlprogram', minimum_deployment_target=ct.target.iOS17,
            compute_precision=ct.precision.FLOAT16, skip_model_load=True,
            inputs=[ct.TensorType(name=n, shape=t.shape, dtype=np.float32) for n, t in zip(names, examples)],
            outputs=[ct.TensorType(name=n, dtype=np.float32) for n in outputs],
        )
        converted.short_description = f'Kadri {name} {title}; box-only; RGB 0..255'
        converted.user_defined_metadata['candidate'] = name
        converted.user_defined_metadata['source_commit'] = CANDIDATES[name]['commit']
        converted.user_defined_metadata['weights_sha256'] = CANDIDATES[name]['weights_sha256']
        path = destination / f'{title}.mlpackage'
        converted.save(str(path))
        spec = converted.get_spec()
        ops = Counter()
        for function in spec.mlProgram.functions.values():
            for block in function.block_specializations.values():
                ops.update(op.type for op in block.operations)
        info['models'][title] = {
            'bytes': sum(p.stat().st_size for p in path.rglob('*') if p.is_file()),
            'mil_ops': dict(ops), 'specification_version': spec.specificationVersion,
            'inputs': [str(x) for x in spec.description.input],
            'outputs': [str(x) for x in spec.description.output],
        }
    (destination / 'conversion.json').write_text(json.dumps(info, indent=2))
    return info


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate', choices=CANDIDATES, default='efficientsam')
    parser.add_argument('--output', type=Path, default=HERE.parent / 'Models')
    args = parser.parse_args()
    convert(args.candidate, args.output)
