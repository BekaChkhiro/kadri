"""Run one fresh pilot, then remaining historical frames without repeating pilot."""
import argparse
import json
from pathlib import Path
from dotenv import load_dotenv
from openai import OpenAI
from segmentation import HERE
from prepare_gemini import load, prepare, sha
from hybrid import process, run_destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['prepare', 'pilot', 'matrix'])
    parser.add_argument('--run', action='store_true')
    args = parser.parse_args()
    out = HERE / 'out_hybrid'
    if args.mode == 'prepare':
        print(f'Prepared {len(prepare(out))} verified historical frames')
        return
    if not args.run:
        parser.error('--run required for paid requests')
    load_dotenv(HERE / '.env')
    client = OpenAI(max_retries=0, timeout=55)
    frames = load(out / 'frames.json')
    if args.mode == 'pilot':
        frames = [f for f in frames if f['scene'] == 'sink' and f['kind'] == 'original']
    for frame in frames:
        dest = run_destination(out, frame)
        if (dest / 'latency.json').exists():
            continue
        source = HERE / frame['input']
        assert sha(source.read_bytes()) == frame['sha256']
        truth = load((HERE / frame['baseline']).parent / 'truth.json')
        instructions = [{'title': s['title'], 'text': s['text']} for s in truth['steps']]
        metrics = process(client, source, instructions, dest, out / 'budget.json')
        print(json.dumps({'frame': frame['key'], **metrics}), flush=True)


if __name__ == '__main__':
    main()
