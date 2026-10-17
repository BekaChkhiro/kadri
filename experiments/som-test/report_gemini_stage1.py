"""Offline review sheets and measurements for the paired stage-one experiment."""
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

from prepare_gemini import load
from realism import atomic_json, percentiles
from run_gemini_stage1 import destination, summarize
from segmentation import HERE, font

OUT = HERE / 'out_gemini'
MODELS = ['gemini-3.8-flash', 'gemini-3.5-flash-lite']


def review_sheets(frames):
    folder = OUT / 'review'
    folder.mkdir(exist_ok=True)
    index = []
    for model in MODELS:
        for start in range(0, len(frames), 4):
            selected = frames[start:start+4]
            tiles = []
            for frame in selected:
                path = destination(OUT, 'matrix', model, frame) / 'parts.png'
                if not path.exists():
                    continue
                im = Image.open(path).convert('RGB')
                im.thumbnail((432, 1450))
                tile = Image.new('RGB', (448, im.height+64), '#ffffff')
                tile.paste(im, (8, 56))
                draw = ImageDraw.Draw(tile)
                draw.text((8,4), f'{model}\n{frame["scene"]}/{frame["kind"]}', font=font(18), fill='black')
                tiles.append(tile)
            if not tiles:
                continue
            height = max(t.height for t in tiles)
            sheet = Image.new('RGB', (448*len(tiles), height), '#d1d5db')
            for i, tile in enumerate(tiles):
                sheet.paste(tile, (448*i,0))
            path = folder / f'{model}-{start//4+1:02}.jpg'
            sheet.save(path, quality=90)
            index.append({'path': str(path.relative_to(HERE)), 'frames': [f['key'] for f in selected]})
    atomic_json(folder / 'index.json', index)


def detail_crops(frames):
    for scene, crop in [('gym', (350,270,620,600)), ('chemistry', (400,330,590,470))]:
        frame = next(f for f in frames if f['scene']==scene and f['kind']=='original')
        for model in MODELS:
            path = destination(OUT, 'matrix', model, frame) / 'parts.json'
            if not path.exists():
                continue
            im = Image.open(HERE / frame['input']).convert('RGB')
            draw = ImageDraw.Draw(im)
            for part in load(path)['parts']:
                if scene == 'gym' and not any(t in part['label'] for t in ['ქინძ', 'ღილაკ']):
                    continue
                x0,y0,x1,y1 = part['box']
                draw.rectangle((x0*im.width/1000,y0*im.height/1000,x1*im.width/1000,y1*im.height/1000), outline='red', width=1)
            x0,y0,x1,y1 = crop
            im = im.crop((int(x0*im.width/1000),int(y0*im.height/1000),int(x1*im.width/1000),int(y1*im.height/1000)))
            im.resize((im.width*4, im.height*4)).save(OUT/'review'/f'{scene}-{model}-box-detail.png')


def main():
    frames = load(OUT / 'frames.json')
    results = summarize(OUT, 'matrix', MODELS, frames)
    review_sheets(frames)
    detail_crops(frames)
    compact = {}
    for model, result in results.items():
        scenes = {}
        for scene in sorted({f['scene'] for f in frames}):
            rows = [r for r in result['rows'] if r['frame'].split('/')[1] == scene]
            scenes[scene] = {'frames': len(rows), 'parts': sum(len(r['labels']) for r in rows),
                'first_box': percentiles([r['gemini_latency']['first_box_full_response_seconds'] for r in rows]),
                'proxy': {name: float(np.mean([p['best_iou'] for r in rows for p in r['proxy'] if p['name']==name and p['best_iou'] is not None]))
                          for name in sorted({p['name'] for r in rows for p in r['proxy'] if p['best_iou'] is not None})}}
        compact[model] = {**{k:v for k,v in result.items() if k!='rows'}, 'scenes': scenes,
                          'tokens': {k: sum(r['gemini_latency']['usage'].get(k, 0) for r in result['rows'])
                                     for k in ('promptTokenCount','candidatesTokenCount','thoughtsTokenCount','totalTokenCount')}}
    astra_metrics = [load(HERE/f['baseline']/'parts_request/metrics.json') for f in frames]
    astra_latency = [load(HERE/f['baseline']/'latency.json') for f in frames]
    compact['astra_historical'] = {
        'n': len(frames),
        'model_only_seconds': percentiles([r['first_box_model_only_seconds'] for r in astra_latency]),
        'generation_estimated_usd': sum(r['estimated_usd'] for r in astra_metrics),
        'price_note': 'Historical manually supplied rates; not reverified; excludes separately reserved count preflights',
        'input_tokens': sum(r['usage']['input_tokens'] for r in astra_metrics),
        'output_tokens': sum(r['usage']['output_tokens'] for r in astra_metrics)}
    atomic_json(OUT / 'measurements.json', compact)
    print(json.dumps(compact, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
