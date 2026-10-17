import numpy as np
import pytest
from PIL import Image
from sam_common import MEAN, box_pixels, prompt_box, prepare_image, resized_size, mask_iou, restore_masks


def test_reference_box_and_prompt():
    box = [267, 89, 488, 169]
    np.testing.assert_array_equal(box_pixels(box, (512, 768)), [136, 68, 250, 130])
    np.testing.assert_allclose(prompt_box(box, (512, 768)),
                               [136*683/512, 68*1024/768, 250*683/512, 130*1024/768])


@pytest.mark.parametrize('box', [[0, 1, 0, 2], [0, 0, 1001, 10], [0, 0, float('nan'), 2], [True, 0, 2, 3]])
def test_bad_box(box):
    with pytest.raises(ValueError):
        prompt_box(box, (512, 768))


def test_letterbox():
    assert resized_size((512, 768)) == (683, 1024)
    image = Image.new('RGB', (512, 768), (255, 0, 0))
    x = prepare_image(image)
    assert x.shape == (1, 3, 1024, 1024) and x.dtype == np.float32
    np.testing.assert_array_equal(x[0, :, 0, 0], [255, 0, 0])
    np.testing.assert_array_equal(x[0, :, 0, 683], MEAN)
    landscape = prepare_image(Image.new('RGB', (768, 512)))
    np.testing.assert_array_equal(landscape[0, :, 683, 0], MEAN)


def test_iou():
    assert mask_iou([0, 1, 1], [1, 1, 0]) == 1/3
    assert mask_iou([0], [0]) == 1
    assert mask_iou([1], [0]) == 0
    with pytest.raises(ValueError):
        mask_iou([0], [[0]])


def test_postprocess_crops_padding_before_threshold():
    logits = np.ones((1, 1, 256, 256), np.float32)
    logits[..., 192:, :] = -100
    masks = restore_masks(logits, (768, 384))
    assert masks.shape == (1, 384, 768) and masks.all()
