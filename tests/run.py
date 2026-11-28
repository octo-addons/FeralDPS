"""Checks a FeralDPS.lua against a scripted stand-in for the 1.12 client.

    pip install lupa
    python tests/run.py FeralDPS/FeralDPS.lua          # the file being worked on
    python tests/run.py path/to/older/FeralDPS.lua old # an older version, for comparison

The stand-in (mock.lua) is a model of the game, not the game, and it runs on a
newer Lua than the client's 5.0 - a pass here is necessary, not sufficient.
"""
import os, sys
import lupa

here = os.path.dirname(os.path.abspath(__file__)).replace("\\", "/") + "/"
addon = os.path.abspath(sys.argv[1]).replace("\\", "/")
is_new = not (len(sys.argv) > 2 and sys.argv[2] == "old")
L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.globals().TEST_DIR = here
src = open(addon, encoding="utf-8").read()
err = L.execute("return function(s) local f, e = load(s); return e end")(src)
print("syntax: " + ("ok" if err is None else str(err)))
scenarios = L.execute('return dofile(TEST_DIR .. "run.lua")')(addon, is_new)
smoke = L.execute('return dofile(TEST_DIR .. "smoke.lua")')(addon)
print(scenarios)
print(smoke)
sys.exit(1 if ("FAIL" in scenarios or "FAIL" in smoke or err is not None) else 0)
