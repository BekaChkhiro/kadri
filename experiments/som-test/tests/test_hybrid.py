import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace
import numpy as np
from PIL import Image
import hybrid
from variant_c import request_stage, schema_steps, prompt_steps


class HybridTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root / 'input.png'
        Image.new('RGB', (20, 20)).save(self.source)

    def test_provider_cap_and_no_retry(self):
        path = self.root / 'budget.json'
        gem = hybrid.ProviderBudget(path, 'gemini')
        astra = hybrid.ProviderBudget(path, 'openai')
        gem.change('a', .49)
        with self.assertRaises(RuntimeError): gem.change('b', .02)
        astra.change('a', 1.99)
        with self.assertRaises(RuntimeError): astra.change('b', .02)
        gem.change('a', .01, settle=True)
        with self.assertRaises(RuntimeError): gem.change('a', .01)
        self.assertAlmostEqual(sum(x['usd'] for x in json.loads(path.read_text())['requests'].values()), 2.)

    @patch.dict(os.environ, {'GEMINI_API_KEY': 'fake'})
    def test_count_settle_and_no_retry(self):
        budget = hybrid.ProviderBudget(self.root / 'budget.json', 'gemini')
        raw = {'usageMetadata': {'promptTokenCount': 100, 'candidatesTokenCount': 20,
               'thoughtsTokenCount': 10, 'totalTokenCount': 130},
               'candidates': [{'finishReason': 'STOP', 'content': {'parts': [{'text': json.dumps({
                   'object': 'test', 'parts': [{'label': 'nut', 'box_2d': [0, 0, 500, 500]}]})}]}}]}
        seen = []
        def counter(model, payload, key):
            seen.append(payload)
            return 100
        def transport(model, payload, key):
            self.assertEqual(seen[0], payload)
            return raw
        dest = self.root / 'gemini'
        result, metrics = hybrid.gemini_parts(self.source, [], dest, budget, counter, transport)
        self.assertEqual(result['parts'][0]['box'], [0, 0, 500, 500])
        self.assertAlmostEqual(metrics['usd'], (100*.75+30*3.75)/1e6)
        with self.assertRaises(FileExistsError):
            hybrid.gemini_parts(self.source, [], dest, budget, counter, transport)

    @patch.dict(os.environ, {'GEMINI_API_KEY': 'fake'})
    def test_failure_retains_reservation(self):
        budget = hybrid.ProviderBudget(self.root / 'budget.json', 'gemini')
        def fail(*args): raise RuntimeError('network')
        with self.assertRaises(RuntimeError):
            hybrid.gemini_parts(self.source, [], self.root / 'gemini', budget, lambda *a: 100, fail)
        entries = json.loads(budget.path.read_text())['requests']
        self.assertEqual(next(iter(entries.values()))['state'], 'reserved')

    def test_stream_ids_low_effort_and_complete_first_step(self):
        parts = [{'id': 'p1', 'label': 'nut', 'box': [0, 0, 500, 500]}]
        step = {'title': 'title', 'text': 'text', 'focus': ['p1'], 'avoid': [],
                'markers': [], 'arrows': [], 'tools': [], 'warn': None}
        output = json.dumps({'steps': [step], 'unknown_parts': []})
        class Response:
            status, model, output_text = 'completed', hybrid.ASTRA, output
            def model_dump(self, **kwargs):
                return {'usage': {'input_tokens': 100, 'output_tokens': 100}}
        class Stream:
            def __iter__(self):
                for delta in (output[:12], output[12:]):
                    yield SimpleNamespace(type='response.output_text.delta', delta=delta)
                yield SimpleNamespace(type='response.completed', response=Response())
            def close(self): pass
        def create(**kwargs):
            self.assertTrue(kwargs['stream'])
            self.assertEqual(kwargs['reasoning'], {'effort': 'low'})
            self.assertEqual(kwargs['text']['format']['schema']['properties']['steps']['items']['properties']['focus']['items']['enum'], ['p1'])
            return Stream()
        result, metrics = request_stage(SimpleNamespace(responses=SimpleNamespace(create=create)),
            hybrid.ASTRA, 'steps', prompt_steps('test', parts, []), schema_steps(parts, 1),
            self.source, self.root / 'steps', 'low', hybrid.ProviderBudget(self.root/'budget.json', 'openai'), {}, parts)
        self.assertEqual(result['steps'][0]['focus'], ['p1'])
        self.assertIsNotNone(metrics['time_to_first_step_seconds'])

    def test_pipeline_order_and_same_instructions(self):
        calls = []
        instructions = [{'title': 't', 'text': 'x'}]
        result = {'object': 'obj', 'parts': [{'label': 'nut', 'box': [0, 0, 500, 500]}]}
        step = {'title': 't', 'text': 'x', 'focus': ['p1'], 'avoid': [], 'markers': [],
                'arrows': [], 'tools': [], 'warn': None}
        def gem(source, inst, *args):
            calls.append('gemini'); self.assertEqual(inst, instructions)
            return result, {'count_seconds': .1, 'usd': .001}
        def sam(*args):
            calls.append('sam'); return np.ones((1,20,20), bool), .2
        def steps(*args):
            calls.append('steps')
            self.assertEqual(args[3], prompt_steps('obj', hybrid.assign_ids(result['parts']), instructions))
            self.assertEqual(args[7], 'low')
            return {'steps': [step], 'unknown_parts': []}, {'time_to_first_step_seconds': .3}
        with patch.object(hybrid, 'gemini_parts', gem), patch.object(hybrid, 'segment_boxes', sam), patch.object(hybrid, 'request_stage', steps), patch.object(hybrid, 'render_steps'), patch.object(hybrid, 'render_parts'):
            metrics = hybrid.process(None, self.source, instructions, self.root/'run', self.root/'budget.json')
        self.assertEqual(calls, ['gemini', 'sam', 'steps'])
        self.assertIsNotNone(metrics['time_to_first_outline_seconds'])


if __name__ == '__main__': unittest.main()
