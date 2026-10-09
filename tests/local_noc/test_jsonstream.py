"""noc.JsonStream: OVSDB JSON-RPC arrives as concatenated JSON texts, split anywhere."""

import json
import unittest

from support import noc


class JsonStreamTest(unittest.TestCase):
    def test_one_message(self):
        self.assertEqual(noc.JsonStream().feed('{"id": 1, "result": []}'),
                         [{"id": 1, "result": []}])

    def test_concatenated_messages(self):
        out = noc.JsonStream().feed('{"a":1}{"b":2}\n {"c":3}')
        self.assertEqual(out, [{"a": 1}, {"b": 2}, {"c": 3}])

    def test_split_anywhere(self):
        text = '{"id":7,"method":"update","params":["m",{"T":{"u":{"new":{"x":"é}"}}}}]}'
        for cut in range(1, len(text)):
            s = noc.JsonStream()
            first = s.feed(text[:cut])
            second = s.feed(text[cut:])
            self.assertEqual(first + second, [json.loads(text)], cut)

    def test_incomplete_waits(self):
        s = noc.JsonStream()
        self.assertEqual(s.feed('{"id": 1, "res'), [])
        self.assertEqual(s.feed('ult": null}'), [{"id": 1, "result": None}])
        self.assertEqual(s.buf, "")

    def test_whitespace_only(self):
        s = noc.JsonStream()
        self.assertEqual(s.feed("  \n\t "), [])
        self.assertEqual(s.buf, "")


if __name__ == "__main__":
    unittest.main()
