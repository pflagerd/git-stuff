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

int main() {
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


			auto cmd1 = "pushd " ~ directoryName ~ " >/dev/null; git pull; popd >/dev/null";
			cmd1.writeln();
			auto result = executeShell(cmd1);
			result.output.write();
			continue;
		} else {
			if (!directoryName.dirName().exists()) {
				auto cmd2 = "mkdir -p " ~ directoryName.dirName();
				cmd2.writeln();
				auto result = executeShell(cmd2);
				result.output.write();
			}

			auto cmd3 = "pushd " ~ directoryName.dirName() ~ " > /dev/null; git clone " ~ gitUrl ~ "; popd > /dev/null";
			writeln(cmd3);
			auto result = executeShell(cmd3);
			result.output.writeln();
		}
	}

    return 2;
}
