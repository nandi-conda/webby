// The JNI side of webby-nim on Android: the Java shell's native methods (dev.webby.nim.Native), calls back into
// Java (dev.webby.nim.MainActivity's static on* methods), the pump timer on the main thread's ALooper, and the frame
// blit into the page's Surface. Everything else is Nim (webby_android.nim); the Nim procs used here are exported
// with the nim_ prefix and take plain C types.
#include <android/log.h>
#include <android/looper.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>
#include <jni.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/timerfd.h>
#include <unistd.h>

// Nim side
extern void NimMain(void);
extern int nim_init(char const* prefix, char const* profile, double density, int dark);
extern int nim_pump(void);
extern void nim_surface(int attached);
extern void nim_resize(int w, int h);
extern void nim_new_tab(char const* url, int focus);
extern void nim_close_tab(int index);
extern void nim_select_tab(int index);
extern void nim_load(char const* text);
extern void nim_nav(int what);
extern void nim_touch(int action, int pointer, float x, float y, int64_t ms);
extern void nim_key(int down, int code, int codepoint, int modifiers);
extern void nim_ime_commit(char const* text, int start, int length);
extern void nim_dialog_respond(int tab, int64_t id, int ok, char const* text);
extern void nim_set_focus(int on);
extern void nim_color_scheme(int scheme);
extern void nim_trim_memory(int level);
extern void nim_visible(int on);
extern void nim_save(void);
extern void nim_paste(char const* text);
extern void nim_context_action(char const* action, char const* arg);
extern char const* nim_command(char const* name, char const* args);

static char* jstr(JNIEnv* e, jstring s);

static JavaVM* vm;
static jclass activity_class;
static ANativeWindow* window;

JNIEXPORT jint JNI_OnLoad(JavaVM* v, void* reserved) {
    (void)reserved;
    vm = v;
    NimMain();   // built with --noMain: Nim's globals are set up here, once per process
    return JNI_VERSION_1_6;
}

void glue_log(char const* text) { __android_log_write(ANDROID_LOG_INFO, "webby-nim", text); }

static JNIEnv* env(void) {
    JNIEnv* e = NULL;
    (*vm)->GetEnv(vm, (void**)&e, JNI_VERSION_1_6);
    return e;
}

// Strings: real UTF-8 both ways (JNI's "UTF" calls use modified UTF-8, which mangles characters outside the BMP).

static jstring jnew(JNIEnv* e, char const* s) {
    if (!s) s = "";
    size_t n = strlen(s);
    jchar* u = malloc((n + 1) * sizeof(jchar));
    size_t k = 0;
    for (size_t i = 0; i < n;) {
        uint8_t c = (uint8_t)s[i];
        uint32_t cp;
        int len;
        if (c < 0x80) { cp = c; len = 1; }
        else if ((c & 0xe0) == 0xc0) { cp = c & 0x1f; len = 2; }
        else if ((c & 0xf0) == 0xe0) { cp = c & 0x0f; len = 3; }
        else if ((c & 0xf8) == 0xf0) { cp = c & 0x07; len = 4; }
        else { cp = 0xfffd; len = 1; }
        if (i + len > n) { cp = 0xfffd; len = (int)(n - i); }
        else for (int j = 1; j < len; j++) {
            uint8_t d = (uint8_t)s[i + j];
            if ((d & 0xc0) != 0x80) { cp = 0xfffd; len = j; break; }
            cp = (cp << 6) | (d & 0x3f);
        }
        i += len;
        if (cp >= 0x10000) {
            cp -= 0x10000;
            u[k++] = (jchar)(0xd800 + (cp >> 10));
            u[k++] = (jchar)(0xdc00 + (cp & 0x3ff));
        } else u[k++] = (jchar)cp;
    }
    jstring r = (*e)->NewString(e, u, (jsize)k);
    free(u);
    return r;
}

static char* jstr(JNIEnv* e, jstring s) {
    if (!s) return strdup("");
    jsize n = (*e)->GetStringLength(e, s);
    jchar const* u = (*e)->GetStringChars(e, s, NULL);
    char* r = malloc((size_t)n * 3 + 1);
    size_t k = 0;
    for (jsize i = 0; i < n; i++) {
        uint32_t cp = u[i];
        if (cp >= 0xd800 && cp < 0xdc00 && i + 1 < n && u[i + 1] >= 0xdc00 && u[i + 1] < 0xe000) {
            cp = 0x10000 + ((cp - 0xd800) << 10) + (u[i + 1] - 0xdc00);
            i++;
        }
        if (cp < 0x80) r[k++] = (char)cp;
        else if (cp < 0x800) { r[k++] = (char)(0xc0 | (cp >> 6)); r[k++] = (char)(0x80 | (cp & 0x3f)); }
        else if (cp < 0x10000) {
            r[k++] = (char)(0xe0 | (cp >> 12)); r[k++] = (char)(0x80 | ((cp >> 6) & 0x3f)); r[k++] = (char)(0x80 | (cp & 0x3f));
        } else {
            r[k++] = (char)(0xf0 | (cp >> 18)); r[k++] = (char)(0x80 | ((cp >> 12) & 0x3f));
            r[k++] = (char)(0x80 | ((cp >> 6) & 0x3f)); r[k++] = (char)(0x80 | (cp & 0x3f));
        }
    }
    r[k] = 0;
    (*e)->ReleaseStringChars(e, s, u);
    return r;
}

// MainActivity.<name>(String) on the main thread.
void glue_call(char const* name, char const* arg) {
    JNIEnv* e = env();
    if (!e || !activity_class) return;
    jmethodID m = (*e)->GetStaticMethodID(e, activity_class, name, "(Ljava/lang/String;)V");
    if (!m) {
        (*e)->ExceptionClear(e);
        return;
    }
    jstring s = jnew(e, arg);
    (*e)->CallStaticVoidMethod(e, activity_class, m, s);
    if ((*e)->ExceptionCheck(e)) {
        (*e)->ExceptionDescribe(e);
        (*e)->ExceptionClear(e);
    }
    (*e)->DeleteLocalRef(e, s);
}

// MainActivity.<name>(String) returning a String, for answers Nim waits for; the result is malloc'd UTF-8 (or NULL).
char* glue_call_string(char const* name, char const* arg) {
    JNIEnv* e = env();
    if (!e || !activity_class) return NULL;
    jmethodID m = (*e)->GetStaticMethodID(e, activity_class, name, "(Ljava/lang/String;)Ljava/lang/String;");
    if (!m) {
        (*e)->ExceptionClear(e);
        return NULL;
    }
    jstring s = jnew(e, arg);
    jstring r = (jstring)(*e)->CallStaticObjectMethod(e, activity_class, m, s);
    (*e)->DeleteLocalRef(e, s);
    if ((*e)->ExceptionCheck(e)) {
        (*e)->ExceptionDescribe(e);
        (*e)->ExceptionClear(e);
        return NULL;
    }
    if (!r) return NULL;
    char* out = jstr(e, r);
    (*e)->DeleteLocalRef(e, r);
    return out;
}

// --- Pump: a timerfd on the main thread's looper, re-armed with the delay nim_pump() asks for.

static int timer_fd = -1;
static int armed_ms = -1;

void glue_schedule(int ms) {
    if (timer_fd < 0) return;
    struct itimerspec spec = {0};
    spec.it_value.tv_sec = ms / 1000;
    spec.it_value.tv_nsec = (long)(ms % 1000) * 1000000L;
    if (spec.it_value.tv_nsec == 0 && spec.it_value.tv_sec == 0) spec.it_value.tv_nsec = 1;
    timerfd_settime(timer_fd, 0, &spec, NULL);
    armed_ms = ms;
}

static int on_timer(int fd, int events, void* data) {
    (void)events;
    (void)data;
    uint64_t n;
    while (read(fd, &n, sizeof n) == sizeof n) { }
    armed_ms = -1;
    int next = nim_pump();
    // nim_pump may have woken itself (glue_schedule) while it ran; keep the sooner one.
    if (armed_ms < 0 || next < armed_ms) glue_schedule(next);
    return 1;
}

// --- Frames: Ladybird's BGRA premultiplied pixels into the Surface, at the frame's own size (the compositor scales).

int glue_blit(uint8_t const* pixels, int w, int h) {
    if (!window || !pixels || w <= 0 || h <= 0) return 0;
    // HAL_PIXEL_FORMAT_BGRA_8888 (5) is Ladybird's layout; if the buffer comes back in another format, swizzle.
    if (ANativeWindow_getWidth(window) != w || ANativeWindow_getHeight(window) != h ||
        ANativeWindow_getFormat(window) != 5) {
        if (ANativeWindow_setBuffersGeometry(window, w, h, 5) != 0)
            ANativeWindow_setBuffersGeometry(window, w, h, WINDOW_FORMAT_RGBA_8888);
    }
    ANativeWindow_Buffer buffer;
    if (ANativeWindow_lock(window, &buffer, NULL) != 0) return 0;
    int rows = h < buffer.height ? h : buffer.height;
    int cols = w < buffer.width ? w : buffer.width;
    uint8_t* dst = buffer.bits;
    if (buffer.format == 5) {
        for (int y = 0; y < rows; y++) memcpy(dst + (size_t)y * buffer.stride * 4, pixels + (size_t)y * w * 4, (size_t)cols * 4);
    } else {
        for (int y = 0; y < rows; y++) {
            uint32_t const* s = (uint32_t const*)(pixels + (size_t)y * w * 4);
            uint32_t* d = (uint32_t*)(dst + (size_t)y * buffer.stride * 4);
            for (int x = 0; x < cols; x++) {
                uint32_t p = s[x];
                d[x] = (p & 0xff00ff00u) | ((p >> 16) & 0xffu) | ((p & 0xffu) << 16);
            }
        }
    }
    ANativeWindow_unlockAndPost(window);
    return 1;
}

// --- Native methods

#define FN(name) Java_dev_webby_nim_Native_##name

JNIEXPORT jint JNICALL FN(init)(JNIEnv* e, jclass c, jclass activity, jstring prefix, jstring profile, jfloat density,
                                jint dark) {
    (void)c;
    activity_class = (*e)->NewGlobalRef(e, activity);
    if (timer_fd < 0) {
        timer_fd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC);
        ALooper_addFd(ALooper_forThread(), timer_fd, ALOOPER_POLL_CALLBACK, ALOOPER_EVENT_INPUT, on_timer, NULL);
    }
    char* p = jstr(e, prefix);
    char* q = jstr(e, profile);
    int r = nim_init(p, q, density, dark);
    free(p);
    free(q);
    return r;
}

JNIEXPORT void JNICALL FN(setSurface)(JNIEnv* e, jclass c, jobject surface) {
    (void)c;
    if (window) {
        nim_surface(0);
        ANativeWindow_release(window);
        window = NULL;
    }
    if (surface) {
        window = ANativeWindow_fromSurface(e, surface);
        nim_surface(1);
    }
}

JNIEXPORT void JNICALL FN(resize)(JNIEnv* e, jclass c, jint w, jint h) { (void)e; (void)c; nim_resize(w, h); }

JNIEXPORT void JNICALL FN(newTab)(JNIEnv* e, jclass c, jstring url, jboolean focus) {
    (void)c;
    char* u = jstr(e, url);
    nim_new_tab(u, focus);
    free(u);
}

JNIEXPORT void JNICALL FN(closeTab)(JNIEnv* e, jclass c, jint i) { (void)e; (void)c; nim_close_tab(i); }
JNIEXPORT void JNICALL FN(selectTab)(JNIEnv* e, jclass c, jint i) { (void)e; (void)c; nim_select_tab(i); }

JNIEXPORT void JNICALL FN(load)(JNIEnv* e, jclass c, jstring text) {
    (void)c;
    char* t = jstr(e, text);
    nim_load(t);
    free(t);
}

JNIEXPORT void JNICALL FN(nav)(JNIEnv* e, jclass c, jint what) { (void)e; (void)c; nim_nav(what); }

JNIEXPORT void JNICALL FN(touch)(JNIEnv* e, jclass c, jint action, jint pointer, jfloat x, jfloat y, jlong ms) {
    (void)e;
    (void)c;
    nim_touch(action, pointer, x, y, ms);
}

JNIEXPORT void JNICALL FN(key)(JNIEnv* e, jclass c, jboolean down, jint code, jint cp, jint mods) {
    (void)e;
    (void)c;
    nim_key(down, code, cp, mods);
}

JNIEXPORT void JNICALL FN(imeCommit)(JNIEnv* e, jclass c, jstring text, jint start, jint length) {
    (void)c;
    char* t = jstr(e, text);
    nim_ime_commit(t, start, length);
    free(t);
}

JNIEXPORT void JNICALL FN(dialogRespond)(JNIEnv* e, jclass c, jint tab, jlong id, jboolean ok, jstring text) {
    (void)c;
    char* t = jstr(e, text);
    nim_dialog_respond(tab, id, ok, t);
    free(t);
}

JNIEXPORT void JNICALL FN(setFocus)(JNIEnv* e, jclass c, jboolean on) { (void)e; (void)c; nim_set_focus(on); }
JNIEXPORT void JNICALL FN(colorScheme)(JNIEnv* e, jclass c, jint s) { (void)e; (void)c; nim_color_scheme(s); }
JNIEXPORT void JNICALL FN(trimMemory)(JNIEnv* e, jclass c, jint l) { (void)e; (void)c; nim_trim_memory(l); }
JNIEXPORT void JNICALL FN(visible)(JNIEnv* e, jclass c, jboolean on) { (void)e; (void)c; nim_visible(on); }
JNIEXPORT void JNICALL FN(save)(JNIEnv* e, jclass c) { (void)e; (void)c; nim_save(); }

JNIEXPORT void JNICALL FN(paste)(JNIEnv* e, jclass c, jstring text) {
    (void)c;
    char* t = jstr(e, text);
    nim_paste(t);
    free(t);
}

JNIEXPORT void JNICALL FN(contextAction)(JNIEnv* e, jclass c, jstring action, jstring arg) {
    (void)c;
    char* a = jstr(e, action);
    char* b = jstr(e, arg);
    nim_context_action(a, b);
    free(a);
    free(b);
}

JNIEXPORT jstring JNICALL FN(command)(JNIEnv* e, jclass c, jstring name, jstring args) {
    (void)c;
    char* a = jstr(e, name);
    char* b = jstr(e, args);
    jstring r = jnew(e, nim_command(a, b));
    free(a);
    free(b);
    return r;
}
