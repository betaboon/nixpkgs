{ system ? builtins.currentSystem,
  config ? {},
  pkgs ? import ../.. { inherit system config; }
}:
with import ../lib/testing-python.nix { inherit system pkgs; };
with pkgs.lib;

let

  # The configuration to install.
  makeConfig = { bootLoader, extraConfig
                # TODO we should take these from extraInstallerOptions or so
               , installerUseBootLoader, installerUseEFIBoot
               # grub-specific
               , grubVersion, grubDevice, grubIdentifier, grubUseEfi, forceGrubReinstallCount ? 0
               }:
    pkgs.writeText "configuration.nix" ''
      { config, lib, pkgs, modulesPath, ... }:

      { imports =
          [ ./hardware-configuration.nix
            <nixpkgs/nixos/modules/testing/test-instrumentation.nix>
          ];

        # To ensure that we can rebuild the grub configuration on the nixos-rebuild
        system.extraDependencies = with pkgs; [ stdenvNoCC ];

        ${optionalString (bootLoader == "grub") ''
          boot.loader.grub.version = ${toString grubVersion};
          ${optionalString (grubVersion == 1) ''
            boot.loader.grub.splashImage = null;
          ''}

          boot.loader.grub.extraConfig = "serial; terminal_output.serial";
          ${if grubUseEfi then ''
            boot.loader.grub.device = "nodev";
            boot.loader.grub.efiSupport = true;
            boot.loader.grub.efiInstallAsRemovable = true; # XXX: needed for OVMF?
          '' else ''
            boot.loader.grub.device = "${grubDevice}";
            boot.loader.grub.fsIdentifier = "${grubIdentifier}";
          ''}

          boot.loader.grub.configurationLimit = 100 + ${toString forceGrubReinstallCount};
        ''}

        ${optionalString (bootLoader == "systemd-boot") ''
          boot.loader.systemd-boot.enable = true;
        ''}

        ${optionalString (bootLoader == "refind") ''
          boot.loader.refind.enable = true;
        ''}
        ${optionalString (bootLoader == "refind" && !(installerUseBootLoader && installerUseEFIBoot)) ''
          boot.loader.refind.installAsRemovable = true;
        ''}

        users.users.alice = {
          isNormalUser = true;
          home = "/home/alice";
          description = "Alice Foobar";
        };

        hardware.enableAllFirmware = lib.mkForce false;

        ${replaceChars ["\n"] ["\n  "] extraConfig}
      }
    '';


  # The test script boots a NixOS VM, installs NixOS on an empty hard
  # disk, and then reboot from the hard disk.  It's parameterized with
  # a test script fragment `createPartitions', which must create
  # partitions and filesystems.
  testScriptFun = { bootLoader, extraConfig
                  , createPartitions, preBootCommands
                  # installer-specific
                  , installerUseBootLoader, installerUseEFIBoot
                  # test-specific
                  , testCloneConfig
                  # grub-specific
                  , grubVersion, grubDevice, grubUseEfi, grubIdentifier
                  }:
    let

      isEfi = bootLoader == "systemd-boot"
        || bootLoader == "refind"
        || (bootLoader == "grub" && grubUseEfi);

      makeMachineConfig = name: pkgs.writeText "machine-config.json" (builtins.toJSON ({
        inherit name;
        # FIXME don't duplicate the -enable-kvm etc. flags here yet again!
        qemuFlags =
          (if system == "x86_64-linux" then "-m 768 " else "-m 512 ") +
          (optionalString (system == "x86_64-linux") "-cpu kvm64 ") +
          (optionalString (system == "aarch64-linux") "-enable-kvm -machine virt,gic-version=host -cpu host ");

        hda = "vm-state-machine/machine.qcow2";
        hdaInterface = if grubVersion == 1 then "ide" else "virtio";
      } // (optionalAttrs (isEfi && !(installerUseBootLoader && installerUseEFIBoot)) {
        # TODO cant we get rid of this case ?
        bios = "${pkgs.OVMF.fd}/FV/OVMF.fd";
      }) //(optionalAttrs (isEfi && installerUseBootLoader && installerUseEFIBoot) {
        efiFirmware = "efi_firmware.bin";
        efiVars = "efi_vars.bin";
      })));

    in if !isEfi && !(pkgs.stdenv.isi686 || pkgs.stdenv.isx86_64) then
      throw "Non-EFI boot methods are only supported on i686 / x86_64"
    else ''
      def create_machine_from_file(machine_config_file):
          with open(machine_config_file, "r") as f:
              return create_machine(json.load(f))


      machine.start()

      # Make sure that we get a login prompt etc.
      machine.succeed("echo hello")
      # machine.wait_for_unit("getty@tty2")
      # machine.wait_for_unit("rogue")
      machine.wait_for_unit("nixos-manual")

      # Wait for hard disks to appear in /dev
      machine.succeed("udevadm settle")

      # Partition the disk.
      ${createPartitions}

      # Create the NixOS configuration.
      machine.succeed("nixos-generate-config --root /mnt")

      machine.succeed("cat /mnt/etc/nixos/hardware-configuration.nix >&2")

      machine.copy_file_from_host(
          "${ makeConfig { inherit bootLoader grubVersion grubDevice grubIdentifier grubUseEfi extraConfig installerUseBootLoader installerUseEFIBoot; } }",
          "/mnt/etc/nixos/configuration.nix",
      )

      # Perform the installation.
      machine.succeed("nixos-install < /dev/null >&2")

      # Do it again to make sure it's idempotent.
      machine.succeed("nixos-install < /dev/null >&2")

      machine.succeed("umount /mnt/boot || true")
      machine.succeed("umount /mnt")
      machine.succeed("sync")

      machine.shutdown()

      # Now see if we can boot the installation.
      machine = create_machine_from_file(
          "${ makeMachineConfig "boot-after-install" }"
      )

      # For example to enter LUKS passphrase.
      ${preBootCommands}

      # Did /boot get mounted?
      machine.wait_for_unit("local-fs.target")

      ${if bootLoader == "grub" then
          ''machine.succeed("test -e /boot/grub")''
        else if (bootLoader == "refind" && installerUseBootLoader && installerUseEFIBoot) then
          ''machine.succeed("test -e /boot/EFI/refind/refind.conf")''
        else if (bootLoader == "refind") then
          ''machine.succeed("test -e /boot/EFI/BOOT/refind.conf")''
        else
          ''machine.succeed("test -e /boot/loader/loader.conf")''
      }

      # Check whether /root has correct permissions.
      machine.succeed("stat -c '%a' /root | grep 700")

      # Did the swap device get activated?
      # uncomment once https://bugs.freedesktop.org/show_bug.cgi?id=86930 is resolved
      machine.wait_for_unit("swap.target")
      machine.succeed("cat /proc/swaps | grep -q /dev")

      # Check that the store is in good shape
      machine.succeed("nix-store --verify --check-contents >&2")

      # Check whether the channel works.
      machine.succeed("nix-env -iA nixos.procps >&2")
      machine.succeed("type -tP ps | tee /dev/stderr | grep .nix-profile")

      # Check that the daemon works, and that non-root users can run builds (this will build a new profile generation through the daemon)
      machine.succeed("su alice -l -c 'nix-env -iA nixos.procps' >&2")

      # We need a writable Nix store on next boot.
      machine.copy_file_from_host(
          "${ makeConfig { inherit bootLoader grubVersion grubDevice grubIdentifier grubUseEfi extraConfig installerUseBootLoader installerUseEFIBoot; forceGrubReinstallCount = 1; } }",
          "/etc/nixos/configuration.nix",
      )

      # Check whether nixos-rebuild works.
      machine.succeed("nixos-rebuild switch >&2")

      # Test nixos-option.
      machine.succeed("nixos-option boot.initrd.kernelModules | grep virtio_console")
      machine.succeed("nixos-option boot.initrd.kernelModules | grep 'List of modules'")
      machine.succeed("nixos-option boot.initrd.kernelModules | grep qemu-guest.nix")

      machine.shutdown()

      # Check whether a writable store build works
      machine = create_machine_from_file(
          "${ makeMachineConfig "rebuild-switch" }"
      )
      ${preBootCommands}
      machine.wait_for_unit("multi-user.target")
      machine.copy_file_from_host(
          "${ makeConfig { inherit bootLoader grubVersion grubDevice grubIdentifier grubUseEfi extraConfig installerUseBootLoader installerUseEFIBoot; forceGrubReinstallCount = 2; } }",
          "/etc/nixos/configuration.nix",
      )
      machine.succeed("nixos-rebuild boot >&2")
      machine.shutdown()

      # And just to be sure, check that the machine still boots after
      # "nixos-rebuild switch".
      machine = create_machine_from_file(
          "${ makeMachineConfig "boot-after-rebuild-switch" }"
      )
      ${preBootCommands}
      machine.wait_for_unit("network.target")
      machine.shutdown()
      # Tests for validating clone configuration entries in grub menu
    '' + optionalString testCloneConfig ''
      # Reboot Machine
      machine = create_machine_from_file(
          "${ makeMachineConfig "clone-default-config" }"
      )
      ${preBootCommands}
      machine.wait_for_unit("multi-user.target")

      # Booted configuration name should be Home
      # This is not the name that shows in the grub menu.
      # The default configuration is always shown as "Default"
      machine.succeed("cat /run/booted-system/configuration-name >&2")
      machine.succeed("cat /run/booted-system/configuration-name | grep Home")

      # We should find **not** a file named /etc/gitconfig
      machine.fail("test -e /etc/gitconfig")

      # Set grub to boot the second configuration
      machine.succeed("grub-reboot 1")

      machine.shutdown()

      # Reboot Machine
      machine = create_machine_from_file(
          "${ makeMachineConfig "clone-alternate-config" }"
      )
      ${preBootCommands}

      machine.wait_for_unit("multi-user.target")
      # Booted configuration name should be Work
      machine.succeed("cat /run/booted-system/configuration-name >&2")
      machine.succeed("cat /run/booted-system/configuration-name | grep Work")

      # We should find a file named /etc/gitconfig
      machine.succeed("test -e /etc/gitconfig")

      machine.shutdown()
    '';


  makeInstallerTest = name:
    { createPartitions, preBootCommands ? "", extraConfig ? ""
    , installerExtraConfig ? {}
    , installerUseBootLoader ? false, installerUseEFIBoot ? false
    , bootLoader ? "grub" # either "grub" or "systemd-boot" or "refind"
    , grubVersion ? 2, grubDevice ? "/dev/vda", grubIdentifier ? "uuid", grubUseEfi ? false
    , enableOCR ? false, meta ? {}
    , testCloneConfig ? false
    }:
    makeTest {
      inherit enableOCR;
      name = "installer-" + name;
      meta = with pkgs.stdenv.lib.maintainers; {
        # put global maintainers here, individuals go into makeInstallerTest fkt call
        maintainers = (meta.maintainers or []);
      };
      nodes = {

        # The configuration of the machine used to run "nixos-install".
        machine =
          { pkgs, ... }:

          { imports =
              [ ../modules/profiles/installation-device.nix
                ../modules/profiles/base.nix
                installerExtraConfig
              ];

            virtualisation.diskSize = 8 * 1024;
            virtualisation.memorySize = 1024;

            # Use a small /dev/vdb as the root disk for the
            # installer. This ensures the target disk (/dev/vda) is
            # the same during and after installation.
            virtualisation.emptyDiskImages = [ 512 ];
            # TODO this has originally been vdb. what to do here ?
            virtualisation.bootDevice = if installerUseBootLoader
              then (if grubVersion == 1 then "/dev/sdc" else "/dev/vdc")
              else (if grubVersion == 1 then "/dev/sdb" else "/dev/vdb");

            # FIXME why scsi when grubVersion==1, while testScriptFun uses ide in that case ?
            virtualisation.qemu.diskInterface =
              if grubVersion == 1 then "scsi" else "virtio";

            virtualisation.useBootLoader = installerUseBootLoader;
            virtualisation.useEFIBoot = installerUseEFIBoot;

            boot.loader.systemd-boot.enable = mkIf (bootLoader == "systemd-boot") true;
            boot.loader.refind = mkIf (bootLoader == "refind") {
              enable = true;
              # TODO is this even required, as we pass kernel+init to ovmf anyway?
              installAsRemovable = !(installerUseBootLoader && installerUseEFIBoot);
            };

            hardware.enableAllFirmware = mkForce false;

            # The test cannot access the network, so any packages we
            # need must be included in the VM.
            system.extraDependencies = with pkgs;
              [ sudo
                libxml2.bin
                libxslt.bin
                desktop-file-utils
                docbook5
                docbook_xsl_ns
                unionfs-fuse
                ntp
                nixos-artwork.wallpapers.simple-dark-gray-bottom
                perlPackages.XMLLibXML
                perlPackages.ListCompare
                shared-mime-info
                texinfo
                xorg.lndir

                # add curl so that rather than seeing the test attempt to download
                # curl's tarball, we see what it's trying to download
                curl
              ]
              ++ optional (bootLoader == "grub" && grubVersion == 1) pkgs.grub
              ++ optionals (bootLoader == "grub" && grubVersion == 2) [ pkgs.grub2 pkgs.grub2_efi ]
              ++ optional (bootLoader == "refind") pkgs.refind;

            nix.binaryCaches = mkForce [ ];
            nix.extraOptions =
              ''
                hashed-mirrors =
                connect-timeout = 1
              '';
          };

      };

      testScript = testScriptFun {
        inherit bootLoader extraConfig
                createPartitions preBootCommands
                grubVersion grubDevice grubIdentifier grubUseEfi
                installerUseBootLoader installerUseEFIBoot
                testCloneConfig;
      };
    };

    makeLuksRootTest = name: luksFormatOpts: makeInstallerTest name
      { createPartitions = ''
          machine.succeed(
              "flock /dev/vda parted --script /dev/vda -- mklabel msdos"
              " mkpart primary ext2 1M 50MB"  # /boot
              " mkpart primary linux-swap 50M 1024M"
              " mkpart primary 1024M -1s",  # LUKS
              "udevadm settle",
              "mkswap /dev/vda2 -L swap",
              "swapon -L swap",
              "modprobe dm_mod dm_crypt",
              "echo -n supersecret | cryptsetup luksFormat ${luksFormatOpts} -q /dev/vda3 -",
              "echo -n supersecret | cryptsetup luksOpen --key-file - /dev/vda3 cryptroot",
              "mkfs.ext3 -L nixos /dev/mapper/cryptroot",
              "mount LABEL=nixos /mnt",
              "mkfs.ext3 -L boot /dev/vda1",
              "mkdir -p /mnt/boot",
              "mount LABEL=boot /mnt/boot",
          )
        '';
        extraConfig = ''
          boot.kernelParams = lib.mkAfter [ "console=tty0" ];
        '';
        enableOCR = true;
        preBootCommands = ''
          machine.start()
          machine.wait_for_text("Passphrase for")
          machine.send_chars("supersecret\n")
        '';
      };

  # The (almost) simplest partitioning scheme: a swap partition and
  # one big filesystem partition.
  simple-test-config = { createPartitions =
       ''
         machine.succeed(
             "flock /dev/vda parted --script /dev/vda -- mklabel msdos"
             " mkpart primary linux-swap 1M 1024M"
             " mkpart primary ext2 1024M -1s",
             "udevadm settle",
             "mkswap /dev/vda1 -L swap",
             "swapon -L swap",
             "mkfs.ext3 -L nixos /dev/vda2",
             "mount LABEL=nixos /mnt",
         )
       '';
   };

  simple-uefi-grub-config =
    { createPartitions =
        ''
          machine.succeed(
              "flock /dev/vda parted --script /dev/vda -- mklabel gpt"
              " mkpart ESP fat32 1M 50MiB"  # /boot
              " set 1 boot on"
              " mkpart primary linux-swap 50MiB 1024MiB"
              " mkpart primary ext2 1024MiB -1MiB",  # /
              "udevadm settle",
              "mkswap /dev/vda2 -L swap",
              "swapon -L swap",
              "mkfs.ext3 -L nixos /dev/vda3",
              "mount LABEL=nixos /mnt",
              "mkfs.vfat -n BOOT /dev/vda1",
              "mkdir -p /mnt/boot",
              "mount LABEL=BOOT /mnt/boot",
          )
        '';
        bootLoader = "grub";
        grubUseEfi = true;
    };

  clone-test-extraconfig = { extraConfig =
         ''
         environment.systemPackages = [ pkgs.grub2 ];
         boot.loader.grub.configurationName = "Home";
         nesting.clone = [
         {
           boot.loader.grub.configurationName = lib.mkForce "Work";

           environment.etc = {
             "gitconfig".text = "
               [core]
                 gitproxy = none for work.com
                 ";
           };
         }
         ];
         '';
       testCloneConfig = true;
  };


in {

  # !!! `parted mkpart' seems to silently create overlapping partitions.


  # The (almost) simplest partitioning scheme: a swap partition and
  # one big filesystem partition.
  simple = makeInstallerTest "simple" simple-test-config;

  # Test cloned configurations with the simple grub configuration
  simpleClone = makeInstallerTest "simpleClone" (simple-test-config // clone-test-extraconfig);

  # Simple GPT/UEFI configuration using systemd-boot with 3 partitions: ESP, swap & root filesystem
  simpleUefiSystemdBoot = makeInstallerTest "simpleUefiSystemdBoot"
    { createPartitions =
        ''
          machine.succeed(
              "flock /dev/vda parted --script /dev/vda -- mklabel gpt"
              " mkpart ESP fat32 1M 50MiB"  # /boot
              " set 1 boot on"
              " mkpart primary linux-swap 50MiB 1024MiB"
              " mkpart primary ext2 1024MiB -1MiB",  # /
              "udevadm settle",
              "mkswap /dev/vda2 -L swap",
              "swapon -L swap",
              "mkfs.ext3 -L nixos /dev/vda3",
              "mount LABEL=nixos /mnt",
              "mkfs.vfat -n BOOT /dev/vda1",
              "mkdir -p /mnt/boot",
              "mount LABEL=BOOT /mnt/boot",
          )
        '';
        bootLoader = "systemd-boot";
    };

  simpleUefiGrub = makeInstallerTest "simpleUefiGrub" simple-uefi-grub-config;

  # Test cloned configurations with the uefi grub configuration
  simpleUefiGrubClone = makeInstallerTest "simpleUefiGrubClone" (simple-uefi-grub-config // clone-test-extraconfig);

  simpleUefiRefind = makeInstallerTest "simpleUefiRefind"
    { createPartitions =
        ''
          machine.succeed(
              "flock /dev/vda parted --script /dev/vda -- mklabel gpt"
              " mkpart ESP fat32 1M 50MiB"  # /boot
              " set 1 boot on"
              " mkpart primary linux-swap 50MiB 1024MiB"
              " mkpart primary ext2 1024MiB -1MiB",  # /
              "udevadm settle",
              "mkswap /dev/vda2 -L swap",
              "swapon -L swap",
              "mkfs.ext3 -L nixos /dev/vda3",
              "mount LABEL=nixos /mnt",
              "mkfs.vfat -n BOOT /dev/vda1",
              "mkdir -p /mnt/boot",
              "mount LABEL=BOOT /mnt/boot",
          )
        '';
        bootLoader = "refind";
        # installerUseBootLoader = true;
        # installerUseEFIBoot = true;
    };

  # Same as the previous, but now with a separate /boot partition.
  separateBoot = makeInstallerTest "separateBoot"
    { createPartitions =
        ''
          machine.succeed(
              "flock /dev/vda parted --script /dev/vda -- mklabel msdos"
              " mkpart primary ext2 1M 50MB"  # /boot
              " mkpart primary linux-swap 50MB 1024M"
              " mkpart primary ext2 1024M -1s",  # /
              "udevadm settle",
              "mkswap /dev/vda2 -L swap",
              "swapon -L swap",
              "mkfs.ext3 -L nixos /dev/vda3",
              "mount LABEL=nixos /mnt",
              "mkfs.ext3 -L boot /dev/vda1",
              "mkdir -p /mnt/boot",
              "mount LABEL=boot /mnt/boot",
          )
        '';
    };

  # Same as the previous, but with fat32 /boot.
  separateBootFat = makeInstallerTest "separateBootFat"
    { createPartitions =
        ''
          machine.succeed(
              "flock /dev/vda parted --script /dev/vda -- mklabel msdos"
              " mkpart primary ext2 1M 50MB"  # /boot
              " mkpart primary linux-swap 50MB 1024M"
              " mkpart primary ext2 1024M -1s",  # /
              "udevadm settle",
              "mkswap /dev/vda2 -L swap",
              "swapon -L swap",
              "mkfs.ext3 -L nixos /dev/vda3",
              "mount LABEL=nixos /mnt",
              "mkfs.vfat -n BOOT /dev/vda1",
              "mkdir -p /mnt/boot",
              "mount LABEL=BOOT /mnt/boot",
          )
        '';
    };

  # zfs on / with swap
  zfsroot = makeInstallerTest "zfs-root"
    {
      installerExtraConfig = {
        boot.supportedFilesystems = [ "zfs" ];
      };

      extraConfig = ''
        boot.supportedFilesystems = [ "zfs" ];

        # Using by-uuid overrides the default of by-id, and is unique
        # to the qemu disks, as they don't produce by-id paths for
        # some reason.
        boot.zfs.devNodes = "/dev/disk/by-uuid/";
        networking.hostId = "00000000";
      '';

      createPartitions =
        ''
          machine.succeed(
              "flock /dev/vda parted --script /dev/vda -- mklabel msdos"
              " mkpart primary linux-swap 1M 1024M"
              " mkpart primary 1024M -1s",
              "udevadm settle",
              "mkswap /dev/vda1 -L swap",
              "swapon -L swap",
              "zpool create rpool /dev/vda2",
              "zfs create -o mountpoint=legacy rpool/root",
              "mount -t zfs rpool/root /mnt",
              "udevadm settle",
          )
        '';
    };

  # Create two physical LVM partitions combined into one volume group
  # that contains the logical swap and root partitions.
  lvm = makeInstallerTest "lvm"
    { createPartitions =
        ''
          machine.succeed(
              "flock /dev/vda parted --script /dev/vda -- mklabel msdos"
              " mkpart primary 1M 2048M"  # PV1
              " set 1 lvm on"
              " mkpart primary 2048M -1s"  # PV2
              " set 2 lvm on",
              "udevadm settle",
              "pvcreate /dev/vda1 /dev/vda2",
              "vgcreate MyVolGroup /dev/vda1 /dev/vda2",
              "lvcreate --size 1G --name swap MyVolGroup",
              "lvcreate --size 2G --name nixos MyVolGroup",
              "mkswap -f /dev/MyVolGroup/swap -L swap",
              "swapon -L swap",
              "mkfs.xfs -L nixos /dev/MyVolGroup/nixos",
              "mount LABEL=nixos /mnt",
          )
        '';
    };

  # Boot off an encrypted root partition with the default LUKS header format
  luksroot = makeLuksRootTest "luksroot-format1" "";

  # Boot off an encrypted root partition with LUKS1 format
  luksroot-format1 = makeLuksRootTest "luksroot-format1" "--type=LUKS1";

  # Boot off an encrypted root partition with LUKS2 format
  luksroot-format2 = makeLuksRootTest "luksroot-format2" "--type=LUKS2";

  # Test whether opening encrypted filesystem with keyfile
  # Checks for regression of missing cryptsetup, when no luks device without
  # keyfile is configured
  encryptedFSWithKeyfile = makeInstallerTest "encryptedFSWithKeyfile"
    { createPartitions = ''
        machine.succeed(
            "flock /dev/vda parted --script /dev/vda -- mklabel msdos"
            " mkpart primary ext2 1M 50MB"  # /boot
            " mkpart primary linux-swap 50M 1024M"
            " mkpart primary 1024M 1280M"  # LUKS with keyfile
            " mkpart primary 1280M -1s",
            "udevadm settle",
            "mkswap /dev/vda2 -L swap",
            "swapon -L swap",
            "mkfs.ext3 -L nixos /dev/vda4",
            "mount LABEL=nixos /mnt",
            "mkfs.ext3 -L boot /dev/vda1",
            "mkdir -p /mnt/boot",
            "mount LABEL=boot /mnt/boot",
            "modprobe dm_mod dm_crypt",
            "echo -n supersecret > /mnt/keyfile",
            "cryptsetup luksFormat -q /dev/vda3 --key-file /mnt/keyfile",
            "cryptsetup luksOpen --key-file /mnt/keyfile /dev/vda3 crypt",
            "mkfs.ext3 -L test /dev/mapper/crypt",
            "cryptsetup luksClose crypt",
            "mkdir -p /mnt/test",
        )
      '';
      extraConfig = ''
        fileSystems."/test" =
        { device = "/dev/disk/by-label/test";
          fsType = "ext3";
          encrypted.enable = true;
          encrypted.blkDev = "/dev/vda3";
          encrypted.label = "crypt";
          encrypted.keyFile = "/mnt-root/keyfile";
        };
      '';
    };


  swraid = makeInstallerTest "swraid"
    { createPartitions =
        ''
          machine.succeed(
              "flock /dev/vda parted --script /dev/vda --"
              " mklabel msdos"
              " mkpart primary ext2 1M 100MB"  # /boot
              " mkpart extended 100M -1s"
              " mkpart logical 102M 2102M"  # md0 (root), first device
              " mkpart logical 2103M 4103M"  # md0 (root), second device
              " mkpart logical 4104M 4360M"  # md1 (swap), first device
              " mkpart logical 4361M 4617M",  # md1 (swap), second device
              "udevadm settle",
              "ls -l /dev/vda* >&2",
              "cat /proc/partitions >&2",
              "udevadm control --stop-exec-queue",
              "mdadm --create --force /dev/md0 --metadata 1.2 --level=raid1 --raid-devices=2 /dev/vda5 /dev/vda6",
              "mdadm --create --force /dev/md1 --metadata 1.2 --level=raid1 --raid-devices=2 /dev/vda7 /dev/vda8",
              "udevadm control --start-exec-queue",
              "udevadm settle",
              "mkswap -f /dev/md1 -L swap",
              "swapon -L swap",
              "mkfs.ext3 -L nixos /dev/md0",
              "mount LABEL=nixos /mnt",
              "mkfs.ext3 -L boot /dev/vda1",
              "mkdir /mnt/boot",
              "mount LABEL=boot /mnt/boot",
              "udevadm settle",
          )
        '';
      preBootCommands = ''
        machine.start()
        machine.fail("dmesg | grep 'immediate safe mode'")
      '';
    };

  # Test a basic install using GRUB 1.
  grub1 = makeInstallerTest "grub1"
    { createPartitions =
        ''
          machine.succeed(
              "flock /dev/sda parted --script /dev/sda -- mklabel msdos"
              " mkpart primary linux-swap 1M 1024M"
              " mkpart primary ext2 1024M -1s",
              "udevadm settle",
              "mkswap /dev/sda1 -L swap",
              "swapon -L swap",
              "mkfs.ext3 -L nixos /dev/sda2",
              "mount LABEL=nixos /mnt",
              "mkdir -p /mnt/tmp",
          )
        '';
      grubVersion = 1;
      grubDevice = "/dev/sda";
    };

  # Test using labels to identify volumes in grub
  simpleLabels = makeInstallerTest "simpleLabels" {
    createPartitions = ''
      machine.succeed(
          "sgdisk -Z /dev/vda",
          "sgdisk -n 1:0:+1M -n 2:0:+1G -N 3 -t 1:ef02 -t 2:8200 -t 3:8300 -c 3:root /dev/vda",
          "mkswap /dev/vda2 -L swap",
          "swapon -L swap",
          "mkfs.ext4 -L root /dev/vda3",
          "mount LABEL=root /mnt",
      )
    '';
    grubIdentifier = "label";
  };

  # Test using the provided disk name within grub
  # TODO: Fix udev so the symlinks are unneeded in /dev/disks
  simpleProvided = makeInstallerTest "simpleProvided" {
    createPartitions = ''
      uuid = machine.succeed("blkid -s UUID -o value /dev/vda2")
      uuid = uuid.strip()
      machine.succeed(
          "sgdisk -Z /dev/vda",
          "sgdisk -n 1:0:+1M -n 2:0:+100M -n 3:0:+1G -N 4 -t 1:ef02 -t 2:8300 -t 3:8200 -t 4:8300 -c 2:boot -c 4:root /dev/vda",
          "mkswap /dev/vda3 -L swap",
          "swapon -L swap",
          "mkfs.ext4 -L boot /dev/vda2",
          "mkfs.ext4 -L root /dev/vda4",
      )
      machine.execute("ln -s ../../vda2 /dev/disk/by-uuid/{}".format(uuid))
      machine.execute("ln -s ../../vda4 /dev/disk/by-label/root")
      machine.succeed(
          "mount /dev/disk/by-label/root /mnt",
          "mkdir /mnt/boot",
          "mount /dev/disk/by-uuid/{} /mnt/boot".format(uuid),
      )
    '';
    grubIdentifier = "provided";
  };

  # Simple btrfs grub testing
  btrfsSimple = makeInstallerTest "btrfsSimple" {
    createPartitions = ''
      machine.succeed(
          "sgdisk -Z /dev/vda",
          "sgdisk -n 1:0:+1M -n 2:0:+1G -N 3 -t 1:ef02 -t 2:8200 -t 3:8300 -c 3:root /dev/vda",
          "mkswap /dev/vda2 -L swap",
          "swapon -L swap",
          "mkfs.btrfs -L root /dev/vda3",
          "mount LABEL=root /mnt",
      )
    '';
  };

  # Test to see if we can detect /boot and /nix on subvolumes
  btrfsSubvols = makeInstallerTest "btrfsSubvols" {
    createPartitions = ''
      machine.succeed(
          "sgdisk -Z /dev/vda",
          "sgdisk -n 1:0:+1M -n 2:0:+1G -N 3 -t 1:ef02 -t 2:8200 -t 3:8300 -c 3:root /dev/vda",
          "mkswap /dev/vda2 -L swap",
          "swapon -L swap",
          "mkfs.btrfs -L root /dev/vda3",
          "btrfs device scan",
          "mount LABEL=root /mnt",
          "btrfs subvol create /mnt/boot",
          "btrfs subvol create /mnt/nixos",
          "btrfs subvol create /mnt/nixos/default",
          "umount /mnt",
          "mount -o defaults,subvol=nixos/default LABEL=root /mnt",
          "mkdir /mnt/boot",
          "mount -o defaults,subvol=boot LABEL=root /mnt/boot",
      )
    '';
  };

  # Test to see if we can detect default and aux subvolumes correctly
  btrfsSubvolDefault = makeInstallerTest "btrfsSubvolDefault" {
    createPartitions = ''
      machine.succeed(
          "sgdisk -Z /dev/vda",
          "sgdisk -n 1:0:+1M -n 2:0:+1G -N 3 -t 1:ef02 -t 2:8200 -t 3:8300 -c 3:root /dev/vda",
          "mkswap /dev/vda2 -L swap",
          "swapon -L swap",
          "mkfs.btrfs -L root /dev/vda3",
          "btrfs device scan",
          "mount LABEL=root /mnt",
          "btrfs subvol create /mnt/badpath",
          "btrfs subvol create /mnt/badpath/boot",
          "btrfs subvol create /mnt/nixos",
          "btrfs subvol set-default \$(btrfs subvol list /mnt | grep 'nixos' | awk '{print \$2}') /mnt",
          "umount /mnt",
          "mount -o defaults LABEL=root /mnt",
          "mkdir -p /mnt/badpath/boot",  # Help ensure the detection mechanism is actually looking up subvolumes
          "mkdir /mnt/boot",
          "mount -o defaults,subvol=badpath/boot LABEL=root /mnt/boot",
      )
    '';
  };

}
