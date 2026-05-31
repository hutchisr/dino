class Dino < Formula
  desc "Dino is a modern XMPP client"
  homepage "https://dino.im"
  url "https://github.com/dino/dino.git"
  version "latest"

  depends_on "meson" => :build
  depends_on "ninja" => :build
  depends_on "librsvg" => :build # rsvg-convert, to rasterize the app icon
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

      build_app_bundle
  end

  # Wrap the installed CLI binary in a proper macOS .app so Dino can be
  # launched from Finder / Launchpad / Spotlight. The bundle is kept in the
  # keg (not auto-linked); see caveats for adding it to /Applications.
  def build_app_bundle
    app = prefix/"Dino.app"
    (app/"Contents/MacOS").mkpath
    (app/"Contents/Resources").mkpath

    # Launcher: Finder gives us none of Homebrew's environment, so point GTK
    # at the schemas, pixbuf loaders, GIO TLS modules (needed for XMPP) and
    # GStreamer plugins (calls) before exec'ing the real binary.
    launcher = app/"Contents/MacOS/Dino"
    launcher.write <<~SH
      #!/bin/bash
      export PATH="#{HOMEBREW_PREFIX}/bin:$PATH"
      export XDG_DATA_DIRS="#{HOMEBREW_PREFIX}/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
      export GSETTINGS_SCHEMA_DIR="#{HOMEBREW_PREFIX}/share/glib-2.0/schemas"
      export GDK_PIXBUF_MODULE_FILE="#{HOMEBREW_PREFIX}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache"
      export GIO_EXTRA_MODULES="#{HOMEBREW_PREFIX}/lib/gio/modules"
      export GST_PLUGIN_SYSTEM_PATH_1_0="#{HOMEBREW_PREFIX}/lib/gstreamer-1.0"
      exec "#{opt_bin}/dino" "$@"
    SH
    launcher.chmod 0755

    # Rasterize the scalable app icon into a multi-resolution .icns.
    svg = "main/data/icons/scalable/apps/im.dino.Dino.svg"
    iconset = buildpath/"Dino.iconset"
    iconset.mkpath
    {
      "icon_16x16.png"      => 16,
      "icon_16x16@2x.png"   => 32,
      "icon_32x32.png"      => 32,
      "icon_32x32@2x.png"   => 64,
      "icon_128x128.png"    => 128,
      "icon_128x128@2x.png" => 256,
      "icon_256x256.png"    => 256,
      "icon_256x256@2x.png" => 512,
      "icon_512x512.png"    => 512,
      "icon_512x512@2x.png" => 1024,
    }.each do |name, px|
      system "rsvg-convert", "-w", px.to_s, "-h", px.to_s, svg, "-o", iconset/name
    end
    system "iconutil", "-c", "icns", iconset, "-o", app/"Contents/Resources/dino.icns"

    (app/"Contents/Info.plist").write <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>CFBundleName</key>            <string>Dino</string>
        <key>CFBundleDisplayName</key>     <string>Dino</string>
        <key>CFBundleIdentifier</key>      <string>im.dino.Dino</string>
        <key>CFBundleExecutable</key>      <string>Dino</string>
        <key>CFBundleIconFile</key>        <string>dino</string>
        <key>CFBundlePackageType</key>     <string>APPL</string>
        <key>CFBundleShortVersionString</key> <string>0.5.0</string>
        <key>CFBundleVersion</key>         <string>0.5.0</string>
        <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
        <key>LSApplicationCategoryType</key> <string>public.app-category.social-networking</string>
        <key>LSMinimumSystemVersion</key>  <string>11.0</string>
        <key>NSHighResolutionCapable</key> <true/>
      </dict>
      </plist>
    XML
  end

  def caveats
    <<~EOS
      A macOS application bundle was installed to:
        #{opt_prefix}/Dino.app

      To launch Dino from Finder / Launchpad / Spotlight, symlink it into
      Applications (this path is stable across upgrades):
        ln -sfn #{opt_prefix}/Dino.app /Applications/Dino.app

      The bundle is unsigned, so on first launch right-click it and choose
      Open, or clear the quarantine flag:
        xattr -dr com.apple.quarantine #{opt_prefix}/Dino.app
    EOS
  end

  test do
    system "#{bin}/dino", "--version"
    assert_path_exists prefix/"Dino.app/Contents/MacOS/Dino"
    assert_path_exists prefix/"Dino.app/Contents/Resources/dino.icns"
  end
end
