"""End-to-end generation through the public engine API, in VICE, vs python/reference_int.py."""
import shutil
import struct
from pathlib import Path

import pytest

import d64ai
import tokenizer
from reference_int import IntEngine

pytestmark = pytest.mark.skipif(not shutil.which("x64sc") or not shutil.which("acme"),
                                reason="needs VICE (x64sc) and ACME")
ROOT = Path(__file__).resolve().parents[1]


def petscii_to_text(b):
    out = []
    for c in b:
        if 0x41 <= c <= 0x5A:
            out.append(chr(c + 32))       # unshifted letter: lowercase in the mixed-case set
        elif 0xC1 <= c <= 0xDA:
            out.append(chr(c - 0x80))     # shifted letter: capital
        else:
            out.append(chr(c))
    return "".join(out)


def generate_on_c64(package, prompt_ids, max_chars=40, inv_temp=0, top_k=1, seed=1, skip_crc=0):
    from engine_harness import assemble
    from vice_harness import Vice
    prg, labels = assemble(ROOT / "engine/tests/api_host.asm", "api_host")
    vm = Vice(reu_image=package)
    try:
        vm.load_prg(prg)
        vm.write(0xC800, bytes([len(prompt_ids)] + prompt_ids))
        vm.write(0xC900, bytes([max_chars, inv_temp & 0xFF, inv_temp >> 8, top_k])
                 + seed.to_bytes(4, "little") + bytes([skip_crc]))
        vm.run_until(labels["test_done"], timeout=1800)
        status = list(vm.read(0xC940, 0xC943))
        cycles = struct.unpack("<I", vm.read(0xC950, 0xC953))[0]
        n = vm.read(0xC700, 0xC700)[0]
        text = petscii_to_text(vm.read(0xC701, 0xC700 + n)) if n else ""
        return status, text, cycles
    finally:
        vm.close()


CASES = [
    ("bringup", ["TASK:ROOM", "LOC:CRYPT", "ROOM:BURIAL_CHAMBER"], None, 0, 1, 1, 60),
    ("bringup", ["TASK:MONSTER", "MON:ORC", "MST:WOUNDED"], None, 320, 8, 12345, 40),
    ("bringup", ["TASK:FREE"], "describe a dungeon", 0, 1, 1, 30),
    pytest.param("baseline", ["TASK:ACTION", "OBJ:DOOR", "ACT:OPEN", "OUT:LOCKED"], None, 0, 1, 1, 60,
                 marks=pytest.mark.slow),
    pytest.param("baseline", ["TASK:ROOM", "LOC:CRYPT", "ROOM:BURIAL_CHAMBER"], None, 320, 8, 99, 50,
                 marks=pytest.mark.slow),
]


@pytest.mark.parametrize("name,ctx,prompt,inv_temp,top_k,seed,max_chars", CASES)
def test_generation_matches_reference(name, ctx, prompt, inv_temp, top_k, seed, max_chars):
    path = ROOT / f"models/exported/{name}.d64ai"
    if not path.exists():
        pytest.skip(f"run `make convert MODEL={name}` first")
    ids = tokenizer.encode_prompt(ctx, prompt)
    ref = IntEngine(d64ai.read(path.read_bytes()))
    want_ids = ref.generate(ids, max_chars=max_chars, inv_temp_q8=inv_temp, top_k=top_k, seed=seed)
    want = tokenizer.display(tokenizer.decode(want_ids))
    status, got, cycles = generate_on_c64(path, ids, max_chars, inv_temp, top_k, seed,
                                          skip_crc=int(name != "bringup"))
    assert status[:4] == [0, 0, 0, 0], status
    print(f"\n{name} {' '.join(ctx)}: {got!r}  ({cycles:,} cycles for "
          f"{len(ids)} prompt + {len(want_ids)} generated tokens, VICE 1 MHz)")
    assert got == want


def test_api_errors_without_model(tmp_path):
    """No model in the REU: AI_LOAD_MODEL must fail with a signature error."""
    blank = tmp_path / "blank.bin"
    blank.write_bytes(bytes(1024))
    status, _, _ = generate_on_c64(blank, [1, 64, 3])
    assert status[0] == 0 and status[1] == 0x05


def test_letter_group_tokens(tmp_path):
    """bpe72 layout (256 ids, multi-letter text tokens): engine output equals the reference."""
    import convert
    import d64ai
    import lexicon
    import quantize
    from helpers import tiny_model
    from reference_int import IntEngine
    lex = lexicon.load("bpe72")
    model = tiny_model(seed=5, vocab_size=lex.VOCAB_SIZE, ctx_len=128, d_model=32, n_layers=2,
                       n_heads=2, d_ff=64)
    cfg = model.cfg.to_dict()
    image = d64ai.write(cfg, quantize.quantize_state(model.state_dict(), cfg),
                        convert.build_tokenizer_section(lex), "test=1\n",
                        rms_eps_q32=round(model.cfg.rms_eps * 2**32), inv_sqrt_head_q24=0,
                        special={n: lex.ID[n] for n in lex.SPECIALS},
                        first_control_id=lex.FIRST_CONTROL_ID, model_version="bpe-test",
                        model_name=b"T", source_sha256=bytes(32))
    path = tmp_path / "bpe.d64ai"
    path.write_bytes(image)
    ref = IntEngine(d64ai.read(image))
    ids = lex.encode_prompt(["TASK:ROOM", "LOC:CRYPT", "ROOM:LIBRARY"])
    want_ids = ref.generate(ids, max_chars=40)
    assert any(len(lex.TOKENS[t]) > 1 for t in want_ids if t != lex.EOS), "test needs letter groups"
    want = lexicon.display(ref.decode(want_ids))
    status, got, _ = generate_on_c64(path, ids, max_chars=40, skip_crc=1)
    assert status[:4] == [0, 0, 0, 0], status
    assert got == want
