import struct
import zlib

import numpy as np
import pytest

import d64ai
import format_validator
from helpers import package, tiny_model


@pytest.fixture(scope="module")
def image_and_tensors():
    return package(tiny_model())


def test_roundtrip(image_and_tensors):
    image, tensors = image_and_tensors
    pkg = d64ai.read(image)
    for key, t in tensors.items():
        got = pkg.tensors[key]
        if isinstance(t, d64ai.Matrix):
            assert (got.w == t.w).all() and (got.s == t.s).all()
        else:
            assert (got == t).all()
    assert len(image) % 256 == 0
    assert all(e["offset"] % 256 == 0 for e in pkg.directory)
    assert pkg.header["vocab_hash"] == zlib.crc32(pkg.tokenizer)


def test_independent_validator_accepts(image_and_tensors):
    errors, _ = format_validator.validate(image_and_tensors[0])
    assert errors == []


def _refresh_crcs(b):
    struct.pack_into("<I", b, 56, zlib.crc32(bytes(b[256:])))
    struct.pack_into("<I", b, 252, zlib.crc32(bytes(b[:252])))


@pytest.mark.parametrize("mutate,message", [
    (lambda b: b.__setitem__(0, ord("X")), "signature"),
    (lambda b: b.__setitem__(6, 2), "major"),
    (lambda b: b.__setitem__(1000, b[1000] ^ 1), "CRC"),
    (lambda b: b.__setitem__(13, 9), "range"),              # n_layers 9 (with CRC refreshed)
    (lambda b: struct.pack_into("<H", b, 16, 256), "d_model"),
])
def test_corruption_rejected_by_both_readers(image_and_tensors, mutate, message):
    b = bytearray(image_and_tensors[0])
    mutate(b)
    if message in ("range", "d_model"):
        _refresh_crcs(b)
    with pytest.raises(d64ai.FormatError):
        d64ai.read(bytes(b))
    assert format_validator.validate(bytes(b))[0]


def test_truncated_image_rejected(image_and_tensors):
    with pytest.raises(d64ai.FormatError):
        d64ai.read(image_and_tensors[0][:-256])


def test_quantizer_refuses_out_of_range():
    import quantize
    with pytest.raises(quantize.QuantizeError):
        quantize.quantize_matrix(np.full((2, 4), 200.0), "big")
    with pytest.raises(quantize.QuantizeError):
        quantize.quantize_gain(np.array([9.0]), "gain")
    with pytest.raises(quantize.QuantizeError):
        quantize.quantize_matrix(np.array([[np.nan, 1.0]]), "nan")


def test_tile_rows_fit_window():
    for cols in (32, 64, 128, 256, 512):
        tr = d64ai.tile_rows_for(cols)
        assert tr * (cols + 3) <= d64ai.TILE_WINDOW
