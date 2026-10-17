import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

import numpy as np
from PIL import Image

from realism import (Budget, KINDS, atomic_json, degrade, mask_truth, match_frames,
                     percentiles, run_b_adapter, run_c_adapter)
from evaluation import truth_masks


class RealismTests(unittest.TestCase):
    def setUp(self):
        self.image = Image.fromarray(np.full((80, 100, 3), 180, np.uint8))
        self.masks = np.zeros((1, 80, 100), bool)
        self.masks[0, 20:60, 30:70] = True

    def test_deterministic_and_visibility(self):
        for kind in KINDS:
            a = degrade(self.image, self.masks, kind, 42)
            b = degrade(self.image, self.masks, kind, 42)
            np.testing.assert_array_equal(a[0], b[0])
            np.testing.assert_array_equal(a[1], b[1])
            self.assertEqual(a[3], b[3])
            self.assertTrue(np.all(a[2] <= a[1]))
        _, full, visible, _ = degrade(self.image, self.masks, 'occlusion', 42)
        self.assertLess(visible.sum(), full.sum())

    def test_shift_mask_and_roundtrip_truth(self):
        _, full, _, meta = degrade(self.image, self.masks, 'shift_right')
        self.assertEqual(meta['source_to_frame'][0][2], 4)
        self.assertTrue(full[0, 21, 34])
        truth = {'parts': [{'name': 'part', 'path': ''}], 'steps': []}
        converted = mask_truth(truth, full, self.image.size)
        np.testing.assert_array_equal(truth_masks(converted, self.image.size), full)
        blank = mask_truth(truth, np.zeros_like(full), self.image.size)
        self.assertEqual(truth_masks(blank, self.image.size).sum(), 0)

    def test_geometry_ignores_raw_labels_and_ids(self):
        a = [{'id': 'a', 'label': 'old', 'box': [300, 250, 700, 750]}]
        b = [{'id': 'b', 'label': 'new', 'box': [340, 262.5, 740, 762.5]},
             {'id': 'c', 'label': 'other', 'box': [0, 0, 50, 50]}]
        original = degrade(self.image, self.masks, 'original')[3]
        shifted = degrade(self.image, self.masks, 'shift_right')[3]
        result = match_frames(a, b, original, shifted, .9)
        self.assertEqual(len(result['matches']), 1)
        self.assertAlmostEqual(result['matches'][0]['iou'], 1)
        self.assertEqual(result['phone_ids'], ['phone_1', 'phone_2'])
        self.assertEqual(result['raw_id_stability'], 0)
        self.assertEqual(result['unmatched'], [1])
        duplicate = match_frames(a, b[:1] * 2, original, shifted, .9)
        self.assertEqual(len(duplicate['matches']), 1)
        self.assertEqual(match_frames(a, [], original, original)['dropout'], [0])

    def test_budget_persists_failures_and_caps(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'ledger.json'
            Budget(path).change('first', 10)
            with self.assertRaises(RuntimeError):
                Budget(path).change('first', 10)
            with self.assertRaises(RuntimeError):
                Budget(path).change('second', 6)
            Budget(path).change('first', 2, settle=True)
            Budget(path).change('second', 11)
            with self.assertRaises(ValueError):
                Budget(path).change('second', 12, settle=True)
            self.assertEqual(json.loads(path.read_text())['requests']['second']['usd'], 11)
            with self.assertRaises(ValueError):
                Budget(path, 14)

    def test_adapter_failed_api_not_retried_and_cached_plan_resume(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            client = SimpleNamespace(
                responses=SimpleNamespace(
                    create=Mock(side_effect=TimeoutError),
                    input_tokens=SimpleNamespace(count=Mock(return_value=SimpleNamespace(input_tokens=100)))
                )
            )
            def process(client, model, source, truth, dest, device):
                return client.responses.create(max_output_tokens=12000, model=model, input=[{"role": "user", "content": "hi"}])
            for exception in (TimeoutError, RuntimeError):
                with self.assertRaises(exception):
                    run_b_adapter(client, 'model', root / 'img', {}, root / 'run', 'cpu', Budget(root / 'ledger'), (10, 50), process)
            self.assertEqual(client.responses.create.call_count, 1)
            result = run_b_adapter(client, 'model', root / 'img', {}, root / 'run', 'cpu', Budget(root / 'ledger'), (10, 50),
                                   lambda *args: {'parts': []})
            self.assertEqual(result, {'parts': []})
            self.assertEqual(client.responses.create.call_count, 1)

    def test_adapter_settles_and_unknown_price_blocks(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            response = SimpleNamespace(model_dump=lambda **kw: {'usage': {'input_tokens': 100, 'output_tokens': 20}})
            client = SimpleNamespace(
                responses=SimpleNamespace(
                    create=Mock(return_value=response),
                    input_tokens=SimpleNamespace(count=Mock(return_value=SimpleNamespace(input_tokens=100)))
                )
            )
            def process(c, m, s, t, d, device):
                c.responses.create(max_output_tokens=12000, model=m, input=[{"role": "user", "content": "hi"}])
                atomic_json(d / 'metrics.json', {'seconds': 2})
                atomic_json(d / 'segmentation.json', {'seconds': 3})
                return {}
            with self.assertRaises(ValueError):
                run_b_adapter(client, 'unknown', root / 'img', {}, root / 'run', 'cpu', Budget(root / 'ledger'), None, process)
            self.assertEqual(client.responses.create.call_count, 0)
            run_b_adapter(client, 'model', root / 'img', {}, root / 'run', 'cpu', Budget(root / 'ledger'), (10, 50), process)
            reqs = json.loads((root / 'ledger').read_text())['requests']
            dest_key = hashlib.sha256(str((root / 'run').resolve()).encode()).hexdigest()
            self.assertEqual(reqs[f"{dest_key}:count"]['state'], 'settled')
            self.assertAlmostEqual(reqs[f"{dest_key}:count"]['usd'], 0.001)
            self.assertEqual(reqs[f"{dest_key}:gen"]['state'], 'settled')
            self.assertAlmostEqual(reqs[f"{dest_key}:gen"]['usd'], 0.002)
            latency = json.loads((root / 'run/latency.json').read_text())
            self.assertEqual(latency['first_box_full_response_seconds'], 2)
            self.assertIn('preflight_seconds', latency)
            self.assertIn('real_wall_time_to_first_box_seconds', latency)

    def test_mock_count_same_payload(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            mock_count = Mock(return_value=SimpleNamespace(input_tokens=123))
            mock_create = Mock(return_value=SimpleNamespace(model_dump=lambda **kw: {'usage': {'input_tokens': 123, 'output_tokens': 10}}))
            client = SimpleNamespace(responses=SimpleNamespace(create=mock_create, input_tokens=SimpleNamespace(count=mock_count)))
            inp = [{'role': 'user', 'content': [{'type': 'input_text', 'text': 'test'}]}]
            txt = {'format': {'type': 'json_schema', 'name': 'test', 'strict': True, 'schema': {}}}
            rsn = {'effort': 'low'}
            def process(c, m, s, t, d, device):
                c.responses.create(model='gpt-6-astra', input=inp, text=txt, reasoning=rsn, max_output_tokens=1000)
                return {'parts': []}
            run_b_adapter(client, 'gpt-6-astra', root / 'img', {}, root / 'run', 'cpu', Budget(root / 'ledger'), (10, 50), process)
            mock_count.assert_called_once_with(
                model='gpt-6-astra',
                input=inp,
                text=txt,
                reasoning=rsn,
                truncation='disabled'
            )
            pref = json.loads((root / 'run/preflight.json').read_text())
            self.assertEqual(pref['input_tokens'], 123)
            self.assertIn('hash', pref)
            self.assertIn('latency_seconds', pref)

    def test_failclosed_count_failure_and_ceiling(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            client_unsupported = SimpleNamespace(responses=SimpleNamespace(create=Mock()))
            with self.assertRaises(NotImplementedError):
                run_b_adapter(client_unsupported, 'model', root / 'img', {}, root / 'run_unsupported', 'cpu', Budget(root / 'ledger'), (10, 50),
                              lambda c, *args: c.responses.create())

            client_err = SimpleNamespace(
                responses=SimpleNamespace(
                    create=Mock(),
                    input_tokens=SimpleNamespace(count=Mock(side_effect=ConnectionError('count error')))
                )
            )
            with self.assertRaises(ConnectionError):
                run_b_adapter(client_err, 'model', root / 'img', {}, root / 'run_err', 'cpu', Budget(root / 'ledger'), (10, 50),
                              lambda c, *args: c.responses.create(model='m', input=[]))
            self.assertEqual(client_err.responses.create.call_count, 0)
            reqs = json.loads((root / 'ledger').read_text())['requests']
            err_key = f"{hashlib.sha256(str((root / 'run_err').resolve()).encode()).hexdigest()}:count"
            self.assertEqual(reqs[err_key]['state'], 'reserved')

            client_ceil = SimpleNamespace(
                responses=SimpleNamespace(
                    create=Mock(),
                    input_tokens=SimpleNamespace(count=Mock(return_value=SimpleNamespace(input_tokens=100001)))
                )
            )
            with self.assertRaises(ValueError):
                run_b_adapter(client_ceil, 'model', root / 'img', {}, root / 'run_ceil', 'cpu', Budget(root / 'ledger'), (10, 50),
                              lambda c, *args: c.responses.create(model='m', input=[]))
            self.assertEqual(client_ceil.responses.create.call_count, 0)
            reqs = json.loads((root / 'ledger').read_text())['requests']
            ceil_key = f"{hashlib.sha256(str((root / 'run_ceil').resolve()).encode()).hexdigest()}:count"
            self.assertEqual(reqs[ceil_key]['state'], 'reserved')

    def test_resize_proxy_matches_evaluation(self):
        from run_realism import proxy_evaluation
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            frame = root / 'frame'
            frame.mkdir(parents=True)
            full_ref = np.zeros((2, 100, 100), bool)
            full_ref[0, 10:50, 10:50] = True
            full_ref[1, 50:90, 50:90] = True
            vis_ref = full_ref.copy()
            vis_ref[0, 10:20, 10:50] = False
            np.savez_compressed(frame / 'truth_masks.npz', full=full_ref, visible=vis_ref)
            dest = frame / 'run_1'
            dest.mkdir(parents=True)
            pred_masks = np.zeros((2, 60, 60), bool)
            pred_masks[0, 6:30, 6:30] = True
            pred_masks[1, 30:54, 30:54] = True
            np.savez_compressed(dest / 'masks.npz', masks=pred_masks, ids=np.array(['p1', 'p2']))
            plan = {
                'parts': [{'id': 'p1', 'label': 'a', 'box': [100, 100, 500, 500]},
                          {'id': 'p2', 'label': 'b', 'box': [500, 500, 900, 900]}],
                'steps': [{'focus': ['p1'], 'avoid': ['p2']}]
            }
            truth = {'parts': [{'name': 'a'}, {'name': 'b'}], 'steps': [{'focus': [0], 'avoid': [1]}]}
            proxy_evaluation(dest, plan, truth)
            self.assertTrue((dest / 'proxy.json').exists())
            proxy = json.loads((dest / 'proxy.json').read_text())
            step_eval = proxy['steps'][0]
            self.assertAlmostEqual(step_eval['focus_full_iou'], 1.0)
            self.assertAlmostEqual(step_eval['focus_visible_iou'], .75)
            self.assertAlmostEqual(step_eval['avoid_full_iou'], 1.0)
            self.assertAlmostEqual(step_eval['avoid_visible_iou'], 1.0)

    def test_cli_dry_run_and_changed_seed_rejected(self):
        import run_realism
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'Camera/assets').mkdir(parents=True)
            self.image.save(root / 'Camera/assets/test.png')
            truth = {'design_size': [100, 80], 'parts': [{'name': 'part', 'path': 'M30 20 L69 20 L69 59 L30 59 Z'}],
                     'steps': [{'title': 'test', 'text': 'test', 'focus': [0], 'avoid': []}]}
            atomic_json(root / 'out/test/ground_truth.json', truth)
            args = ['--dry-run', '--scenes', 'test', '--kinds', 'original', 'shift_right', '--out', str(root / 'results')]
            with patch.object(run_realism, 'HERE', root), patch.object(run_realism, 'ROOT', root), \
                 patch.object(run_realism, 'SCENES', {'test': ('test.png', 'unused')}), \
                 patch.object(run_realism, 'run_b_adapter', side_effect=AssertionError('API forbidden')):
                self.assertEqual(run_realism.main(args), 0)
                self.assertEqual(run_realism.main(args + ['--resume']), 0)
                self.assertEqual(run_realism.main(args + ['--seed', '99']), 1)
            meta = json.loads((root / 'results/test/test/shift_right/transform.json').read_text())
            self.assertEqual(meta['source_to_frame'][0][2], 4)

            # Test variant c dry run
            args_c = ['--dry-run', '--variant', 'c', '--effort', 'minimal', '--max-side', '512',
                      '--scenes', 'test', '--kinds', 'original', '--out', str(root / 'results_c')]
            with patch.object(run_realism, 'HERE', root), patch.object(run_realism, 'ROOT', root), \
                 patch.object(run_realism, 'SCENES', {'test': ('test.png', 'unused')}), \
                 patch.object(run_realism, 'run_c_adapter', side_effect=AssertionError('API forbidden')):
                self.assertEqual(run_realism.main(args_c), 0)

    def test_real_b_adapter_mock_sam_and_cached_resume(self):
        from test_variant_b import plan, truth, client_for, sam_for_boxes
        from run_realism import prepare, proxy_evaluation
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / 'source.jpg'
            Image.new('RGB', (100, 100), 'gray').save(source)
            frame = root / 'original'
            prepare(source, truth(), frame, 'original', 7)
            adapted_truth = json.loads((frame / 'truth.json').read_text())
            client = client_for(plan())
            client.responses.input_tokens = SimpleNamespace(count=Mock(return_value=SimpleNamespace(input_tokens=100)))
            budget = Budget(root / 'ledger')
            with patch('variant_b.make_sam', return_value=sam_for_boxes):
                result = run_b_adapter(client, 'gpt-6-astra', frame / 'image.png', adapted_truth, frame / 'run_1', 'cpu', budget, (10, 50))
                proxy_evaluation(frame / 'run_1', result, truth())
                run_b_adapter(client, 'gpt-6-astra', frame / 'image.png', adapted_truth, frame / 'run_1', 'cpu', budget, (10, 50))
            self.assertEqual(client.responses.create.call_count, 1)
            self.assertTrue((frame / 'run_1/proxy.json').exists())
            self.assertTrue((frame / 'run_1/parts.png').exists())
            prepare(source, truth(), root / 'real', 'original', 7, real=True)
            with np.load(root / 'real/truth_masks.npz') as masks:
                self.assertEqual(masks['full'].sum(), 0)

    def c_fixture(self, root, failure=None):
        from test_variant_b import plan, truth, sam_for_boxes
        from test_variant_c import response, stream_for, steps
        source = root / 'source.png'
        Image.new('RGB', (100, 100), 'white').save(source)
        parts = {'object': 'fixture', 'parts': [{k: v for k, v in p.items() if k != 'id'} for p in plan()['parts']]}
        def create(**kwargs):
            if kwargs.get('stream'):
                if failure == 'disconnect':
                    stream = Mock()
                    stream.__iter__ = Mock(return_value=iter([]))
                    return stream
                return stream_for(steps(), status='incomplete' if failure == 'incomplete' else 'completed')
            return response(parts)
        client = SimpleNamespace(responses=SimpleNamespace(create=Mock(side_effect=create),
            input_tokens=SimpleNamespace(count=Mock(return_value=SimpleNamespace(input_tokens=1000)))))
        args = (client, 'gpt-6-astra', source, truth(), root / 'run', 'cpu', Budget(root / 'ledger'), (10, 50))
        return client, args, sam_for_boxes

    def test_actual_c_counts_both_stages_settles_once_and_complete_resume(self):
        from realism import payload_sha256
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            client, args, sam = self.c_fixture(root)
            run_c_adapter(*args, sam=sam)
            self.assertEqual(client.responses.create.call_count, 2)
            self.assertEqual(client.responses.input_tokens.count.call_count, 2)
            for stage, count_call, create_call in zip(('parts', 'steps'), client.responses.input_tokens.count.call_args_list,
                                                     client.responses.create.call_args_list):
                counted, created = count_call.kwargs, create_call.kwargs
                self.assertEqual(counted, {k: created[k] for k in counted})
                self.assertEqual(created['truncation'], 'disabled')
                pref = json.loads((root / f'run/{stage}_request/preflight.json').read_text())
                self.assertEqual(pref['hash'], payload_sha256(counted))
            rows = json.loads((root / 'ledger').read_text())['requests']
            self.assertEqual(len(rows), 4)
            self.assertTrue(all(r['state'] == 'settled' for r in rows.values()))
            self.assertAlmostEqual(sum(r['usd'] for r in rows.values()), .05)
            atomic_json(root / 'run/complete.json', {'complete': True})
            metrics = (root / 'run/metrics.json').read_bytes()
            run_c_adapter(*args, sam=sam, resume=True)
            self.assertEqual(client.responses.create.call_count, 2)
            self.assertEqual((root / 'run/metrics.json').read_bytes(), metrics)
            for field, value in [('model', 'other'), ('device', 'mps'), ('rates', (11, 50)),
                                 ('budget', Budget(root / 'other-ledger'))]:
                changed = list(args)
                changed[{'model': 1, 'device': 5, 'rates': 7, 'budget': 6}[field]] = value
                with self.subTest(field=field), self.assertRaises(ValueError):
                    run_c_adapter(*changed, sam=sam, resume=True)
            for kw in ({'effort': 'high'}, {'max_side': 512}, {'seed': 99}):
                with self.assertRaises(ValueError):
                    run_c_adapter(*args, sam=sam, resume=True, **kw)
            Image.new('RGB', (100, 100), 'black').save(args[2])
            with self.assertRaises(ValueError):
                run_c_adapter(*args, sam=sam, resume=True)

    def test_actual_c_partial_resume_preserves_stage_metrics_even_on_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            client, args, sam = self.c_fixture(root)
            with patch('variant_c.segment_boxes', side_effect=RuntimeError('SAM unavailable')):
                with self.assertRaises(RuntimeError):
                    run_c_adapter(*args, sam=sam)
            path = root / 'run/parts_request/metrics.json'
            original = path.read_bytes()
            with patch('variant_c.segment_boxes', side_effect=RuntimeError('SAM unavailable')):
                with self.assertRaises(RuntimeError):
                    run_c_adapter(*args, sam=sam, resume=True)
            self.assertEqual(path.read_bytes(), original)
            run_c_adapter(*args, sam=sam, resume=True)
            self.assertEqual(path.read_bytes(), original)
            self.assertEqual(client.responses.create.call_count, 2)
            self.assertEqual(client.responses.input_tokens.count.call_count, 2)
            latency = json.loads((root / 'run/latency.json').read_text())
            self.assertTrue(latency['partial_recovery'])
            self.assertIsNone(latency['time_to_first_step_from_start_seconds'])
            self.assertIsNone(latency['first_box_model_only_seconds'])

    def test_actual_c_disconnect_retains_and_terminal_usage_settles(self):
        for failure, state in [('disconnect', 'reserved'), ('incomplete', 'settled')]:
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                client, args, sam = self.c_fixture(root, failure)
                with self.assertRaises((RuntimeError, ValueError)):
                    run_c_adapter(*args, sam=sam)
                key = hashlib.sha256(str((root / 'run/steps_request').resolve()).encode()).hexdigest() + ':gen'
                rows = json.loads((root / 'ledger').read_text())['requests']
                self.assertEqual(rows[key]['state'], state)
                with self.assertRaises((RuntimeError, ValueError)):
                    run_c_adapter(*args, sam=sam, resume=True)
                self.assertEqual(client.responses.create.call_count, 2)
                self.assertEqual(client.responses.input_tokens.count.call_count, 2)

    def test_c_cache_hash_mismatch_never_reissues(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            client, args, sam = self.c_fixture(root)
            with patch('variant_c.segment_boxes', side_effect=RuntimeError):
                with self.assertRaises(RuntimeError):
                    run_c_adapter(*args, sam=sam)
            atomic_json(root / 'run/parts_request/request_hash.json', {'request_hash': 'changed'})
            with self.assertRaises(ValueError):
                run_c_adapter(*args, sam=sam, resume=True)
            self.assertEqual(client.responses.create.call_count, 1)

    def test_invalid_counts_for_b_and_c(self):
        for value in (-1, True, 1.5, '100', None, 100001):
            for variant in ('b', 'c'):
                with self.subTest(value=value, variant=variant), tempfile.TemporaryDirectory() as tmp:
                    root = Path(tmp)
                    client, args, sam = self.c_fixture(root)
                    client.responses.input_tokens.count.return_value = SimpleNamespace(input_tokens=value)
                    with self.assertRaises(ValueError):
                        if variant == 'c':
                            run_c_adapter(*args, sam=sam)
                        else:
                            run_b_adapter(*args, process=lambda c, *a: c.responses.create(model='gpt-6-astra', input=[]))
                    client.responses.create.assert_not_called()

    def test_actual_request_b_latency_does_not_double_count(self):
        from variant_b import request_b
        from test_variant_b import client_for, plan, truth
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / 'source.png'
            self.image.save(source)
            client = client_for(plan())
            now = [0.0]
            response = client.responses.create.return_value
            def count(**kwargs):
                now[0] += 2
                return SimpleNamespace(input_tokens=100)
            def create(**kwargs):
                now[0] += 5
                return response
            client.responses.input_tokens = SimpleNamespace(count=Mock(side_effect=count))
            client.responses.create.side_effect = create
            with patch('time.perf_counter', side_effect=lambda: now[0]):
                run_b_adapter(client, 'gpt-6-astra', source, truth(), root / 'run', 'cpu', Budget(root / 'ledger'),
                              (10, 50), process=lambda c, m, s, t, d, dev: request_b(c, m, s, t, d))
            latency = json.loads((root / 'run/latency.json').read_text())
            self.assertEqual(latency['preflight_seconds'], 2)
            self.assertEqual(latency['first_box_model_only_seconds'], 5)
            self.assertEqual(latency['real_wall_time_to_first_box_seconds'], 7)

    def test_count_cannot_mutate_generation_payload(self):
        from realism import CResumeResponsesWrapper, payload_sha256
        for variant in ('b', 'c'):
            with self.subTest(variant=variant), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                original = [{'role': 'user', 'content': 'original'}]
                sent = []
                def count(**kwargs):
                    sent.append(json.loads(json.dumps(kwargs)))
                    kwargs['input'][0]['content'] = 'count mutated its copy'
                    original[0]['content'] = 'external mutation'
                    return SimpleNamespace(input_tokens=100)
                response = SimpleNamespace(model_dump=lambda **kw: {'usage': {'input_tokens': 100, 'output_tokens': 20}})
                client = SimpleNamespace(responses=SimpleNamespace(create=Mock(return_value=response),
                    input_tokens=SimpleNamespace(count=Mock(side_effect=count))))
                if variant == 'b':
                    run_b_adapter(client, 'model', root / 'image', {}, root / 'run', 'cpu', Budget(root / 'ledger'),
                                  (10, 50), process=lambda c, *a: c.responses.create(model='model', input=original, max_output_tokens=100))
                    pref_path = root / 'run/preflight.json'
                else:
                    wrapper = CResumeResponsesWrapper(client, root / 'run', Budget(root / 'ledger'), (10, 50))
                    wrapper.create(model='model', input=original, max_output_tokens=100)
                    pref_path = root / 'run/parts_request/preflight.json'
                created = client.responses.create.call_args.kwargs
                self.assertEqual(created['input'][0]['content'], 'original')
                self.assertEqual(sent[0], {k: created[k] for k in sent[0]})
                self.assertEqual(json.loads(pref_path.read_text())['hash'], payload_sha256(sent[0]))

    def test_c_both_cached_stages_preserve_metrics_and_summary_excludes_replay(self):
        from run_realism import summarize
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            client, args, sam = self.c_fixture(root)
            args = list(args)
            args[4] = root / 'results/sink/photo/original/run_1'
            run_c_adapter(*args, sam=sam)
            paths = [args[4] / f'{stage}_request/metrics.json' for stage in ('parts', 'steps')]
            original = [p.read_bytes() for p in paths]
            atomic_json(args[4].parent / 'transform.json', {'source_to_frame': np.eye(3).tolist(), 'size': [100, 100]})
            self.assertEqual(summarize(root / 'results')['first_box_full_response_seconds']['n'], 1)
            run_c_adapter(*args, sam=sam, resume=True)
            self.assertEqual([p.read_bytes() for p in paths], original)
            self.assertEqual(client.responses.create.call_count, 2)
            self.assertEqual(client.responses.input_tokens.count.call_count, 2)
            self.assertEqual(summarize(root / 'results')['first_box_full_response_seconds']['n'], 0)

    def test_percentiles(self):
        self.assertEqual(percentiles([]), {'n': 0, 'p50': None, 'p90': None})
        self.assertEqual(percentiles([1, 3])['p50'], 2)


if __name__ == '__main__':
    unittest.main()
