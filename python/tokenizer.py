"""DM64 tokenizer: character-level text plus structured control tokens.

Sequence layout for one example (ids from vocab.py):

    BOS  ctx-control-tokens...  [prompt chars (TASK:FREE only)]  SEP  text chars...  EOS

The training loss covers only the positions that predict text and EOS (the
tokens after SEP). The prompt is given, not learned.

The same tables are packaged into the .d64ai tokenizer section (PETSCII), so
the C64 tokenizer is a 256-byte lookup.
"""
import vocab

# ASCII text symbol -> PETSCII code as stored on the C64 (lowercase/uppercase
# character set: unshifted letters $41-$5A display as lowercase).
def ascii_to_petscii(c):
    if "a" <= c <= "z":
        return ord(c) - ord("a") + 0x41
    if c in "0123456789 .,!?'\"-:;":
        return ord(c)
    raise ValueError(f"no PETSCII mapping for {c!r}")


def petscii_input_table():
    """256-entry PETSCII keyboard code -> token id (UNK when unmapped)."""
    table = [vocab.UNK] * 256
    for c, tid in vocab.CHAR_ID.items():
        code = ascii_to_petscii(c)
        table[code] = tid
        if 0x41 <= code <= 0x5A:
            table[code + 0x80] = tid      # shifted letters ($C1-$DA) map to the same token
    return table


class EncodeError(ValueError):
    pass


def encode_text(text):
    try:
        return [vocab.CHAR_ID[c] for c in text]
    except KeyError as e:
        raise EncodeError(f"character {e.args[0]!r} is not in the vocabulary") from None


def encode_prompt(ctx, prompt=None):
    """Context tokens (+ optional typed prompt) up to and including SEP."""
    ids = [vocab.BOS]
    for name in ctx:
        if name not in vocab.ID or vocab.ID[name] < vocab.FIRST_CONTROL_ID:
            raise EncodeError(f"unknown control token {name!r}")
        ids.append(vocab.ID[name])
    if prompt:
        ids += encode_text(prompt)
    ids.append(vocab.SEP)
    return ids


def encode_example(example):
    """Returns (ids, n_prompt). ids[n_prompt:] is the learned continuation."""
    prompt_ids = encode_prompt(example["ctx"], example.get("prompt"))
    return prompt_ids + encode_text(example["text"]) + [vocab.EOS], len(prompt_ids)


def decode(ids):
    out = []
    for i in ids:
        if i == vocab.EOS:
            break
        name = vocab.TOKENS[i]
        if vocab.FIRST_TEXT_ID <= i < vocab.FIRST_TEXT_ID + len(vocab.TEXT_CHARS):
            out.append(name)
        else:
            out.append(f"‹{name}›")
    return "".join(out)


def display(text):
    """Capitalize sentence starts, as the C64 output module will."""
    out, cap = [], True
    for c in text:
        if cap and c.isalpha():
            out.append(c.upper())
            cap = False
        else:
            out.append(c)
        if c in ".!?":
            cap = True
    return "".join(out)
