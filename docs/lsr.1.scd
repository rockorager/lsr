lsr(1)

# NAME

lsr - list directory contents, but with io_uring

# SYNOPSIS

*lsr* [options...] [directory]

# DESCRIPTION

lsr is an implementation of ls(1) which utilizes io_uring to perform syscall
batching.

# OPTIONS

*-1*, *--oneline*
	Print entries one per line

*-a*, *--all*
	Show files that start with a dot (ASCII 0x2E)

*-A*, *--almost-all*
	Like --all, but skips implicit "." and ".." directories

*-C*, *--columns*
	Print the output in columns

*--color=WHEN*
	When to use colors (always, auto, never)

*--group-directories-first*
	Print all directories before printing regular files

*--help*
	Print the help menu and exit

*--hyperlinks=WHEN*
	When to use OSC 8 hyperlinks (always, auto, never)

*--icons=WHEN*
	When to display icons (always, auto, never)

*-l*, *--long*
	Display extended file metadata

*--version*
	Print the version and exit

# AUTHORS

Written and maintained by Tim Culverhouse <tim@timculverhouse.com>, assisted by
open source contributors.
