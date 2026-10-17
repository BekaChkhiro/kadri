"""Export the pinned EfficientSAM-Ti point decoder, retaining the box decoder."""
import json
from collections import Counter
import numpy as np
import torch
import torch.nn.functional as F
import coremltools as ct
from candidates import load, CANDIDATES
from sam_common import HERE


class PointDecoder(torch.nn.Module):
    def __init__(self, box_decoder):
        super().__init__()
        self.prompt = box_decoder.prompt
        self.decoder = box_decoder.decoder

    def forward(self, embedding, points, labels):
        # Upstream uses six prompt slots; expose two and pad the remaining four.
        points = F.pad(points, (0, 0, 0, 4), value=-1.0)
        labels = F.pad(labels, (0, 4), value=-1.0)
        sparse = self.prompt(points, labels).unsqueeze(1)
        return self.decoder(embedding, self.prompt.get_dense_pe(), sparse, multimask_output=True)


def convert():
    torch.set_num_threads(4)
    _, decoder = load('efficientsam')
    model = PointDecoder(decoder).eval()
    examples = (torch.zeros(1, 256, 64, 64), torch.tensor([[[512., 512.], [-1., -1.]]]), torch.tensor([[1., -1.]]))
    with torch.inference_mode():
        traced = torch.jit.trace(model, examples, check_trace=False)
    converted = ct.convert(
        traced, convert_to='mlprogram', minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT16, skip_model_load=True,
        inputs=[ct.TensorType(name=n, shape=t.shape, dtype=np.float32)
                for n, t in zip(['embedding', 'points', 'labels'], examples)],
        outputs=[ct.TensorType(name=n, dtype=np.float32) for n in ['mask_logits', 'iou_scores']],
    )
    converted.short_description = 'Kadri EfficientSAM-Ti point decoder; 1024-square coordinates; labels 1 foreground, -1 padding'
    cfg = CANDIDATES['efficientsam']
    converted.user_defined_metadata.update({'candidate': 'efficientsam', 'source_commit': cfg['commit'], 'weights_sha256': cfg['weights_sha256']})
    destination = HERE.parent / 'Models'
    path = destination / 'SAMDecoderPoint.mlpackage'
    converted.save(str(path))
    spec = converted.get_spec()
    ops = Counter()
    for function in spec.mlProgram.functions.values():
        for block in function.block_specializations.values():
            ops.update(op.type for op in block.operations)
    metadata = destination / 'conversion.json'
    info = json.loads(metadata.read_text())
    info['models']['SAMDecoderPoint'] = {
        'bytes': sum(p.stat().st_size for p in path.rglob('*') if p.is_file()),
        'mil_ops': dict(ops), 'specification_version': spec.specificationVersion,
        'inputs': [str(x) for x in spec.description.input],
        'outputs': [str(x) for x in spec.description.output],
    }
    metadata.write_text(json.dumps(info, indent=2) + '\n')


if __name__ == '__main__':
    convert()
