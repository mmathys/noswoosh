// The single source of truth for the version string. Kept in a file of its own
// because the release workflow and the bundle script both read it with a grep,
// and a one-line file is one that cannot drift or be matched by accident.

let noswooshVersion = "1.7.6"
