import std.file;
import std.path;
import std.process;
import std.stdio;
import std.string;

static const auto gitrepos = ".gitrepos";

static bool debugging = false;

int main()
{

	try {
		// git pull the current directory


        // Iterate through all directory entries recursively
        foreach (DirEntry entry; dirEntries("./", SpanMode.shallow, false)) {
            // Check if the entry is a regular file whose baseName matches gitrepos contents
			if (entry.isFile && baseName(entry.name) == gitrepos) {
				writeln("Found ", entry.name);
			}
        }
    } catch (FileException e) {
        writeln("Error: ", e.msg);
    }


	return 0;
}

int pull() {
	if (!gitrepos.exists()) {
		stderr.writeln(gitrepos ~ " does not exist in the current working directory. Is your current working directory set to a desktop directory?");
		return 1;
	}

	File file = File(gitrepos, "r");

    foreach (line; file.byLine()) {
		auto splitLine = line.split();
		auto directory = splitLine[0];
		if (debugging) stderr.writeln("directory == \"" ~ directory ~ "\"");
		auto gitUrl = splitLine[1];
		if (directory.exists() && directory.isDir()) {
			auto cmd1 = "pushd " ~ directory ~ " >/dev/null; git pull; popd >/dev/null";
			cmd1.writeln();
			auto result = executeShell(cmd1);
			result.output.write();
			continue;
		}

		if (!directory.exists()) {
			if (!directory.dirName().exists()) {
				auto cmd2 = "mkdir -p " ~ directory.dirName();
				cmd2.writeln();
				auto result = executeShell(cmd2);
				result.output.write();
			}

			auto cmd3 = "pushd " ~ directory.dirName() ~ " > /dev/null; git clone " ~ gitUrl ~ "; popd > /dev/null";
			writeln(cmd3);
			auto result = executeShell(cmd3);
			result.output.writeln();
		}
	}

    file.close();
    return 2;
}
