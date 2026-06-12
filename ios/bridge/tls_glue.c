/*
 * Registers the statically linked glib-networking OpenSSL backend with GIO.
 * On iOS there is no module directory to scan, so the backend's GIOModule
 * load function is called directly with a NULL module; since GLib 2.56
 * g_type_module_register_type() treats that as static type registration.
 */
#include <gio/gio.h>

extern void g_io_openssl_load(void *module);
extern void dino_ios_install_tls_database(void);

void dino_poc_register_tls_backend(void) {
    g_io_extension_point_register(G_TLS_BACKEND_EXTENSION_POINT_NAME);
    g_io_openssl_load(NULL);
    dino_ios_install_tls_database();
}
