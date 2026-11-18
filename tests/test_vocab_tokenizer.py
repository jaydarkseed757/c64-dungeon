import pytest

import tokenizer
import vocab


def test_vocab_layout():
    assert vocab.VOCAB_SIZE <= 256
    assert vocab.TOKENS[:5] == ["PAD", "BOS", "EOS", "SEP", "UNK"]
    assert all(vocab.CHAR_ID[c] < vocab.FIRST_CONTROL_ID for c in vocab.TEXT_CHARS)
    assert vocab.ID["TASK:ROOM"] == vocab.FIRST_CONTROL_ID
    assert len(set(vocab.TOKENS)) == vocab.VOCAB_SIZE


def test_encode_example_roundtrip():
    ex = {"ctx": ["TASK:ROOM", "LOC:CRYPT"], "text": "a cold crypt."}
    ids, n_prompt = tokenizer.encode_example(ex)
    assert ids[0] == vocab.BOS and ids[n_prompt - 1] == vocab.SEP and ids[-1] == vocab.EOS
    assert tokenizer.decode(ids[n_prompt:]) == "a cold crypt."
    assert n_prompt == 4


def test_free_prompt_chars_precede_sep():
    ids, n_prompt = tokenizer.encode_example({"ctx": ["TASK:FREE"], "prompt": "where am i", "text": "x."})
    assert ids[n_prompt - 1] == vocab.SEP
    assert tokenizer.decode(ids[2:n_prompt - 1]) == "where am i"


def test_rejects_unknown_input():
    with pytest.raises(tokenizer.EncodeError):
        tokenizer.encode_text("Capital")
    with pytest.raises(tokenizer.EncodeError):
        tokenizer.encode_prompt(["ROOM:NOWHERE"])
    with pytest.raises(tokenizer.EncodeError):
        tokenizer.encode_prompt(["a"])          # text symbols are not control tokens


def test_petscii_table():
    table = tokenizer.petscii_input_table()
    assert table[0x41] == vocab.CHAR_ID["a"] == table[0xC1]
    assert table[0x20] == vocab.CHAR_ID[" "]
    assert table[0x0D] == vocab.UNK
    assert sum(t != vocab.UNK for t in table) == len(vocab.TEXT_CHARS) + 26


def test_display_capitalizes_sentences():
    assert tokenizer.display("the door opens. a rat! run?") == "The door opens. A rat! Run?"
