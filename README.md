### Example usage

```sh
$ cd $(nix-build --no-out-link . -A evaluators.all)
$ bin/sh id
uid=0(root) gid=0 groups=0
```
