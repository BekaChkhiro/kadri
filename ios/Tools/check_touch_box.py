"""Offline probe of the two-pass box prompt against the sink SAM2 fixture."""
from pathlib import Path
import time
import coremltools as ct
import numpy as np
from PIL import Image
from sam_common import prepare_image, prompt_box, restore_masks, mask_iou

root = Path(__file__).resolve().parents[1]
image = Image.open(root / 'KadriTests/Fixtures/sink/input.png')
reference = np.asarray(Image.open(root / 'KadriTests/Fixtures/sink/sam2_p5.png')) > 127
encoder = ct.models.MLModel(str(root / 'Models/SAMEncoder.mlpackage'), compute_units=ct.ComputeUnit.CPU_ONLY)
decoder = ct.models.MLModel(str(root / 'Models/SAMDecoder.mlpackage'), compute_units=ct.ComputeUnit.CPU_ONLY)
start = time.perf_counter()
embedding = encoder.predict({'image': prepare_image(image, square=True)})['embedding']
print('embed_ms', (time.perf_counter()-start)*1000, flush=True)
w, h = image.size

def decode(box):
    output = decoder.predict({'embedding': embedding, 'box': prompt_box(box, image.size, square=True)})
    return restore_masks(output['mask_logits'], image.size, square=True)[output['iou_scores'].argmax()]

for fraction in [.18, .22, .25]:
    results = []
    for y in range(200, 380, 30):
        for x in range(160, 340, 30):
            if not reference[y, x]:
                continue
            radius = min(w, h) * fraction / 2
            box = np.array([np.floor(max(0,x-radius)/w*1000), np.floor(max(0,y-radius)/h*1000), np.ceil(min(w,x+radius)/w*1000), np.ceil(min(h,y+radius)/h*1000)])
            first = decode(box)
            yy, xx = np.where(first)
            if len(xx):
                refined = np.array([np.floor(xx.min()/w*1000), np.floor(yy.min()/h*1000), np.ceil((xx.max()+1)/w*1000), np.ceil((yy.max()+1)/h*1000)])
                second = decode(refined)
                results.append((mask_iou(second, reference), x, y, mask_iou(first, reference)))
    print('fraction', fraction, 'tested', len(results), 'best (refined IoU, x, y, initial IoU)', sorted(results, reverse=True)[:5], flush=True)
