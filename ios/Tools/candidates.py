"""Pinned upstream inference implementations; weights stay in the local cache."""
import importlib
import json
import sys
import urllib.request
from pathlib import Path

import torch
from torch import nn
import torch.nn.functional as F
from sam_common import HERE, MEAN, STD, digest

CANDIDATES = {
    'edgesam': {
        'repo': 'chongzhou96/EdgeSAM', 'commit': '03465ff934a01e850639f47e3cd02304d1840f58',
        'package': 'edge_sam', 'license': 'S-Lab-1.0 (non-commercial; ineligible)',
        'weights_url': 'https://huggingface.co/spaces/chongzhou/EdgeSAM/resolve/main/weights/edge_sam_3x.pth',
        'weights_sha256': '5a3e3261da9e2f4c8154410885689ae57d09cbf4cf5d0c848b9d80b6df336ece',
    },
    'mobilesam': {
        'repo': 'ChaoningZhang/MobileSAM', 'commit': 'f706ad9c4eb7f219c00d9050e46328518ffb65d2',
        'package': 'mobile_sam', 'license': 'Apache-2.0',
        'weights_url': 'https://raw.githubusercontent.com/ChaoningZhang/MobileSAM/f706ad9c4eb7f219c00d9050e46328518ffb65d2/weights/mobile_sam.pt',
        'weights_sha256': '6dbb90523a35330fedd7f1d3dfc66f995213d81b29a5ca8108dbcdd4e37d6c2f',
    },
    'efficientsam': {
        'repo': 'yformer/EfficientSAM', 'commit': 'd525f622e6f640acf5a0fc37c7ca1f243da5bde0',
        'package': 'efficient_sam', 'license': 'Apache-2.0',
        'weights_url': 'https://raw.githubusercontent.com/yformer/EfficientSAM/d525f622e6f640acf5a0fc37c7ca1f243da5bde0/weights/efficient_sam_vitt.pt',
        'weights_sha256': 'dff858b19600a46461cbb7de98f796b23a7a888d9f5e34c0b033f7d6eb9e4e6a',
    },
}


def download(url, path, expected=None):
    path = Path(path)
    if path.exists() and (expected is None or digest(path) == expected):
        return path
    path.parent.mkdir(parents=True, exist_ok=True)
    partial = path.with_suffix(path.suffix + '.download')
    with urllib.request.urlopen(url, timeout=120) as src, partial.open('wb') as dst:
        while chunk := src.read(1024 * 1024):
            dst.write(chunk)
    if expected and digest(partial) != expected:
        partial.unlink()
        raise ValueError(f'Checksum mismatch for {url}')
    partial.replace(path)
    return path


def sources(name):
    cfg = CANDIDATES[name]
    dest = HERE / '.cache' / 'sources' / name / cfg['commit']
    marker = dest / 'SOURCE_COMMIT'
    if not marker.exists():
        tree = json.load(urllib.request.urlopen(
            f"https://api.github.com/repos/{cfg['repo']}/git/trees/{cfg['commit']}?recursive=1", timeout=60))
        for item in tree['tree']:
            p = item['path']
            if item['type'] == 'blob' and (p == 'LICENSE' or (p.startswith(cfg['package'] + '/') and p.endswith('.py'))):
                download(f"https://raw.githubusercontent.com/{cfg['repo']}/{cfg['commit']}/{p}", dest / p)
        marker.write_text(cfg['commit'])
    sys.path.insert(0, str(dest))
    return dest


class Encoder(nn.Module):
    def __init__(self, model):
        super().__init__()
        self.encoder = model.image_encoder
        self.register_buffer('mean', torch.tensor(MEAN).reshape(1, 3, 1, 1))
        self.register_buffer('std', torch.tensor(STD).reshape(1, 3, 1, 1))

    def forward(self, image):
        return self.encoder((image - self.mean) / self.std)


class Decoder(nn.Module):
    def __init__(self, model):
        super().__init__()
        self.prompt = model.prompt_encoder
        self.decoder = model.mask_decoder

    def forward(self, embedding, box):
        sparse, dense = self.prompt(points=None, boxes=box.reshape(1, 4), masks=None)
        return self.decoder.predict_masks(embedding, self.prompt.get_dense_pe(), sparse, dense)


class EfficientDecoder(nn.Module):
    def __init__(self, model):
        super().__init__()
        self.prompt = model.prompt_encoder
        self.decoder = model.mask_decoder
        self.register_buffer('labels', torch.tensor([[2, 3, -1, -1, -1, -1]]))

    def forward(self, embedding, box):
        points = F.pad(box.reshape(1, 2, 2), (0, 0, 0, 4), value=-1.0)
        sparse = self.prompt(points, self.labels).unsqueeze(1)
        # Upstream EfficientSAM uses its three multimask tokens for inference.
        return self.decoder(embedding, self.prompt.get_dense_pe(), sparse, multimask_output=True)


def load(name):
    sources(name)
    cfg = CANDIDATES[name]
    weight = download(cfg['weights_url'], HERE / '.cache/weights' / (name + '.pt'), cfg['weights_sha256'])
    if name == 'edgesam':
        module = importlib.import_module('edge_sam')
        model = module.sam_model_registry['edge_sam'](checkpoint=str(weight), upsample_mode='bilinear')
    elif name == 'mobilesam':
        module = importlib.import_module('mobile_sam')
        model = module.sam_model_registry['vit_t'](checkpoint=str(weight))
    else:
        module = importlib.import_module('efficient_sam.efficient_sam')
        model = module.build_efficient_sam(192, 3, checkpoint=str(weight))
    model.eval()
    return Encoder(model).eval(), (EfficientDecoder(model) if name == 'efficientsam' else Decoder(model)).eval()
