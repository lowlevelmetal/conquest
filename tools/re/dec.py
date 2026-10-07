"""Query Ghidra's full decompilation (ref/ghidra/<binary>.c).

  dec.py fn <rva|name> [...]     print functions
  dec.py callers <name|rva>      functions that call it
  dec.py callees <name|rva>      functions it calls
  dec.py grep <regex>            functions whose body matches
"""
import os, re, sys

ROOT = os.path.join(os.path.dirname(__file__), '..', '..', 'ref', 'ghidra')
HEADER = re.compile(r'^// FUNCTION (\S+) @ ([0-9a-f]+) rva=([0-9a-f]+)')


def load(binary):
    funcs, order = {}, []
    cur = None
    with open(os.path.join(ROOT, binary + '.c'), encoding='utf-8', errors='replace') as f:
        for line in f:
            m = HEADER.match(line)
            if m:
                cur = {'name': m.group(1), 'va': int(m.group(2), 16), 'rva': int(m.group(3), 16), 'lines': []}
                funcs[cur['name']] = cur
                order.append(cur)
            elif cur:
                cur['lines'].append(line)
    return funcs, order


def find(funcs, order, key):
    if key in funcs:
        return funcs[key]
    try:
        rva = int(key, 16)
    except ValueError:
        return None
    for f in order:
        if f['rva'] == rva:
            return f
    return None


def main():
    binary = os.environ.get('BIN', 'Battlefront2.dll')
    cmd, args = sys.argv[1], sys.argv[2:]
    funcs, order = load(binary)
    if cmd == 'fn':
        for a in args:
            f = find(funcs, order, a)
            print(f"// {f['name']} rva={f['rva']:x}" if f else f'// {a}: not found')
            if f:
                sys.stdout.write(''.join(f['lines']))
    elif cmd == 'callers':
        f = find(funcs, order, args[0])
        pat = re.compile(r'\b' + re.escape(f['name']) + r'\b')
        for g in order:
            if g is not f and any(pat.search(l) for l in g['lines']):
                print(f"{g['name']} rva={g['rva']:x}")
    elif cmd == 'callees':
        f = find(funcs, order, args[0])
        names = sorted(set(re.findall(r'\b(FUN_[0-9a-f]+|[A-Za-z_][A-Za-z0-9_]*)\(', ''.join(f['lines']))))
        print(' '.join(n for n in names if n in funcs and n != f['name']))
    elif cmd == 'grep':
        pat = re.compile(args[0])
        for g in order:
            if any(pat.search(l) for l in g['lines']):
                print(f"{g['name']} rva={g['rva']:x}")


if __name__ == '__main__':
    main()
