-- tests/vnext/conformance/tests/test-jsonpatch.lua
-- lib/jsonpatch.lua: the RFC 6902 subset (add, replace, remove) the
-- metadata-binding fixtures use to express each fixture as a named base
-- document plus a short patch. Pointer decoding is lib/jsonschema.lua's
-- (percent- then tilde-decoding, zero-based canonical array indices).
local patch = require("lib.jsonpatch")
local json = require("lib.json")

local function doc() return json.decode('{"a":{"b":1,"c":[10,20]},"k/x":{"~t":true},"e":[]}') end
local function raises(fn, what)
  local okflag = pcall(fn)
  assert(not okflag, "expected an error: " .. what)
end

return {
  { name = "add sets an object member, replacing an existing one", fn = function()
      local d = patch.apply(doc(), { { op = "add", path = "/a/d", value = "new" },
        { op = "add", path = "/a/b", value = 2 } })
      assert(d.a.d == "new" and d.a.b == 2)
    end },
  { name = "add inserts into arrays at a zero-based index or appends with -", fn = function()
      local d = patch.apply(doc(), { { op = "add", path = "/a/c/0", value = 5 },
        { op = "add", path = "/a/c/-", value = 30 }, { op = "add", path = "/e/-", value = "x" } })
      assert(d.a.c[1] == 5 and d.a.c[2] == 10 and d.a.c[3] == 20 and d.a.c[4] == 30, "array insert/append wrong")
      assert(d.e[1] == "x", "append to an empty array failed")
    end },
  { name = "replace requires an existing target", fn = function()
      local d = patch.apply(doc(), { { op = "replace", path = "/a/c/1", value = 99 } })
      assert(d.a.c[2] == 99)
      raises(function() patch.apply(doc(), { { op = "replace", path = "/a/zz", value = 1 } }) end, "replace of a missing member")
      raises(function() patch.apply(doc(), { { op = "replace", path = "/a/c/2", value = 1 } }) end, "replace past the array end")
    end },
  { name = "remove deletes object members and array elements", fn = function()
      local d = patch.apply(doc(), { { op = "remove", path = "/a/b" }, { op = "remove", path = "/a/c/0" } })
      assert(d.a.b == nil and #d.a.c == 1 and d.a.c[1] == 20)
      raises(function() patch.apply(doc(), { { op = "remove", path = "/a/nope" } }) end, "remove of a missing member")
    end },
  { name = "pointer segments are tilde-decoded", fn = function()
      local d = patch.apply(doc(), { { op = "replace", path = "/k~1x/~0t", value = false } })
      assert(d["k/x"]["~t"] == false)
    end },
  { name = "a JSON null value is stored, not dropped", fn = function()
      local d = patch.apply(doc(), { { op = "add", path = "/a/n", value = pandoc.json.null } })
      assert(d.a.n == pandoc.json.null)
    end },
  { name = "added values are copies, never aliases of the patch", fn = function()
      local v = { deep = { 1 } }
      local d = patch.apply(doc(), { { op = "add", path = "/a/v", value = v } })
      d.a.v.deep[1] = 2
      assert(v.deep[1] == 1, "patch value was aliased into the document")
    end },
  { name = "expand resolves {$base, $patch} anywhere, including inside bases", fn = function()
      local files = {
        ["bases/inner.json"] = json.decode('{"x":1,"y":[1]}'),
        ["bases/outer.json"] = json.decode('{"inner":{"$base":"bases/inner.json","$patch":[{"op":"replace","path":"/x","value":2}]},"z":0}'),
      }
      local loads = 0
      local function load(rel) loads = loads + 1; return assert(files[rel], "no file " .. rel) end
      local v = patch.expand(json.decode('{"keep":"me","doc":{"$base":"bases/outer.json","$patch":[{"op":"add","path":"/inner/y/-","value":9}]}}'), load)
      assert(v.keep == "me" and v.doc.z == 0 and v.doc.inner.x == 2 and v.doc.inner.y[2] == 9, "expansion wrong")
      assert(files["bases/inner.json"].x == 1 and #files["bases/inner.json"].y == 1, "a base file was mutated")
      local again = patch.expand(json.decode('{"$base":"bases/inner.json","$patch":[]}'), load)
      assert(again.x == 1 and again.y[2] == nil, "an earlier patch leaked into a later expansion")
      raises(function() patch.expand(json.decode('{"$base":"bases/inner.json","$patch":[],"extra":1}'), load) end,
        "stray keys beside $base/$patch")
    end },
  { name = "unknown operations and missing intermediate paths raise", fn = function()
      raises(function() patch.apply(doc(), { { op = "move", from = "/a", path = "/b" } }) end, "unsupported op")
      raises(function() patch.apply(doc(), { { op = "add", path = "/x/y/z", value = 1 } }) end, "missing parent")
      raises(function() patch.apply(doc(), { { op = "add", path = "/a/c/01", value = 1 } }) end, "noncanonical index")
    end },
}
