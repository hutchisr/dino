dependencies = [
    dep_dino,
    dep_gdk_pixbuf,
    dep_gee,
    dep_gio,
    dep_glib,
    dep_qlite,
    dep_xmpp_vala,
]
sources = files(
    'dino_ios.vala',
    'tls_glue.c',
)
vala_args = []
if get_option('plugin-omemo').enabled()
    dependencies += [dep_omemo, dep_libomemo_c]
    vala_args += ['-D', 'WITH_OMEMO', '--vapidir', meson.project_source_root() / 'plugins/omemo/vapi']
endif
if get_option('plugin-http-files').enabled()
    dependencies += dep_http_files
    vala_args += ['-D', 'WITH_HTTP_FILES']
endif
lib_dino_ios = library('dinoios', sources, vala_args: vala_args, dependencies: dependencies, install: true, install_dir: [true, true, true])
