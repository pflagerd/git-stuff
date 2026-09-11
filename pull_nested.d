import std.algorithm;
import std.array;
import std.conv;
import std.file;
import std.path;
import std.process;
import std.range;
import std.stdio;
import std.string;
import std.utf;

static const auto gitrepos = ".gitrepos";

int main(string[] args) {
    if (!gitrepos.exists) {
		stderr.writeln(gitrepos ~ " does not exist in the current working directory. Is your current working directory set to a desktop directory?");
		return 1;
	}

    debug writeln("load .gitrepos file");
    string[] gitRepos = "./.gitrepos".readText().splitLines;
    gitRepos.sort;
    auto retVal = 0;

    foreach (repo; gitRepos) {
		debug writeln("repo == \"" ~ repo ~ "\"");
		auto splitLine = repo.split();
		auto directoryName = splitLine[0];
	    debug writeln("if directory has a leading /, remove it: " ~ directoryName);
		if (directoryName.startsWith("/"))
			directoryName = directoryName[1..$];

		writeln("directoryName == \"" ~ directoryName ~ "\"");
		writeln(typeof(directoryName).stringof);
		auto gitUrl = splitLine[1];
		writeln("gitUrl == \"" ~ gitUrl ~ "\"");
		auto branchName = directoryName;
		if (branchName[$ - branchName.strideBack(branchName.length)] == '/')
			branchName = directoryName[0 .. $ - branchName.strideBack(branchName.length)];
		if (splitLine.length == 3)
			branchName = splitLine[2];

		writefln("exists(%s) = %s, isDir would throw if false", directoryName, std.file.exists(directoryName));
		if (std.file.exists(directoryName)) {
			try {
				if (!directoryName.isDir())
					throw new FileException(directoryName);
			} catch (FileException fe) {
				stderr.writeln(directoryName ~ " is not a directory. Cannot clone or pull repo.");
				retVal = 2;
				continue;
			}

		    try {
				if (!(directoryName ~ "/.git").isDir)
					throw new FileException(directoryName);
			} catch (FileException fe) {
				stderr.writeln(directoryName ~ "/.git/ is not a directory. Cannot clone or pull repo.");
				retVal = 2;
				continue;
			}

			if (splitLine.length == 3) { // if there's a branch specified ...
				auto cmd1 = "git -C " ~ directoryName ~ " checkout " ~ branchName;
				debug cmd1.writeln();
				auto result = executeShell(cmd1);
				debug writeln("result.status = " ~ result.status.to!string ~ ", result.output = " ~ result.output);
			}

			auto cmd1 = "git -C " ~ directoryName ~ " pull";
			cmd1.writeln();
			auto result = executeShell(cmd1);
			result.output.write();
			continue;
		} else {
			auto cmd3 = "git clone " ~ gitUrl ~ " " ~ directoryName;
			writeln(cmd3);
			auto result = executeShell(cmd3);
			result.output.writeln();

			auto cmd4 = "git -C " ~ directoryName ~ " checkout " ~ branchName;
			writeln(cmd4);
			result = executeShell(cmd4);
			result.output.writeln();
		}
	}

    return retVal;
}
