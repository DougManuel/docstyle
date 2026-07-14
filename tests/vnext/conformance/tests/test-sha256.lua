local sha = require("lib.sha256")
return {
  { name = "empty string", fn = function()
      assert(sha.hex("") ==
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    end },
  { name = "abc", fn = function()
      assert(sha.hex("abc") ==
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    end },
  { name = "448-bit vector", fn = function()
      assert(sha.hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq") ==
        "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    end },
  { name = "million a (padding across blocks)", fn = function()
      assert(sha.hex(string.rep("a", 1000000)) ==
        "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    end },
}
