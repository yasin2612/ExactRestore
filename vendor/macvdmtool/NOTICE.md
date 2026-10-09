# macvdmtool

`main.cpp` in this folder is a modified copy of [macvdmtool](https://github.com/AsahiLinux/macvdmtool) by the Asahi Linux project, licensed under the Apache License 2.0. The other source files are downloaded unmodified at build time.

Changes for Exact Restore: every host USB C port can be used, plus the `list`, `dfu <rid>`, `dfu all` and `restart <rid>` commands, and failures printed as `ERROR: ...`.
