// nimkit's JNI glue on Android: dev.nimkit.Native's native methods call into the Nim backend
// (src/nimkit/backend/android.nim, procs prefixed nk_), and the backend reaches Java through nk_op / nk_http, which
// call dev.nimkit.Host's static methods. Canvases are SurfaceViews whose ANativeWindows are kept here by widget id.
// Everything runs on the main thread. Taken from webby's nim/android/src/glue.c.
#include <android/log.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>
#include <jni.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// Nim side
extern void NimMain(void);
extern void nk_event(int id, int kind, char const* text, float x, float y, int pointer);
extern void nk_surface(int id, int width, int height, int attached);
extern void nk_timer(int id);
extern void nk_restart(void);

static JavaVM* vm;
static jclass host;
static jmethodID op_method, http_method;
static char data_dir[1024];
static float density = 1;
static int started;

JNIEXPORT jint JNI_OnLoad(JavaVM* v, void* reserved) {
    (void)reserved;
    vm = v;
    return JNI_VERSION_1_6;
}

static JNIEnv* env(void) {
    JNIEnv* e = NULL;
    (*vm)->GetEnv(vm, (void**)&e, JNI_VERSION_1_6);
    return e;
}

static char* jstr(JNIEnv* e, jstring s) {
    if (!s) return strdup("");
    char const* c = (*e)->GetStringUTFChars(e, s, NULL);
    char* r = strdup(c);
    (*e)->ReleaseStringUTFChars(e, s, c);
    return r;
}

// Java's modified UTF-8 chokes on some bytes; build the string from UTF-8 bytes instead.
static jstring utf8(JNIEnv* e, char const* text) {
    size_t n = strlen(text);
    jbyteArray bytes = (*e)->NewByteArray(e, (jsize)n);
    (*e)->SetByteArrayRegion(e, bytes, 0, (jsize)n, (jbyte const*)text);
    jclass string_class = (*e)->FindClass(e, "java/lang/String");
    jmethodID ctor = (*e)->GetMethodID(e, string_class, "<init>", "([BLjava/lang/String;)V");
    jstring charset = (*e)->NewStringUTF(e, "UTF-8");
    jstring s = (jstring)(*e)->NewObject(e, string_class, ctor, bytes, charset);
    (*e)->DeleteLocalRef(e, bytes);
    (*e)->DeleteLocalRef(e, charset);
    (*e)->DeleteLocalRef(e, string_class);
    return s;
}

// --- Nim -> Java

char const* nk_data_dir(void) { return data_dir; }
float nk_density(void) { return density; }
void nk_log(char const* text) { __android_log_write(ANDROID_LOG_INFO, "nimkit", text); }

void nk_op(int op, int id, int arg, char const* text) {
    JNIEnv* e = env();
    jstring s = utf8(e, text ? text : "");
    (*e)->CallStaticVoidMethod(e, host, op_method, op, id, arg, s);
    (*e)->DeleteLocalRef(e, s);
}

void nk_http(int id, char const* json) {
    JNIEnv* e = env();
    jstring s = utf8(e, json);
    (*e)->CallStaticVoidMethod(e, host, http_method, id, s);
    (*e)->DeleteLocalRef(e, s);
}

// --- Canvases: premultiplied BGRA pixels into the SurfaceView's window

#define MAX_SURFACES 64
static struct { int id; ANativeWindow* window; } surfaces[MAX_SURFACES];

static ANativeWindow** slot(int id, int make) {
    for (int i = 0; i < MAX_SURFACES; i++) if (surfaces[i].id == id) return &surfaces[i].window;
    if (!make) return NULL;
    for (int i = 0; i < MAX_SURFACES; i++) if (surfaces[i].id == 0) { surfaces[i].id = id; return &surfaces[i].window; }
    return NULL;
}

void nk_blit(int id, uint8_t const* pixels, int w, int h) {
    ANativeWindow** s = slot(id, 0);
    ANativeWindow* window = s ? *s : NULL;
    if (!window || !pixels || w <= 0 || h <= 0) return;
    // HAL_PIXEL_FORMAT_BGRA_8888 (5) is our layout; if the buffer comes back in another format, swizzle.
    if (ANativeWindow_getWidth(window) != w || ANativeWindow_getHeight(window) != h ||
        ANativeWindow_getFormat(window) != 5) {
        if (ANativeWindow_setBuffersGeometry(window, w, h, 5) != 0)
            ANativeWindow_setBuffersGeometry(window, w, h, WINDOW_FORMAT_RGBA_8888);
    }
    ANativeWindow_Buffer buffer;
    if (ANativeWindow_lock(window, &buffer, NULL) != 0) return;
    int rows = h < buffer.height ? h : buffer.height;
    int cols = w < buffer.width ? w : buffer.width;
    uint8_t* dst = buffer.bits;
    for (int y = 0; y < rows; y++) {
        uint32_t const* src = (uint32_t const*)(pixels + (size_t)y * w * 4);
        uint32_t* d = (uint32_t*)(dst + (size_t)y * buffer.stride * 4);
        if (buffer.format == 5) memcpy(d, src, (size_t)cols * 4);
        else for (int x = 0; x < cols; x++) {
            uint32_t p = src[x];
            d[x] = (p & 0xff00ff00u) | ((p >> 16) & 0xffu) | ((p & 0xffu) << 16);
        }
    }
    ANativeWindow_unlockAndPost(window);
}

// --- Java -> Nim (dev.nimkit.Native)

JNIEXPORT void JNICALL Java_dev_nimkit_Native_start(JNIEnv* e, jclass c, jclass h, jstring dir, jfloat d) {
    (void)c;
    if (host) (*e)->DeleteGlobalRef(e, host);
    host = (jclass)(*e)->NewGlobalRef(e, h);
    op_method = (*e)->GetStaticMethodID(e, host, "op", "(IIILjava/lang/String;)V");
    http_method = (*e)->GetStaticMethodID(e, host, "http", "(ILjava/lang/String;)V");
    char* s = jstr(e, dir);
    strncpy(data_dir, s, sizeof data_dir - 1);
    free(s);
    density = d;
    if (!started) {
        started = 1;
        NimMain();   // built with --noMain: runs the app's top level, which builds its widgets and calls run()
    } else {
        nk_restart();   // a new Activity in the same process: build the native views again
    }
}

JNIEXPORT void JNICALL Java_dev_nimkit_Native_event(JNIEnv* e, jclass c, jint id, jint kind, jstring text, jfloat x,
                                                    jfloat y, jint pointer) {
    (void)c;
    char* s = jstr(e, text);
    nk_event(id, kind, s, x, y, pointer);
    free(s);
}

JNIEXPORT void JNICALL Java_dev_nimkit_Native_surface(JNIEnv* e, jclass c, jint id, jobject surface, jint w, jint h) {
    (void)c;
    ANativeWindow** s = slot(id, 1);
    if (!s) return;
    if (*s && (!surface || *s != NULL)) { ANativeWindow_release(*s); *s = NULL; }
    if (surface) *s = ANativeWindow_fromSurface(e, surface);
    nk_surface(id, w, h, surface != NULL);
}

JNIEXPORT void JNICALL Java_dev_nimkit_Native_timer(JNIEnv* e, jclass c, jint id) {
    (void)e; (void)c;
    nk_timer(id);
}
