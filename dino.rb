class Dino < Formula
  desc "Dino is a modern XMPP client"
  homepage "https://dino.im"
  url "https://github.com/dino/dino.git"
  version "latest"

  depends_on "meson" => :build
  depends_on "ninja" => :build
  depends_on "adwaita-icon-theme"
  depends_on "libadwaita"
  depends_on "glib"
  depends_on "glib-networking"
  depends_on "gpgme"
  depends_on "icu4c"
  depends_on "libgpg-error"
  depends_on "libgcrypt"
  depends_on "gtk+3"
  depends_on "gtk4"
  depends_on "libgee"
  depends_on "libsoup"
  depends_on "libsoup@2"
  depends_on "libomemo-c"
  depends_on "sqlite"
  depends_on "cmake"
  depends_on "gettext"
  depends_on "ninja"
  depends_on "vala"
  depends_on "qrencode"
  depends_on "libxml2"
  depends_on "gspell"
  depends_on "gstreamer"
  depends_on "srtp"
  depends_on "libnice"

  def install
      # GLib's GModule looks for plugins with the `.so` suffix (Module.SUFFIX)
      # on macOS, but Meson builds shared modules as `.dylib`, so the loader
      # never finds them and encryption (OMEMO) etc. silently go missing.
      # Force the plugins to build with a `.so` suffix. (dino/dino#1830)
      Dir["plugins/*/meson.build"].each do |f|
        inreplace f, "name_prefix: ''", "name_prefix: '', name_suffix: 'so'"
      end

      system "meson", "setup", "build", *std_meson_args
      system "meson", "compile", "-C", "build"
      system "meson", "install", "-C", "build"
  end

  test do
    system "#{bin}/dino", "--version"
  end
end
