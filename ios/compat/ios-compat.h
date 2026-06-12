/*
 * iOS cross-compile compatibility header, force-included via the Meson
 * cross file (-include).
 *
 * Recent iOS SDKs export some POSIX-2024 symbols (pipe2, dup3, ...) from
 * libSystem without declaring them in the headers. Meson's link-based
 * cc.has_function() checks therefore report them as available, but
 * compilation then fails with implicit-function-declaration errors.
 * Declaring them here keeps both sides consistent.
 *
 * Note: these symbols only exist at runtime on recent OS versions; the
 * simulator inherits them from the macOS 26 host. Revisit before
 * lowering the device deployment target.
 */
#ifndef DINO_IOS_COMPAT_H
#define DINO_IOS_COMPAT_H
#ifndef __ASSEMBLER__

#ifdef __cplusplus
extern "C" {
#endif

int pipe2(int fildes[2], int flags);
int dup3(int oldfd, int newfd, int flags);

#ifdef __cplusplus
}
#endif

#endif /* !__ASSEMBLER__ */
#endif /* DINO_IOS_COMPAT_H */
