import std.algorithm;
import std.array;
import std.conv;
import std.file;
import std.path;
import std.process;
import std.range;
import std.stdio;
import std.string;

static const auto gitrepos = ".gitrepos";

int main(string[] args) {
    if (!gitrepos.exists) {
		stderr.writeln(gitrepos ~ " does not exist in the current working directory. Is your current working directory set to a desktop directory?");
		return 1;
	}

    debug writeln("load .gitrepos file");
    string[] gitRepos = "./.gitrepos".readText().splitLines;
    gitRepos.sort;

    foreach (repo; gitRepos) {
		debug writeln("repo == \"" ~ repo ~ "\"");
		auto splitLine = repo.split();
		auto directoryName = splitLine[0];
	    debug writeln("if directory has a leading /, remove it: " ~ directoryName);
		if (directoryName.startsWith("/"))
			directoryName = directoryName[1..$];

		writeln("directoryName == \"" ~ directoryName ~ "\"");
		auto gitUrl = splitLine[1];
		writeln("gitUrl == \"" ~ gitUrl ~ "\"");


		if (directoryName.exists()) {
			try {
				if (!directoryName.isDir)
					throw new FileException(directoryName);
			} catch (FileException fe) {
				stderr.writeln(directoryName ~ " is not a directory. Cannot clone or pull repo.");
				continue;
			}

		    try {
				if (!(directoryName ~ "/.git").isDir)
					throw new FileException(directoryName);
			} catch (FileException fe) {
				stderr.writeln(directoryName ~ "/.git/ is not a directory. Cannot clone or pull repo.");
				return 1;
			}

			if (splitLine.length == 3) { // if there's a branch specified ...
				auto cmd1 = "git -C " ~ directoryName ~ " checkout " ~ splitLine[2];
				debug cmd1.writeln();
				auto result = executeShell(cmd1);
				debug writeln("result.status = " ~ result.status.to!string ~ ", result.output = " ~ result.output);
			}

			auto cmd1 = "git -C " ~ directoryName ~ " pull";
			debug cmd1.writeln();
			auto result = executeShell(cmd1);
				debug writeln("result.status = " ~ result.status.to!string ~ ", result.output = " ~ result.output);
			continue;
		} else {
			if (!directoryName.dirName().exists()) { // if directoryName's parent directory doesn't exist...
				auto cmd2 = "mkdir -p " ~ directoryName.dirName();
				debug cmd2.writeln();
				auto result = executeShell(cmd2); // ... create it.
				debug writeln("result.status = " ~ result.status.to!string ~ ", result.output = " ~ result.output);
			}

			auto cmd3 = "git clone " ~ gitUrl ~ " " ~ splitLine[0];

			debug writeln(cmd3);
			auto result = executeShell(cmd3);
			debug result.output.writeln();

			if (splitLine.length == 3) { // If there is a branch specified in .gitignore, ...
				auto cmd = "git -C " ~ directoryName ~ " checkout " ~ splitLine[2];
				debug writeln(cmd);
				result = executeShell(cmd);
				debug writeln("result.status = " ~ result.status.to!string ~ ", result.output = " ~ result.output);
			}
		}
	}

    return 2;
}
