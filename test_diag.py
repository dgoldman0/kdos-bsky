import os, sys
EMU_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "emu")
sys.path.insert(0, EMU_DIR)
# reuse the test_bsky machinery 
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_bsky import build_snapshot, run_forth, jstr

build_snapshot()

# Test 1: Does JSON-FIND-KEY work?
json_str = '{"accessJwt":"atok","refreshJwt":"rtok","did":"did:plc:abc","handle":"me.bsky.social"}'
out = run_forth(
    ['BSK-INIT'] +
    jstr(json_str) +
    [': _T TA',
     '  ." TBUF=" OVER . DUP . CR',
     '  S" accessJwt" JSON-FIND-KEY',
     '  ." FK=" OVER . DUP . CR',
     '  DUP 0= IF ." NOTFOUND" CR 2DROP ELSE',
     '    JSON-GET-STRING',
     '    ." GS=" OVER . DUP . CR',
     '    TYPE',
     '  THEN CR ; _T']
)
print("=== JSON-FIND-KEY + GET-STRING test ===")
for line in out.strip().split('\n'):
    line = line.strip()
    if any(line.startswith(p) for p in ('TBUF=', 'FK=', 'GS=', 'NOT', 'atok')):
        print(f"  {line}")

# Test 2: Step through _BSK-PARSE-SESSION field by field
out2 = run_forth(
    ['BSK-INIT'] +
    jstr(json_str) +
    [': _T TA',
     '  2DUP S" accessJwt" BSK-ACCESS-JWT BSK-JWT-MAX BSK-ACCESS-LEN _BSK-EXTRACT-FIELD ." F1=" . CR',
     '  2DUP S" refreshJwt" BSK-REFRESH-JWT BSK-JWT-MAX BSK-REFRESH-LEN _BSK-EXTRACT-FIELD ." F2=" . CR',
     '  2DUP S" did" BSK-DID BSK-DID-MAX BSK-DID-LEN _BSK-EXTRACT-FIELD ." F3=" . CR',
     '  S" handle" BSK-HANDLE BSK-HANDLE-MAX BSK-HANDLE-LEN _BSK-EXTRACT-FIELD ." F4=" . CR',
     ' ; _T']
)
print("\n=== Step-by-step field extraction ===")
for line in out2.strip().split('\n'):
    line = line.strip()
    if line.startswith('F'):
        print(f"  {line}")

