{ stdenv
, lib
, fetchFromGitLab
, autoreconfHook
, autoconf-archive
, pkg-config
, python3
, pygobject3
, dbus
, dbus-glib
, ncurses
}:

with lib;

stdenv.mkDerivation rec {
  pname = "dbus-python";
  version = "1.2.18";

  outputs = [ "out" "dev" ];

  src = fetchFromGitLab {
    domain = "gitlab.freedesktop.org";
    owner = "dbus";
    repo = pname;
    rev = "${pname}-${version}";
    sha256 = "147nwvl3b92vramsmxnfqjmalp4yj13v0lyxzajfkszgyl3xwbxs";
  };

  patches = [
    ./fix-includedir.patch
    ./fix-cross-compilation.patch
  ];

  autoreconfPhase = "NOCONFIGURE=1 ./autogen.sh";

  preConfigure =
    if (lib.versionAtLeast stdenv.hostPlatform.darwinMinVersion "11" && stdenv.isDarwin) then ''
      MACOSX_DEPLOYMENT_TARGET=10.16
    '' else null;

  nativeBuildInputs = [
    pkg-config
    autoconf-archive
    autoreconfHook
    python3
  ];

  buildInputs = [ dbus dbus-glib ]
    # My guess why it's sometimes trying to -lncurses.
    # It seems not to retain the dependency anyway.
    ++ lib.optional (! python3 ? modules) ncurses;

  checkInputs = [ dbus.out pygobject3 ];

  meta = {
    description = "Python DBus bindings";
    homepage = "https://gitlab.freedesktop.org/dbus/dbus-python";
    license = lib.licenses.mit;
    platforms = dbus.meta.platforms;
  };

}
