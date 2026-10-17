import json
from pathlib import Path
import tempfile
import unittest
import numpy as np
from report_hybrid import evaluate_run


class ReportHybridTests(unittest.TestCase):
    def test_visible_mask_resize_and_empty_union(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            run, truth = root/'run', root/'truth'
            run.mkdir(); truth.mkdir()
            (run/'plan.json').write_text(json.dumps({'steps': [
                {'focus':['p1'], 'avoid':[]}, {'focus':[], 'avoid':['p1']}]}))
            (truth/'truth.json').write_text(json.dumps({'steps':[
                {'focus':[0], 'avoid':[]}, {'focus':[], 'avoid':[0]}]}))
            np.savez_compressed(run/'masks.npz', masks=np.ones((1,2,2),bool))
            np.savez_compressed(truth/'truth_masks.npz', visible=np.ones((1,4,4),bool))
            rows=evaluate_run(run,truth)
            self.assertEqual([r['focus_iou'] for r in rows],[1.,1.])
            self.assertEqual([r['empty_focus'] for r in rows],[False,True])
            self.assertEqual([r['avoid_iou'] for r in rows],[1.,1.])

    def test_step_count_mismatch_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            (root/'plan.json').write_text(json.dumps({'steps':[]}))
            (root/'truth.json').write_text(json.dumps({'steps':[{'focus':[]}]}))
            np.savez_compressed(root/'masks.npz',masks=np.ones((1,2,2),bool))
            np.savez_compressed(root/'truth_masks.npz',visible=np.ones((1,2,2),bool))
            with self.assertRaises(ValueError): evaluate_run(root,root)

if __name__=='__main__': unittest.main()
