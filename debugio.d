module debugio;

import std.stdio;
import core.stdc.stdio : _IONBF;

debug shared static this()
{
    stdout.setvbuf(0, _IONBF);
}


