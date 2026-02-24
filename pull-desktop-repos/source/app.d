import std.file;
import std.getopt;
import std.path;
import std.process;
import std.stdio;
import std.string;

static const auto gitrepos = ".gitrepos";

static bool debugging = false;
static bool verbose = false;

int main(string[] args) {
	getopt(args, "verbose", &verbose, "d|debug", &debugging);

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
		if (debugging) stderr.writeln("gitUrl == \"" ~ gitUrl ~ "\"");

		auto branch = "";
		if (splitLine.length == 3) {
			branch = splitLine[2].idup;
			if (debugging) stderr.writeln("branch == \"" ~ branch ~ "\"");
		}

		if (!directory.exists()) {
			if (debugging) stderr.writeln("directory.dirName == \"" ~ directory.dirName ~ "\"");
			if (directory.dirName() != "." && !directory.dirName().exists()) {
				auto cmd2 = "mkdir -p " ~ directory.dirName();
				if (debugging) stderr.writeln(cmd2);
				auto result = executeShell(cmd2);
				if (debugging) stderr.writeln("result.status == ",result.status);
				if (result.status)
					continue;
				result.output.write();
			}

			auto cmd3 = "git clone " ~ gitUrl ~ " " ~ directory ~ " >/dev/null";
			if (!branch.empty)
				cmd3 = "git clone -b " ~ branch ~ " " ~ gitUrl ~ " " ~ directory ~ " >/dev/null";
			if (debugging) stderr.writeln(cmd3);
			auto result = executeShell(cmd3);
			if (debugging) stderr.writeln("result.status == ",result.status);
			if (result.status)
				continue;
			result.output.writeln();
		} else {
			if (!directory.isDir()) {
				stderr.writeln("directory == \"" ~ directory ~ "\" exists but is NOT a directory.");
				continue;
			}
			if (debugging) writeln("directory \"" ~ directory ~ "\" exists.");

			auto cmd1 = "git -C " ~ directory ~ " branch";
			if (debugging) writeln("executing: " ~ cmd1);
			auto result = executeShell(cmd1);
			if (debugging) stderr.writeln("result.status == ",result.status);
			if (result.status)
				continue;
			if (debugging) writeln("result.output == \"" ~ result.output ~ "\"");
			auto isDefaultBranch = result.output.split[0] == "*";
			if (debugging) writeln("isDefaultBranch == ",isDefaultBranch);
			auto actualBranch = result.output.split[1];
			if (!branch.empty) {
				if (debugging) stderr.writeln("actualBranch == \"",actualBranch,"\"");
				if (branch != actualBranch) {
					stderr.writeln("You specified you want to pull branch \"" ~ branch ~ "\", but a different branch (\"" ~ actualBranch ~ "\") is already checked out. Not pulling.");
					continue;
				}
			}

			// auto cmd1 = "git -C " ~ directory ~ " git pull; popd >/dev/null";

			// auto cmd1 = "pushd " ~ directory ~ " >/dev/null; git pull; popd >/dev/null";
			// if (!branch.empty)
			// 	cmd1 = "pushd " ~ directory ~ " >/dev/null; git pull origin " ~ branch ~"; popd >/dev/null";
			// if (debugging) writeln("executing: " ~ cmd1);
			// result = executeShell(cmd1);
			// result.output.write();
			// if (debugging) writeln("result.status == ", result.status);
			break;
			continue;
		}
		break;
	}

    file.close();
    return 2;
}
