local c = require("lib.canonical")
return {
  { name = "keys sorted, no whitespace", fn = function()
      assert(c.encode({ b = 1, a = "x" }) == '{"a":"x","b":1}')
    end },
  { name = "nested arrays and objects", fn = function()
      assert(c.encode({ l = { 1, { z = true, a = pandoc.json.null } } })
        == '{"l":[1,{"a":null,"z":true}]}')
    end },
  { name = "string escapes per RFC 8785", fn = function()
      assert(c.encode({ s = 'q"\\\n\t\27' }) == '{"s":"q\\"\\\\\\n\\t\\u001b"}')
    end },
  { name = "utf-8 passes through unescaped", fn = function()
      assert(c.encode({ s = "protocole étendu" }) == '{"s":"protocole étendu"}')
    end },
  { name = "non-integer number raises", fn = function()
      assert(not pcall(c.encode, { x = 1.5 }))
    end },
  { name = "decoded-JSON integral float encodes as integer", fn = function()
      assert(c.encode(require("lib.json").decode('{"n":1}')) == '{"n":1}')
    end },
}
