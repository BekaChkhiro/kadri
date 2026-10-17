import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from PIL import Image
from jsonschema import ValidationError
from gemini_stage1 import (box_xyxy, parse_parts, prompt, request_parts, model_config,
                           usage_cost, MODELS)
from realism import Budget


class GeminiStage1Tests(unittest.TestCase):
    def test_asymmetric_box_axes(self):
        self.assertEqual(box_xyxy([100, 230, 800, 990]), [230, 100, 990, 800])

    def test_invalid_boxes_are_not_clamped_or_reordered(self):
        for b in (None, [], [0, 1, 2], [0, 0, 0, 2], [4, 0, 2, 5],
                  [-1, 0, 4, 5], [0, 0, 1001, 3], [0, 0, float('nan'), 3],
                  [0, 0, float('inf'), 3], [False, 0, 4, 5], [0, '2', 4, 5]):
            with self.subTest(box=b), self.assertRaises(ValueError):
                box_xyxy(b)

    def test_parse_contract_and_empty_scene(self):
        text = json.dumps({'object': 'ნიჟარა', 'parts': [{'label': 'ქანჩი', 'box_2d': [100, 230, 800, 990]}]})
        self.assertEqual(parse_parts(text), {'object': 'ნიჟარა', 'parts': [{'label': 'ქანჩი', 'box': [230, 100, 990, 800]}]})
        self.assertEqual(parse_parts('{"object":"none","parts":[]}')['parts'], [])

    def test_empty_invalid_truncated_and_extra_fields_fail(self):
        for text in ('', ' ', None, 'null', '[]', '{}', '{"parts":', '```json\n{}\n```',
                     '{"object":"x","parts":[{"label":" ","box_2d":[0,0,1,1]}]}',
                     '{"object":"x","parts":[],"steps":[]}'):
            with self.subTest(text=text), self.assertRaises((ValueError, ValidationError)):
                parse_parts(text)

    def test_semantics_and_price_gate(self):
        self.assertIn('box_2d=[ymin,xmin,ymax,xmax]', prompt([]))
        self.assertNotIn('box=[x0', prompt([]))
        with self.assertRaises(ValueError):
            model_config('unpriced')

    def test_cost_includes_thinking(self):
        usage = {'promptTokenCount': 1000, 'candidatesTokenCount': 100, 'thoughtsTokenCount': 200, 'totalTokenCount': 1300}
        self.assertAlmostEqual(usage_cost(usage, MODELS['gemini-3.8-flash']), .001875)
        with self.assertRaises(ValueError):
            usage_cost({}, MODELS['gemini-3.8-flash'])

    def test_request_settlement_and_no_retry(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, {'GEMINI_API_KEY': 'fake-test-key'}):
            root = Path(tmp)
            source = root / 'image.png'
            Image.new('RGB', (32, 32)).save(source)
            budget = Budget(root / 'budget.json', 5)
            calls = []
            def transport(model, payload, key):
                calls.append(payload)
                return {'candidates': [{'finishReason': 'STOP', 'content': {'parts': [{'text': '{"object":"none","parts":[]}'}]}}],
                        'usageMetadata': {'promptTokenCount': 20, 'candidatesTokenCount': 10, 'totalTokenCount': 30}}
            result, metrics = request_parts('gemini-3.8-flash', source, [], root / 'run', budget, transport)
            self.assertEqual(result['parts'], [])
            self.assertIsNone(metrics['first_box_full_response_seconds'])
            self.assertEqual(calls[0]['generationConfig']['thinkingConfig'], {'thinkingLevel': 'low'})
            self.assertNotIn('fake-test-key', (root / 'run/request.json').read_text())
            self.assertEqual(next(iter(json.loads((root / 'budget.json').read_text())['requests'].values()))['state'], 'settled')
            with self.assertRaises(RuntimeError):
                request_parts('gemini-3.8-flash', source, [], root / 'run', budget, transport)
            self.assertEqual(len(calls), 1)

    def test_failure_retains_reservation_and_redacts_error(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, {'GEMINI_API_KEY': 'fake-test-key'}):
            root = Path(tmp)
            source = root / 'image.png'
            Image.new('RGB', (32, 32)).save(source)
            def fail(*args):
                raise RuntimeError('fake-test-key secret request echo')
            with self.assertRaises(RuntimeError):
                request_parts('gemini-3.8-flash', source, [], root / 'run', Budget(root / 'budget.json', 5), fail)
            self.assertNotIn('fake-test-key', (root / 'run/error.json').read_text())
            row = next(iter(json.loads((root / 'budget.json').read_text())['requests'].values()))
            self.assertEqual(row['state'], 'reserved')
            self.assertGreater(row['usd'], .7)
