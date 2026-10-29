/**
 * Finding: one problem reported by a check() method.
 *
 * Checks return findings instead of printing them, so each command decides
 * what to print, its exit status, and whether --fix applies.
 *
 * Design: docs/nested-repos-design.md
 */
module finding;

struct Finding
{
    string directory; /// the nested repo it concerns; "" for a whole-file problem
    string message;   /// human-readable description, naming the file
    bool fixable;     /// whether --fix can repair it
}
