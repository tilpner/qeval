{ pkgs ? import ./nixpkgs.nix }:

with pkgs;
with lib;

rec {
  qemu = pkgs.qemu.override {
    sdlSupport = false;
    vncSupport = false;
    spiceSupport = false;
    pulseSupport = false;
    smbdSupport = true;
    hostCpuOnly = true;
  };

  baseKernelPackages = linuxPackages;

  kconfig = kernelConfig.override {
    linux = baseKernelPackages.kernel;
  } {
    config = {
      X86 = true;
      "64BIT" = true;
      #"PRINTK" "BUG" # extra debugging

      LOCAL_VERSION = "qeval";
      DEFAULT_HOSTNAME = "qeval";

      SWAP = false;

      TTY = true;
      SERIAL_8250 = true;
      SERIAL_8250_CONSOLE = true;

      # execute elf and #! scripts
      BINFMT_ELF = true;
      BINFMT_SCRIPT = true;

      # enable ramdisk with gzip
      BLK_DEV_INITRD = true;
      RD_GZIP = true;

      # allow for userspace to shut kernel down
      PROC_FS = true;
      MAGIC_SYSRQ = true;
      
      # needed for guest to tell qemu to shutdown
      PCI = true;
      ACPI = true;

      # allow unix domain sockets
      NET = true;
      UNIX = true;

      # enable block layer
      BLOCK = true;
      BLK_DEV = true;
      BLK_DEV_LOOP = true;

      # required by Nix, which wants to acquire the big lock
      FILE_LOCKING = true;

      MISC_FILESYSTEMS = true;
      SQUASHFS = true;
      SQUASHFS_LZ4 = true;
      LZ4_DECOMPRESS = true;
      SQUASHFS_DECOMP_SINGLE = true;
      # SQUASHFS_DECOMP_MULTI = true;
      # SQUASHFS_FILE_DIRECT = true;
      SQUASHFS_FILE_CACHE = true;

      PROC_SYSCTL = true;
      KERNFS = true;
      SYSFS = true;
      DEVTMPFS = true;
      TMPFS = true;

      OVERLAY_FS = true;

      # support passing in various things
      VIRTIO_PCI = true;
      VIRTIO_BLK = true;
      VIRTIO_INPUT = true;
      VIRTIO_CONSOLE = true;

      FUTEX = true;

      # stop on kernel panic
      PVPANIC = true;
      X86_PLATFORM_DEVICES = true;

      # enable timers (ghc needs them)
      POSIX_TIMERS = true;
      TIMERFD = true;
      EVENTFD = true;
      EPOLL = true;

      # tsc scaling, maybe
      # "X86_TSC"

      ADVISE_SYSCALLS = true;

      # "FSCACHE"
      # "CACHEFILES"

      # TODO: disable IR_SANYO_DECODER, etc.
      RC_CORE = false;

      # required for guest to gather entropy, some applications
      # will otherwise block forever (e.g. rustc)
      HW_RANDOM = true;
      HW_RANDOM_VIRTIO = true;
    };
  };

  kernelPackages = linuxPackages_custom {
    inherit (baseKernelPackages.kernel) version src;
    configfile = kconfig;
  };
  inherit (kernelPackages) kernel;

  initrdUtils = runCommand "initrd-utils"
    { buildInputs = [ nukeReferences ];
      allowedReferences = [ "out" ]; # prevent accidents like glibc being included in the initrd
    }
    ''
      mkdir -p $out/bin $out/lib

      # Copy what we need from Glibc.
      cp -p ${stdenv.glibc.out}/lib/ld-linux*.so.? $out/lib
      cp -p ${stdenv.glibc.out}/lib/libc.so.* $out/lib
      cp -p ${stdenv.glibc.out}/lib/libm.so.* $out/lib
      cp -p ${stdenv.glibc.out}/lib/libresolv.so.* $out/lib

      # Copy BusyBox.
      cp -pd ${busybox}/bin/* $out/bin

      # Run patchelf to make the programs refer to the copied libraries.
      for i in $out/bin/* $out/lib/*; do if ! test -L $i; then nuke-refs $i; fi; done

      for i in $out/bin/*; do
          if [ -f "$i" -a ! -L "$i" ]; then
              echo "patching $i..."
              patchelf --set-interpreter $out/lib/ld-linux*.so.? --set-rpath $out/lib $i || true
          fi
      done
    '';

  closurePaths = path:
    let closure = closureInfo { rootPaths = path; };
        text = lib.fileContents "${closure}/store-paths";
    in lib.splitString "\n" text;

  stage1 = writeScript "vm-run-stage1" ''
    #! ${initrdUtils}/bin/ash -e
    export PATH=${initrdUtils}/bin

    mkdir /etc
    echo -n > /etc/fstab

    mount -t proc none /proc
    mount -t sysfs none /sys

    # Does this even work with the current config?
    echo 2 > /proc/sys/vm/panic_on_oom

    for o in $(cat /proc/cmdline); do
      case $o in
        jobDesc=*)
          set -- $(IFS==; echo $o)
          jobDesc=$2
          ;;
        mountVirtfs=*)
          set -- $(IFS==; echo $o)
          mountVirtfs=$2
          ;;
      esac
    done

    mount -t devtmpfs devtmpfs /dev

    # ifconfig lo up
    stty -icrnl -igncr # necessary?

    mkdir -p /dev/shm /dev/pts
    mount -t tmpfs -o "mode=1777" none /dev/shm
    mount -t devpts none /dev/pts

    mkdir -p /tmp /run /var
    mount -t tmpfs -o "mode=1777" none /tmp
    mount -t tmpfs -o "mode=755" none /run
    ln -sfn /run /var/run

    mkdir -p /etc
    ln -sf /proc/mounts /etc/mtab
    echo "127.0.0.1 localhost" > /etc/hosts
    echo "root:x:0:0:root:/:/bin/sh" > /etc/passwd

    mkdir -p /bin
    ln -s ${initrdUtils}/bin/ash /bin/sh

    for store in /dev/vd*; do
      if [ -e "$store" ]; then
        name=$(basename $store)
        mkdir -p /mnt/store/$name
        mount -o ro,loop /dev/$name /mnt/store/$name
      fi
    done

    stores="$( ( find /mnt/store -mindepth 1 -maxdepth 1; echo /nix/store ) | paste -sd :)"
    echo stores: $stores
    mount -t overlay overlay -o "ro,lowerdir=$stores" /nix/store 

    if [ -n "$jobDesc" ]; then
      . "$jobDesc"
    fi

    "$preCmd"

    echo ready > /dev/vport2p1
    read -r input < /dev/vport2p1
    echo "$input" > /input

    "$cmd" /input

    exec poweroff -f
  '';

  initrd = initrdPath: makeInitrd {
    contents = [
      { object = stage1;
        symlink = "/init"; }
      { object = linkFarm "extra"
          (map (p: { name = p.name; path = toString p; }) initrdPath);
        symlink = "/tmp/extra"; }
    ];
  };

  squashfsTools = pkgs.squashfsTools.override { lz4Support = true; };
  mkSquashFs = settings: contents: bitflip.flipTwice (stdenv.mkDerivation {
    name = "squashfs.img";
    nativeBuildInputs = [ squashfsTools ];
    buildCommand = ''
      closureInfo=${closureInfo { rootPaths = contents; }}
      mksquashfs $(cat $closureInfo/store-paths) $out \
        -keep-as-directory -all-root -b 1048576 ${settings} 
    '';
  });

  mkSquashFsXz = mkSquashFs "-comp xz -Xdict-size 100%";
  mkSquashFsLz4 = mkSquashFs "-comp lz4 -Xhc";
  mkSquashFsGz = mkSquashFs "-comp gzip -Xcompression-level 9";

  prepareJob = args@{
      name, aliases ? [], initrdPath ? [ initrdUtils ], storeDrives ? {}, mem ? 50, command, preCommand ? "",
      doCheck ? true, testInput ? "", testOutput ? "success" }:
    let
      fullPath = (concatLists (builtins.attrValues storeDrives)) ++ initrdPath;
      mkScript = cmd: writeScript "run" ''
        #!/bin/sh -e
        PATH=${lib.makeBinPath (map builtins.unsafeDiscardStringContext fullPath)}
        ${cmd}
      '';

      desc = writeText "desc" ''
        cmd=${mkScript command}
        preCmd=${mkScript preCommand}
      '';
      run' = run {
        inherit name initrdPath fullPath mem desc;
        storeDrives = (mapAttrs (k: mkSquashFsLz4) storeDrives) // {
          desc = mkSquashFsLz4 [ desc initrdUtils ];
        };
      };

      description = writeText "desc" (builtins.toJSON {
        inherit name aliases mem;
        available = map (p: p.name) fullPath;
      });

      self = stdenv.mkDerivation rec {
        inherit name aliases;

        src = writeShellScriptBin "run" ''
          set -e
          PATH=${coreutils}/bin
          job=$(mktemp -d)
          ${run'}/bin/run-qemu "$job" "$@"
          rm -rf "$job"
        '';

        installPhase = ''
          mkdir -p $out/bin $out/desc
          for n in $name $aliases; do
            ln -s $src/bin/run "$out/bin/$n"
          done

          ln -s ${description} "$out/desc/$name"
        '';

        inherit doCheck;
        checkPhase = ''
          EXPECTED="$(printf ${escapeShellArg testOutput})"
          ${xxd}/bin/xxd <<<"$EXPECTED"
          RESULT="$($src/bin/run ${escapeShellArg testInput})"
          ${xxd}/bin/xxd <<<"$RESULT"
          [ "$RESULT" = "$EXPECTED" ]
        '';
      };
    in self // {
      inherit desc;
      run = run';

      # Nix itself can't do it, because it can't check if something
      # is a file or a directory (exportReferencesGraph doesn't tell),
      # but apparmor rules differ based on that distinction
      apparmor = stdenv.mkDerivation rec {
        name = "apparmor.profile";

        closureItems = [
          self self.src run'
          bashInteractive glibcLocales
        ];

        buildCommand = ''
          (
            echo '${self.src}/bin/run {'
            echo '  signal, ptrace,'
            echo '  /dev/{kvm,null,random,urandom,tty}' wr,
            echo '  /tmp/**' wr,
            echo '  /proc/** r,'
            echo '  /sys/devices/system/** r,'

            closure=${closureInfo { rootPaths = closureItems; }}
            while read -r path; do
              if [ -f "$path" ]; then
                echo "  $path mkrix,"
              elif [ -d "$path" ]; then
                echo "  $path** mkrix,"
              fi
            done < $closure/store-paths
            echo }
          ) > $out
        '';
      };
    };

  # -drive if=virtio,readonly,format=qcow2,file="$disk" \

  # -enable-kvm -cpu Haswell-noTSX-IBRS,vmx=on \
  # -cpu IvyBridge \
  # -net none -m "$mem" \
  # -virtfs local,readonly,path=/nix/store,security_model=none,mount_tag=store \
  commonQemuOptions = ''
    -only-migratable \
    -nographic -no-reboot \
    -cpu IvyBridge \
    -enable-kvm \
    -net none -m "$mem" \
    -device virtio-rng-pci,max-bytes=1024,period=1000 \
    -device virtio-serial-pci \
    -device virtio-serial \
    -device pvpanic \
    -chardev pipe,path="$job"/control,id=control \
    -device virtserialport,chardev=control,id=control \
    -qmp-pretty unix:"$job"/qmp,nowait \'';

  qemuDriveOptions = lib.concatMapStringsSep " " (d: "-drive if=virtio,readonly,format=raw,file=${d}");

  suspensionUseCompression = true;
  suspensionWriteCommand =
    if suspensionUseCompression
    then "${lz4}/bin/lz4 -9 --favor-decSpeed -"
    else "cat >";

  suspensionReadCommand =
    if suspensionUseCompression
    then "${lz4}/bin/lz4 -d --favor-decSpeed"
    else "cat ";

  run = args@{ name, fullPath, initrdPath, storeDrives, mem, desc, ... }: writeShellScriptBin "run-qemu" ''
    # ${name}
    # needs ''${concatStringsSep ", " fullPath}
    job="$1"
    shift
    mkfifo "$job"/control
    mem="${toString mem}"

    ( echo '{ "execute": "qmp_capabilities" }'
    ) | ${netcat}/bin/nc -lU "$job"/qmp >/dev/null &

    ( echo "$@" 
      echo ". /input"
    ) > "$job"/control &

    timeout --foreground 10 \
      ${qemu}/bin/qemu-system-x86_64 \
      ${commonQemuOptions}
      ${qemuDriveOptions (builtins.attrValues storeDrives)} \
        -incoming 'exec:${suspensionReadCommand} ${suspension args}' | ${dos2unix}/bin/dos2unix -f | head -c 1M

    # ^ qemu incorrectly does crlf conversion, check in the future if still necessary
  '' // args;

  # if this doesn't build, and just silently sits there, try increasing memory
  suspension = { name, initrdPath, fullPath, storeDrives, mem, desc }: bitflip.flipTwice (stdenv.mkDerivation {
    name = "${name}-suspension";
    requiredSystemFeatures = [ "kvm" ];
    nativeBuildInputs = [ qemu netcat lz4 ];

    inherit fullPath mem desc;

    buildCommand = ''
      mkdir job
      job=$PWD/job
      mkfifo job/control

      ( read ready < job/control
        echo '{ "execute": "qmp_capabilities" }'
        echo '{ "execute": "migrate", "arguments": { "uri": "exec:${suspensionWriteCommand} '$out'" } }'
        sleep 15 # FIXME
        echo '{ "execute": "quit" }'
      ) | ${netcat}/bin/nc -lU job/qmp &

      qemu-system-x86_64 \
      ${commonQemuOptions}
      ${qemuDriveOptions (builtins.attrValues storeDrives)} \
        -kernel ${kernel}/bzImage \
        -initrd ${initrd initrdPath}/initrd \
        -append "console=ttyS0,38400 tsc=unstable jobDesc=${desc}"
    '';
  });

  evaluators = callPackage ./evaluators.nix { inherit prepareJob; };
}
