/* swap-fail.c: the proof tool for patch 0006
 * (docs/plugin/client-swap-fail/plan.md), run by swap-fail-open.
 * A test shim that makes chosen EGL buffer swaps fail, loaded with
 * LD_PRELOAD. It stands in for the NVIDIA driver's failed swap: a failed
 * swap here returns EGL_FALSE and never reaches the driver, so nothing is
 * shown for that frame.
 *
 *   SWAPFAIL_FIRST  the first swap to fail, counted from 1 (default: none)
 *   SWAPFAIL_COUNT  how many swaps in a row fail (default 1)
 *
 * The client gets eglSwapBuffersWithDamageKHR and EXT through
 * eglGetProcAddress, so the shim wraps that too.
 *
 * Build: cc -shared -fPIC -o swap-fail.so swap-fail.c -ldl
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef unsigned int EGLBoolean;
typedef int          EGLint;
typedef void *       EGLDisplay;
typedef void *       EGLSurface;
typedef void (*EglProc)(void);
typedef EGLBoolean (*SwapDamageFn)(EGLDisplay, EGLSurface, EGLint *, EGLint);

static unsigned long swaps;
static SwapDamageFn  realKHR, realEXT;

static unsigned long envNum(const char * name, unsigned long def)
{
  const char * v = getenv(name);
  return v && *v ? strtoul(v, NULL, 10) : def;
}

/* Count one swap and say whether it must fail. */
static int failThisSwap(void)
{
  const unsigned long first = envNum("SWAPFAIL_FIRST", 0);
  const unsigned long count = envNum("SWAPFAIL_COUNT", 1);
  const unsigned long n     = ++swaps;
  if (!first || n < first || n - first >= count)
    return 0;
  if (n == first || n == first + count - 1)
    fprintf(stderr, "swap-fail: swap %lu fails\n", n);
  return 1;
}

EGLBoolean eglSwapBuffers(EGLDisplay display, EGLSurface surface)
{
  static EGLBoolean (*real)(EGLDisplay, EGLSurface);
  if (!real)
    real = (EGLBoolean (*)(EGLDisplay, EGLSurface))
      dlsym(RTLD_NEXT, "eglSwapBuffers");
  return failThisSwap() ? 0 : real(display, surface);
}

static EGLBoolean swapKHR(EGLDisplay display, EGLSurface surface,
    EGLint * rects, EGLint count)
{
  return failThisSwap() ? 0 : realKHR(display, surface, rects, count);
}

static EGLBoolean swapEXT(EGLDisplay display, EGLSurface surface,
    EGLint * rects, EGLint count)
{
  return failThisSwap() ? 0 : realEXT(display, surface, rects, count);
}

EglProc eglGetProcAddress(const char * name)
{
  static EglProc (*real)(const char *);
  if (!real)
    real = (EglProc (*)(const char *))dlsym(RTLD_NEXT, "eglGetProcAddress");

  EglProc proc = real(name);
  if (!proc)
    return proc;
  if (!strcmp(name, "eglSwapBuffersWithDamageKHR"))
  {
    realKHR = (SwapDamageFn)proc;
    return (EglProc)swapKHR;
  }
  if (!strcmp(name, "eglSwapBuffersWithDamageEXT"))
  {
    realEXT = (SwapDamageFn)proc;
    return (EglProc)swapEXT;
  }
  return proc;
}
