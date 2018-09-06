# qeval

qeval is a toy to safely-ish (beware bugs and hardware limitations) execute malicious/untrusted code.
It's inspired by [shbot](https://github.com/geirha/shbot), but none of the code was taken from there.

There are currently evaluators for

* Perl 5
* Rust nightly
* Go
* C (gcc)
* C (tcc)
* C++ (gcc)
* Java (openjdk)
* Python 3
* Python 2
* Ruby
* Bash
* Ash (from busybox)
* NodeJS
* Lua
* PHP
* Racket
* Guile
* Haskell
* Qalculate (which doesn't really need the sandboxing)

Perl is currently the fastest evaluator, taking 0.16s on my laptop for a simple `print 42`.


### Example usage

```sh
# This may build Linux, QEMU, and Perl. Use evaluators.sh if you're impatient
$ cd $(nix-build --no-out-link . -A evaluators.all)
$ bin/sh id
uid=0(root) gid=0 groups=0
```

### Todo

* Disk hotplug to reduce amount of disk suspensions (and be able to mlock the remaining one)
* More sophisticated control processes
  * Quicker abort when output has reached size limit
  * Report exit status, memory usage (and OOM), other statistics (count syscalls?)
  * Multi-line input
