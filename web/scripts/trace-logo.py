"""Trace the supplied transparent NETA logo to clean SVG paths.

Reads the copied source; only writes web/public/brand/neta-logo-light.svg.
Requires Pillow and numpy. The original iOS files are never changed.
"""
from pathlib import Path
from collections import defaultdict
import numpy as np
from PIL import Image

root = Path(__file__).resolve().parents[1]
pixels = np.asarray(Image.open(root / 'public/brand/neta-logo-original.png').convert('RGBA'))


def simplify(points, tolerance=1.1):
    if len(points) < 3:
        return points
    start, end = np.array(points[0]), np.array(points[-1])
    delta = end - start
    middle = np.array(points[1:-1]) - start
    norm = np.linalg.norm(delta)
    distances = np.abs(delta[0] * middle[:, 1] - delta[1] * middle[:, 0]) / norm if norm else np.linalg.norm(middle, axis=1)
    index = int(np.argmax(distances)) + 1
    if distances[index - 1] <= tolerance:
        return [points[0], points[-1]]
    return simplify(points[:index + 1], tolerance)[:-1] + simplify(points[index:], tolerance)


def paths(mask):
    padded = np.pad(mask, 1)
    adjacent = [padded[:-2, 1:-1], padded[1:-1, 2:], padded[2:, 1:-1], padded[1:-1, :-2]]
    edges = defaultdict(list)
    for side, neighbor in enumerate(adjacent):
        ys, xs = np.nonzero(mask & ~neighbor)
        for x, y in zip(xs.tolist(), ys.tolist()):
            corners = [(x, y), (x + 1, y), (x + 1, y + 1), (x, y + 1)]
            edges[corners[side]].append(corners[(side + 1) % 4])
    result = []
    while edges:
        start = next(iter(edges))
        point = start
        loop = [point]
        while True:
            following = edges[point].pop()
            if not edges[point]:
                del edges[point]
            loop.append(following)
            point = following
            if point == start:
                break
        area = abs(sum(a[0] * b[1] - b[0] * a[1] for a, b in zip(loop, loop[1:]))) / 2
        if area < 40:
            continue
        # Split the closed polygon so Douglas–Peucker retains its full outline.
        split = len(loop) // 2
        points = simplify(loop[:split + 1])[:-1] + simplify(loop[split:])
        result.append('M' + ' L'.join(f'{x} {y}' for x, y in points[:-1]) + ' Z')
    return ' '.join(result)

solid = pixels[:, :, 3] >= 160
blue = solid & (pixels[:, :, 2] > 120)
letters = solid & ~blue
rgb = np.median(pixels[blue][:, :3], axis=0).astype(int)
blue_color = '#' + ''.join(f'{value:02x}' for value in rgb)
svg = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1636 407" fill-rule="evenodd">
  <path fill="{blue_color}" d="{paths(blue)}"/>
  <path fill="#f8fafc" d="{paths(letters)}"/>
</svg>
'''
(root / 'public/brand/neta-logo-light.svg').write_text(svg)
print('Traced original silhouettes; blue:', blue_color)
