dependencies = [
    dep_crypto_vala,
    dep_dino,
    dep_gdk_pixbuf,
    dep_gee,
    dep_gio,
    dep_glib,
    dep_gmodule,
    dep_libgcrypt,
    dep_libomemo_c,
    dep_m,
    dep_qlite,
    dep_xmpp_vala,
]
sources = files(
    'src/dtls_srtp_verification_draft.vala',
    'src/file_transfer/file_decryptor.vala',
    'src/file_transfer/file_encryptor.vala',
    'src/jingle/jet_omemo.vala',
    'src/jingle/jingle_helper.vala',
    'src/logic/database.vala',
    'src/logic/decrypt.vala',
    'src/logic/encrypt.vala',
    'src/logic/manager.vala',
    'src/logic/pre_key_store.vala',
    'src/logic/session_store.vala',
    'src/logic/signed_pre_key_store.vala',
    'src/logic/trust_manager.vala',
    'src/plugin.vala',
    'src/protocol/bundle.vala',
    'src/protocol/message_flag.vala',
    'src/protocol/stream_module.vala',
    'src/native/context.vala',
    'src/native/helper.c',
    'src/native/simple_iks.vala',
    'src/native/simple_pks.vala',
    'src/native/simple_spks.vala',
    'src/native/simple_ss.vala',
    'src/native/store.vala',
    'src/native/util.vala',
    'src/trust_level.vala',
)
c_args = [
    '-DG_LOG_DOMAIN="OMEMO"',
]
vala_args = [
    '--vapidir', meson.current_source_dir() / 'vapi',
    # This is to build internal vapi for tests
    '--header', meson.current_build_dir() / 'omemo.h',
    '--internal-vapi', meson.current_build_dir() / 'omemo-internal.vapi',
    '--internal-header', meson.current_build_dir() / 'omemo-internal.h',
]
if not static_plugins
    sources += files('src/register_plugin.vala')
endif
# The GTK UI (src/ui, data/, po/) was removed with the desktop app; this is an
# iOS-only tree, so the plugin always builds headless.
vala_args += ['-D', 'DINO_NO_UI']
lib_omemo = library('omemo', sources, name_prefix: '', c_args: c_args, vala_args: vala_args, include_directories: include_directories('src'), dependencies: dependencies, install: true, install_dir: get_option('libdir') / get_option('plugindir'), install_rpath: default_install_rpath)
dep_omemo = declare_dependency(link_with: lib_omemo, include_directories: include_directories('.', 'src'))
summary('End-to-end encryption using OMEMO (omemo)', dep_omemo, section: 'Plugins')
# This is to use the internal vapi instead of the regular
vapi_omemo_internal = custom_target('omemo-internal-vapi', command: [find_program('touch'), meson.current_build_dir() / 'omemo-internal.vapi'], output: ['omemo-internal.vapi'], depends: lib_omemo)
dep_omemo_internal = declare_dependency(link_args: [lib_omemo.full_path()], include_directories: include_directories('.', 'src'), sources: [vapi_omemo_internal])

test_sources = [
    'tests/native/common.vala',
    'tests/native/testcase.vala',

    'tests/native/curve25519.vala',
    'tests/native/hkdf.vala',
    'tests/native/session_builder.vala',
]
test_vala_args = [
    '--vapidir', meson.current_source_dir() / 'vapi',
]

if not meson.is_cross_build()
exe_omemo_test = executable('omemo-test', test_sources, c_args: c_args, vala_args: test_vala_args, dependencies: dependencies + dep_omemo_internal, build_rpath: '$ORIGIN', install: false)
test('Tests for omemo', exe_omemo_test)
endif
