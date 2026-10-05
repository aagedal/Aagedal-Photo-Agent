import math
import unittest
from detect import compare_message, SCOPE, summarize


class DetectionPolicyTests(unittest.TestCase):
    def test_no_verdict_without_known_message(self):
        self.assertEqual(compare_message('1'*256, None)['status'], 'inconclusive')

    def test_threshold_cannot_classify_diagnostic_channel(self):
        with self.assertRaises(ValueError):
            compare_message('1'*256, None, 0.9)

    def test_known_message_requires_explicit_threshold_for_verdict(self):
        result = compare_message('1'*256, '1'*256)
        self.assertEqual(result['status'], 'inconclusive')
        self.assertEqual(result['bit_match_fraction'], 1)

    def test_known_message_match_boundary(self):
        self.assertEqual(compare_message('1'*128+'0'*128, '1'*256, 0.5)['status'], 'known_message_match')
        self.assertEqual(compare_message('1'*127+'0'*129, '1'*256, 0.5)['status'], 'known_message_not_matched')

    def test_invalid_thresholds_and_payloads(self):
        for threshold in (0, 1, math.nan, math.inf):
            with self.assertRaises(ValueError):
                compare_message('1'*256, '1'*256, threshold)
        for expected in ('', '1'*255, 'x'*256, '1'*257):
            with self.assertRaises(ValueError):
                compare_message('1'*256, expected)

    def test_scope_names_production_compatibility_limit(self):
        self.assertIn('does not detect all Meta-generated images', SCOPE)
        self.assertIn('proprietary production watermark', SCOPE)


try:
    import torch
except ImportError:
    torch = None


@unittest.skipIf(torch is None, 'PyTorch required for tensor validation')
class PredictionTests(unittest.TestCase):
    def test_pooled_and_spatial_predictions_agree(self):
        pooled = torch.ones(1,257)
        pooled[:,1::2] = -1
        score,bits = summarize(pooled,torch)
        spatial = pooled[:,:,None,None].expand(1,257,2,2)
        self.assertEqual(summarize({'preds':spatial},torch),(score,bits))
        self.assertEqual(bits,'01'*128)

    def test_wrong_model_output_and_nan_rejected(self):
        for tensor in (torch.zeros(1,97), torch.zeros(2,257), torch.zeros(1,257,2), torch.full((1,257),math.nan)):
            with self.assertRaises(ValueError):
                summarize(tensor,torch)


if __name__ == '__main__':
    unittest.main()
