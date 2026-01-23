import std.stdio;

int main(string[] args)
{
    writeln("Hello, World!");
    for (int i = 0; i < args.length; i++) {
        if (i > 0) {
            write(" ");
        }
        write(args[i]);
    }
    writeln();

    return 0;
}