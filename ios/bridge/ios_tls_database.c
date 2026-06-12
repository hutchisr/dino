/*
 * GTlsDatabase backed by the iOS trust store (Security.framework).
 *
 * glib-networking's OpenSSL backend routes certificate verification through
 * g_tls_database_verify_chain() on the connection's database, so installing
 * this as the backend's default database makes every TLS connection validate
 * against the operating system's trust store (including user-installed
 * profiles and certificate transparency policy) instead of a CA file.
 */
#include <gio/gio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>

typedef struct {
    GTlsDatabase parent_instance;
} DinoIosTlsDatabase;

typedef struct {
    GTlsDatabaseClass parent_class;
} DinoIosTlsDatabaseClass;

GType dino_ios_tls_database_get_type(void);
G_DEFINE_TYPE(DinoIosTlsDatabase, dino_ios_tls_database, G_TYPE_TLS_DATABASE)

static GTlsCertificateFlags
dino_ios_tls_database_verify_chain(GTlsDatabase *database,
                                   GTlsCertificate *chain,
                                   const gchar *purpose,
                                   GSocketConnectable *identity,
                                   GTlsInteraction *interaction,
                                   GTlsDatabaseVerifyFlags flags,
                                   GCancellable *cancellable,
                                   GError **error)
{
    GTlsCertificateFlags result = 0;

    CFMutableArrayRef certs = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    for (GTlsCertificate *c = chain; c != NULL; c = g_tls_certificate_get_issuer(c)) {
        GByteArray *der = NULL;
        g_object_get(c, "certificate", &der, NULL);
        if (der == NULL) continue;
        CFDataRef data = CFDataCreate(NULL, der->data, der->len);
        g_byte_array_unref(der);
        if (data == NULL) continue;
        SecCertificateRef cert = SecCertificateCreateWithData(NULL, data);
        CFRelease(data);
        if (cert != NULL) {
            CFArrayAppendValue(certs, cert);
            CFRelease(cert);
        }
    }
    if (CFArrayGetCount(certs) == 0) {
        CFRelease(certs);
        return G_TLS_CERTIFICATE_GENERIC_ERROR;
    }

    const gchar *hostname = NULL;
    if (identity != NULL && G_IS_NETWORK_ADDRESS(identity)) {
        hostname = g_network_address_get_hostname(G_NETWORK_ADDRESS(identity));
    } else if (identity != NULL && G_IS_NETWORK_SERVICE(identity)) {
        hostname = g_network_service_get_domain(G_NETWORK_SERVICE(identity));
    }

    CFStringRef host_cf = hostname != NULL
        ? CFStringCreateWithCString(NULL, hostname, kCFStringEncodingUTF8)
        : NULL;
    SecPolicyRef policy = SecPolicyCreateSSL(true, host_cf);
    SecTrustRef trust = NULL;

    if (SecTrustCreateWithCertificates(certs, policy, &trust) == errSecSuccess) {
        CFErrorRef cferror = NULL;
        bool trusted = SecTrustEvaluateWithError(trust, &cferror);
        if (!trusted) {
            /* Security.framework doesn't distinguish failure causes in a way
             * that maps cleanly onto GTlsCertificateFlags; report the chain
             * as untrusted. */
            result = G_TLS_CERTIFICATE_UNKNOWN_CA;
            if (cferror != NULL) {
                CFStringRef desc = CFErrorCopyDescription(cferror);
                char buf[256] = "";
                if (desc != NULL) {
                    CFStringGetCString(desc, buf, sizeof buf, kCFStringEncodingUTF8);
                    CFRelease(desc);
                }
                g_message("ios-tls: %s NOT trusted: %s", hostname ? hostname : "?", buf);
            }
        } else {
            g_message("ios-tls: %s verified by iOS trust store", hostname ? hostname : "?");
        }
        if (cferror != NULL) CFRelease(cferror);
        CFRelease(trust);
    } else {
        result = G_TLS_CERTIFICATE_GENERIC_ERROR;
    }

    if (policy != NULL) CFRelease(policy);
    if (host_cf != NULL) CFRelease(host_cf);
    CFRelease(certs);
    return result;
}

static void dino_ios_tls_database_init(DinoIosTlsDatabase *self) {}

static void dino_ios_tls_database_class_init(DinoIosTlsDatabaseClass *klass) {
    G_TLS_DATABASE_CLASS(klass)->verify_chain = dino_ios_tls_database_verify_chain;
}

void dino_ios_install_tls_database(void) {
    GTlsBackend *backend = g_tls_backend_get_default();
    if (backend == NULL) {
        g_warning("ios-tls: no TLS backend registered");
        return;
    }
    GTlsDatabase *db = g_object_new(dino_ios_tls_database_get_type(), NULL);
    g_tls_backend_set_default_database(backend, db);
    g_object_unref(db);
    g_message("ios-tls: Security.framework trust database installed");
}
