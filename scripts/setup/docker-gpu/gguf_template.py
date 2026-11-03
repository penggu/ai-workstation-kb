#!/usr/bin/env python3
"""Write a GGUF file's own chat template to a file, with ONE change: a system message that comes after the
conversation has started is rendered as a system turn instead of raising "System message must be at the beginning."

usage: gguf_template.py MODEL.gguf OUT.jinja

Why: the Qwen3.8 template refuses a late system message. Clients that speak the OpenAI/Anthropic APIs
(Claude Code among them) can send one, and the server then answers HTTP 500 and the client retries forever.
The script reads only the metadata at the start of the model file (it does not load the model). It refuses to
write anything unless the expected line occurs exactly once, so a different template is never patched blindly.
"""
import struct
import sys

RAISE = "{{- raise_exception('System message must be at the beginning.') }}"
REPLACEMENT = "{{- '<|im_start|>system\\n' + content + '<|im_end|>\\n' }}"
SIZES = {0: "B", 1: "b", 2: "H", 3: "h", 4: "I", 5: "i", 6: "f", 7: "?", 10: "Q", 11: "q", 12: "d"}


def main():
    path, out = sys.argv[1:3]
    f = open(path, "rb")
    if f.read(4) != b"GGUF":
        sys.exit("not a GGUF file: " + path)

    def rd(fmt):
        return struct.unpack("<" + fmt, f.read(struct.calcsize("<" + fmt)))

    def rstr():
        n, = rd("Q")
        return f.read(n).decode("utf-8", "replace")

    def rval(t):
        if t == 8:
            return rstr()
        if t == 9:
            et, = rd("I"); n, = rd("Q")
            if et in (8, 9):
                return [rval(et) for _ in range(n)]
            f.seek(n * struct.calcsize("<" + SIZES[et]), 1)
            return None
        return rd(SIZES[t])[0]

    rd("I")                      # version
    _tensors, nkv = rd("QQ")
    tpl = None
    for _ in range(nkv):
        key = rstr(); t, = rd("I"); val = rval(t)
        if key == "tokenizer.chat_template":
            tpl = val
            break
    if not tpl:
        sys.exit("no tokenizer.chat_template in " + path)
    if tpl.count(RAISE) != 1:
        sys.exit(f"expected the line to patch exactly once, found {tpl.count(RAISE)}: not patching an unknown template")
    open(out, "w").write(tpl.replace(RAISE, REPLACEMENT))
    print(f"wrote {out} ({len(tpl)} chars, 1 line changed)")


if __name__ == "__main__":
    main()
