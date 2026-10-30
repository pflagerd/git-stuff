# GDB pretty-printers for D dynamic arrays, so a debugger shows `string[] args`
# as its elements ("alpha", "beta") instead of the raw struct fields `length`
# and `ptr`, and shows each string as exactly `length` characters (D strings
# have no terminating NUL, so printed the C way they run into each other).
#
# A D array is laid out as struct { size_t length; T* ptr; }
# (https://dlang.org/spec/abi.html#arrays); any struct with exactly those two
# fields is treated as one. Arrays of char are shown as strings; all others as
# their elements [0], [1], ...
#
# Load it from ~/.gdbinit, which gdb runs at startup (and so when Kate's
# debugger starts gdb):
#
#     source /path/to/git-stuff/gdb/d_arrays.py
#
# Front ends using gdb's machine interface (MI) see it only after sending
# -enable-pretty-printing; plain `print` uses it as soon as it's loaded.
#
# This is the one Python file meant to stay in this repository: gdb can only
# be extended in Python (this Ubuntu gdb has no Guile). See CLAUDE.md.
#
# API: https://sourceware.org/gdb/current/onlinedocs/gdb.html/Pretty-Printing-API.html

import gdb


def _is_d_array(t):
    t = t.strip_typedefs()
    if t.code != gdb.TYPE_CODE_STRUCT:
        return False
    names = [f.name for f in t.fields()]
    return names == ["length", "ptr"]

def _element_type(t):
    return t.strip_typedefs().fields()[1].type.target()

def _is_char(t):
    return t.strip_typedefs().unqualified().name in ("char", "immutable(char)", "const(char)")

class DStringPrinter:
    """A D string: exactly `length` characters, not up to a NUL."""
    def __init__(self, value):
        self.value = value
    def to_string(self):
        return self.value["ptr"].lazy_string(length=int(self.value["length"]))
    def display_hint(self):
        return "string"

class DArrayPrinter:
    """Any other D array: its elements as children [0], [1], ..."""
    def __init__(self, value):
        self.value = value
    def to_string(self):
        return "length %d" % int(self.value["length"])
    def children(self):
        ptr = self.value["ptr"]
        for i in range(int(self.value["length"])):
            yield "[%d]" % i, (ptr + i).dereference()
    def display_hint(self):
        return "array"

def lookup(value):
    if not _is_d_array(value.type):
        return None
    if _is_char(_element_type(value.type)):
        return DStringPrinter(value)
    return DArrayPrinter(value)

gdb.pretty_printers.append(lookup)
