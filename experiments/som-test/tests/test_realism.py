import json
from pathlib import Path
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

import numpy as np
from PIL import Image

from realism import (Budget, KINDS, atomic_json, degrade, mask_truth, match_frames,
                     percentiles, run_b_adapter)
from evaluation import truth_masks


class RealismTests(unittest.TestCase):
    def setUp(self):
        self.image = Image.fromarray(np.full((80,100,3),180,np.uint8))
        self.masks = np.zeros((1,80,100),bool)
        self.masks[0,20:60,30:70] = True

    def test_deterministic_and_visibility(self):
        for kind in KINDS:
            a = degrade(self.image,self.masks,kind,42)
            b = degrade(self.image,self.masks,kind,42)
            np.testing.assert_array_equal(a[0],b[0])
            np.testing.assert_array_equal(a[1],b[1])
            self.assertEqual(a[3],b[3])
            self.assertTrue(np.all(a[2] <= a[1]))
        _,full,visible,_ = degrade(self.image,self.masks,'occlusion',42)
        self.assertLess(visible.sum(),full.sum())

    def test_shift_mask_and_roundtrip_truth(self):
        _,full,_,meta = degrade(self.image,self.masks,'shift_right')
        self.assertEqual(meta['source_to_frame'][0][2],4)
        self.assertTrue(full[0,21,34])
        truth = {'parts':[{'name':'part','path':''}], 'steps':[]}
        converted = mask_truth(truth,full,self.image.size)
        np.testing.assert_array_equal(truth_masks(converted,self.image.size),full)
        blank = mask_truth(truth,np.zeros_like(full),self.image.size)
        self.assertEqual(truth_masks(blank,self.image.size).sum(),0)

    def test_geometry_ignores_raw_labels_and_ids(self):
        a = [{'id':'a','label':'old','box':[300,250,700,750]}]
        b = [{'id':'b','label':'new','box':[340,262.5,740,762.5]},
             {'id':'c','label':'other','box':[0,0,50,50]}]
        original = degrade(self.image,self.masks,'original')[3]
        shifted = degrade(self.image,self.masks,'shift_right')[3]
        result = match_frames(a,b,original,shifted,.9)
        self.assertEqual(len(result['matches']),1)
        self.assertAlmostEqual(result['matches'][0]['iou'],1)
        self.assertEqual(result['phone_ids'],['phone_1','phone_2'])
        self.assertEqual(result['raw_id_stability'],0)
        self.assertEqual(result['unmatched'],[1])
        duplicate = match_frames(a,b[:1]*2,original,shifted,.9)
        self.assertEqual(len(duplicate['matches']),1)
        self.assertEqual(match_frames(a,[],original,original)['dropout'],[0])

    def test_budget_persists_failures_and_caps(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/'ledger.json'
            Budget(path).change('first',10)
            with self.assertRaises(RuntimeError):
                Budget(path).change('first',10)
            with self.assertRaises(RuntimeError):
                Budget(path).change('second',6)
            Budget(path).change('first',2,settle=True)
            Budget(path).change('second',13)
            with self.assertRaises(ValueError):
                Budget(path).change('second',14,settle=True)
            self.assertEqual(json.loads(path.read_text())['requests']['second']['usd'],13)
            with self.assertRaises(ValueError):
                Budget(path,16)

    def test_adapter_failed_api_not_retried_and_cached_plan_resume(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            client = SimpleNamespace(responses=SimpleNamespace(create=Mock(side_effect=TimeoutError)))
            def process(client,model,source,truth,dest,device):
                return client.responses.create(max_output_tokens=12000)
            for exception in (TimeoutError,RuntimeError):
                with self.assertRaises(exception):
                    run_b_adapter(client,'model',root/'img',{},root/'run','cpu',Budget(root/'ledger'),(10,50),process)
            self.assertEqual(client.responses.create.call_count,1)
            # B can resume SAM from an already valid persisted plan, without API.
            result = run_b_adapter(client,'model',root/'img',{},root/'run','cpu',Budget(root/'ledger'),(10,50),
                                   lambda *args: {'parts':[]})
            self.assertEqual(result,{'parts':[]})
            self.assertEqual(client.responses.create.call_count,1)

    def test_adapter_settles_and_unknown_price_blocks(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            response = SimpleNamespace(model_dump=lambda **kw: {'usage':{'input_tokens':100,'output_tokens':20}})
            client = SimpleNamespace(responses=SimpleNamespace(create=Mock(return_value=response)))
            def process(c,m,s,t,d,device):
                c.responses.create(max_output_tokens=12000)
                atomic_json(d/'metrics.json',{'seconds':2})
                atomic_json(d/'segmentation.json',{'seconds':3})
                return {}
            with self.assertRaises(ValueError):
                run_b_adapter(client,'unknown',root/'img',{},root/'run','cpu',Budget(root/'ledger'),None,process)
            self.assertEqual(client.responses.create.call_count,0)
            run_b_adapter(client,'model',root/'img',{},root/'run','cpu',Budget(root/'ledger'),(10,50),process)
            row = next(iter(json.loads((root/'ledger').read_text())['requests'].values()))
            self.assertEqual(row['state'],'settled')
            self.assertAlmostEqual(row['usd'],.002)
            self.assertEqual(json.loads((root/'run/latency.json').read_text())['first_box_full_response_seconds'],2)

    def test_cli_dry_run_and_changed_seed_rejected(self):
        import run_realism
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root/'Camera/assets').mkdir(parents=True)
            self.image.save(root/'Camera/assets/test.png')
            truth = {'design_size':[100,80], 'parts':[{'name':'part','path':'M30 20 L69 20 L69 59 L30 59 Z'}],
                     'steps':[{'title':'test','text':'test','focus':[0],'avoid':[]}]}
            atomic_json(root/'out/test/ground_truth.json',truth)
            args = ['--dry-run','--scenes','test','--kinds','original','shift_right','--out',str(root/'results')]
            with patch.object(run_realism,'HERE',root), patch.object(run_realism,'ROOT',root), \
                 patch.object(run_realism,'SCENES',{'test':('test.png','unused')}), \
                 patch.object(run_realism,'run_b_adapter',side_effect=AssertionError('API forbidden')):
                self.assertEqual(run_realism.main(args),0)
                self.assertEqual(run_realism.main(args+['--resume']),0)
                self.assertEqual(run_realism.main(args+['--seed','99']),1)
            meta = json.loads((root/'results/test/test/shift_right/transform.json').read_text())
            self.assertEqual(meta['source_to_frame'][0][2],4)

    def test_real_b_adapter_mock_sam_and_cached_resume(self):
        from test_variant_b import plan, truth, client_for, sam_for_boxes
        from run_realism import prepare, proxy_evaluation
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root/'source.jpg'
            Image.new('RGB',(100,100),'gray').save(source)
            frame = root/'original'
            prepare(source,truth(),frame,'original',7)
            adapted_truth = json.loads((frame/'truth.json').read_text())
            client = client_for(plan())
            budget = Budget(root/'ledger')
            with patch('variant_b.make_sam',return_value=sam_for_boxes):
                result = run_b_adapter(client,'gpt-6-astra',frame/'image.png',adapted_truth,frame/'run_1','cpu',budget,(10,50))
                proxy_evaluation(frame/'run_1',result,truth())
                run_b_adapter(client,'gpt-6-astra',frame/'image.png',adapted_truth,frame/'run_1','cpu',budget,(10,50))
            self.assertEqual(client.responses.create.call_count,1)
            self.assertTrue((frame/'run_1/proxy.json').exists())
            self.assertTrue((frame/'run_1/parts.png').exists())
            # Real photos retain instructions only and never inherit design masks.
            prepare(source,truth(),root/'real','original',7,real=True)
            with np.load(root/'real/truth_masks.npz') as masks:
                self.assertEqual(masks['full'].sum(),0)

    def test_percentiles(self):
        self.assertEqual(percentiles([]),{'n':0,'p50':None,'p90':None})
        self.assertEqual(percentiles([1,3])['p50'],2)


if __name__ == '__main__':
    unittest.main()
