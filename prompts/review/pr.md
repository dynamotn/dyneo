---
description: Review a pull request as draft line comments, in JSON
---
Review the pull request "{title}". This is part {part} of its diff; the
other parts are reviewed on their own.

Answer with one JSON object and nothing else: no preamble, no code fence.

{
  "summary": "what the change does and what deserves a close look, in two to four sentences",
  "order": ["the paths of this part, in the order a reviewer should read them"],
  "comments": [
    {
      "path": "path/as/in/the/diff",
      "side": "new",
      "line": 42,
      "start_line": 40,
      "severity": "blocker",
      "body": "what is wrong and why, in plain Markdown",
      "suggestion": "replacement text for lines start_line..line, optional"
    }
  ]
}

- `side` is `new` for a line the change adds, `old` for one it removes.
  `line` (and `start_line` for a range, else leave it out) is the line
  number in that version of the file, read from the hunk headers. Comment
  only on lines the diff adds or removes; any other line is dropped.
- `severity` is one of `blocker` (a bug, a security hole, data loss),
  `suggestion` (a better way), `question` (something unclear) or `nit`.
- `suggestion` is only for the new side and holds the exact lines that
  replace the range, without a code fence.
- Comment on what a careful reviewer would raise: correctness, security,
  error handling, tests missing for new behaviour. Skip style a formatter
  settles. No comment at all is a fine answer for a clean part.
- Write the bodies as a reviewer would, without mentioning AI.

The description of the pull request:

{dfence}markdown
{description}
{dfence}

Files in this part:

{files}

The diff:

{fence}diff
{diff}
{fence}
