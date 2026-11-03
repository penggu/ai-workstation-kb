#!/usr/bin/env python3
"""Write a GGUF file's own chat template to a file, with TWO changes, each replacing a hard error that a client
such as Claude Code can trigger with a harmless rendering:

  1. a system message that comes after the conversation has started is rendered as a system turn
     (instead of raising "System message must be at the beginning.")
  2. a content block the template does not know (anything but text/image/video) is dropped if it is a thinking block,
     and otherwise replaced by a visible marker "[content of type X omitted]"
     (instead of raising "Unexpected item type in content.")

usage: gguf_template.py MODEL.gguf OUT.jinja

Why: the Qwen3.8 template raises on both. Clients that speak the OpenAI/Anthropic APIs (Claude Code among them)
can send either, and the server then answers HTTP 500 and the client retries until it gives up.
The script reads only the metadata at the start of the model file (it does not load the model). It refuses to
write anything unless every line to patch occurs exactly once, so a different template is never patched blindly.
"""
import struct
import sys

PATCHES = [
    ("late system message",
     "{{- raise_exception('System message must be at the beginning.') }}",
     "{{- '<|im_start|>system\\n' + content + '<|im_end|>\\n' }}"),
    ("unknown content block",
     "{{- raise_exception('Unexpected item type in content.') }}",
     "{%- if 'type' in item and item.type in ['thinking', 'redacted_thinking'] %}\n"
     "                {%- else %}\n"
     "                    {{- '[content of type ' ~ (item.type if 'type' in item else 'unknown') ~ ' omitted]' }}\n"
     "                {%- endif %}"),
]
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
    for name, old, _new in PATCHES:
        if tpl.count(old) != 1:
            sys.exit(f"patch '{name}': expected its line exactly once, found {tpl.count(old)}: not patching an unknown template")
    tpl_out = tpl
    for _name, old, new in PATCHES:
        tpl_out = tpl_out.replace(old, new)
    open(out, "w").write(tpl_out)
    print(f"wrote {out} ({len(tpl)} chars, {len(PATCHES)} lines changed)")


if __name__ == "__main__":
    main()
