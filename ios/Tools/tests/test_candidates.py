"""Cheap checks of pinned downloads and preprocessing, with no network/model loads."""
import numpy as np
import pytest
from PIL import Image
from candidates import CANDIDATES, download
from sam_common import digest, prepare_image, prompt_box, restore_masks


def test_weight_checksums_pinned():
    for cfg in CANDIDATES.values():
        assert len(cfg['weights_sha256']) == 64
        int(cfg['weights_sha256'], 16)
        assert len(cfg['commit']) == 40


def test_download_rejects_bad_hash(tmp_path):
    source = tmp_path / 'source'; source.write_bytes(b'weights')
    target = tmp_path / 'target'
    with pytest.raises(ValueError, match='Checksum'):
        download(source.as_uri(), target, '0' * 64)
    assert not target.exists()
    download(source.as_uri(), target, digest(source))
    assert target.read_bytes() == b'weights'


def test_efficient_square_coordinates_and_image():
    np.testing.assert_allclose(prompt_box([0, 0, 1000, 1000], (512, 768), square=True), [0, 0, 1024, 1024])
    x = prepare_image(Image.new('RGB', (512, 768), (255, 0, 0)), square=True)
    np.testing.assert_array_equal(x[0, :, -1, -1], [255, 0, 0])
    assert restore_masks(np.ones((1, 3, 256, 256)), (512, 768), square=True).shape == (3, 768, 512)
