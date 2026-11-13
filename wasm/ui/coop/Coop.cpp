/*
 * Cooperative threads for wasm webby: pthreads on the component model's thread built-ins.
 *
 * A wasm32-wasip1 module has one thread, and wasi-libc's pthread functions are stubs. Ladybird's media pipeline
 * (LibMedia's decoders, demuxer scans, sinks; MediaServer's sessions) runs on worker threads that wait on condition
 * variables, so running a thread's body inline to the end (patches/0018) cannot work for it. The component model's
 * cooperative threads can: thread.new-indirect starts a thread on a stack of wasmtime's own (a fiber), and
 * thread.switch-to (canon thread.suspend-then-resume) moves to another one. Nothing is preemptive: a thread runs
 * until it waits.
 *
 * Linked into the programs that are components (the UI, webby-core): their pthread_create, mutexes and condition
 * variables are the ones here, which take precedence over wasi-libc's stubs. Everything else keeps the stubs.
 *
 * Scheduling: the main thread (the implicit thread of whichever export call the host is making) runs the event
 * loop; LibCore's WASI event loop calls webby_coop_run() each time it waits, which runs every ready worker until it
 * waits again (or the time budget is spent). A worker that waits always switches back to the main thread. When the
 * main thread itself waits (a mutex a worker holds, a condition variable, join), it runs the workers until it can
 * go on.
 *
 * Stacks: clang keeps C's stack (address-taken locals, the GC's spilled pointers) in linear memory under the
 * __stack_pointer global, and binaryen's --stack-check traps when that global leaves [__stack_limit, __stack_base].
 * Each thread gets a stack of its own from the heap; a switch saves the three globals of the thread it leaves and
 * sets those of the thread it enters (binaryen-webby.patch makes --stack-check use __webby_stack_base/limit, the
 * globals defined below). LibGC only ever scans the main thread's stack: workers must not touch the GC heap (media
 * threads do not).
 */

#include <errno.h>
#include <new>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define CM_IMPORT(name) __attribute__((import_module("$root"), import_name(name)))
extern "C" {
CM_IMPORT("[thread-new-indirect-v0]") int webby_cm_thread_new(void (*start)(int), int context);
CM_IMPORT("[thread-suspend-then-resume]") int webby_cm_switch_to(int thread);
CM_IMPORT("[thread-resume-later]") void webby_cm_resume_later(int thread);
CM_IMPORT("[thread-index]") int webby_cm_thread_index();

uint32_t webby_coop_get_sp();
void webby_coop_set_stack(uint32_t sp, uint32_t base, uint32_t limit);
void webby_coop_get_limits(uint32_t* base_and_limit);
void webby_coop_entry(int context);
}

// The stack globals and the switch primitives. Stack limits are set before the stack pointer, so that
// --stack-check's test of the new stack pointer passes.
__asm__(R"(
.globaltype __stack_pointer, i32
.globaltype __webby_stack_base, i32
__webby_stack_base:
.globaltype __webby_stack_limit, i32
__webby_stack_limit:

.globl webby_coop_get_sp
.type webby_coop_get_sp,@function
webby_coop_get_sp:
  .functype webby_coop_get_sp () -> (i32)
  global.get __stack_pointer
  end_function

.globl webby_coop_set_stack
.type webby_coop_set_stack,@function
webby_coop_set_stack:
  .functype webby_coop_set_stack (i32, i32, i32) -> ()
  local.get 1
  global.set __webby_stack_base
  local.get 2
  global.set __webby_stack_limit
  local.get 0
  global.set __stack_pointer
  end_function

.globl webby_coop_get_limits
.type webby_coop_get_limits,@function
webby_coop_get_limits:
  .functype webby_coop_get_limits (i32) -> ()
  local.get 0
  global.get __webby_stack_base
  i32.store 0
  local.get 0
  global.get __webby_stack_limit
  i32.store 4
  end_function

# A thread's first frame. It has no stack frame of its own, so that after the body it can hand the main thread's
# stack back and end without an epilogue putting this thread's stack pointer back.
# No local may be live across a call either: binaryen's --spill-pointers would give the function a frame (and an
# epilogue) to spill it to. So the body hands the context back on the operand stack.
.functype webby_coop_thread_body (i32) -> (i32)
.functype webby_coop_thread_finish (i32) -> (i32)
.globl webby_coop_entry
.type webby_coop_entry,@function
webby_coop_entry:
  .functype webby_coop_entry (i32) -> ()
  .local i32
  local.get 0
  call webby_coop_thread_body
  call webby_coop_thread_finish
  local.set 1
  local.get 1
  i32.load 4
  global.set __webby_stack_base
  local.get 1
  i32.load 8
  global.set __webby_stack_limit
  local.get 1
  i32.load 0
  global.set __stack_pointer
  end_function
)");

namespace {

enum class State : uint8_t {
    Ready,
    Blocked,
    Done,
};

struct Thread {
    // Read by webby_coop_entry: keep these three first.
    uint32_t sp { 0 };
    uint32_t base { 0 };
    uint32_t limit { 0 };

    int cm { -1 };
    uint64_t id { 0 };
    State state { State::Ready };
    bool started { false };
    bool detached { false };
    bool timed_out { false };

    void* (*start)(void*) { nullptr };
    void* arg { nullptr };
    void* result { nullptr };
    void* stack { nullptr };

    // What a blocked thread waits for.
    void const* wait_cond { nullptr };
    void const* wait_mutex { nullptr };
    Thread* wait_join { nullptr };
    int64_t deadline_ns { -1 };

    char name[16] {};
};

Thread s_main;
Thread* s_current = &s_main;
Thread** s_threads = nullptr; // the workers, live or done but not yet joined
size_t s_thread_count = 0;
size_t s_thread_capacity = 0;
uint64_t s_next_id = 2;
size_t s_next_to_run = 0;
bool s_initialized = false;

constexpr size_t DEFAULT_STACK_SIZE = 1024 * 1024;

int64_t now_ns()
{
    timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return int64_t(ts.tv_sec) * 1'000'000'000 + ts.tv_nsec;
}

int64_t to_ns(timespec const* ts)
{
    return int64_t(ts->tv_sec) * 1'000'000'000 + ts->tv_nsec;
}

void initialize()
{
    if (s_initialized)
        return;
    s_initialized = true;
    s_main.id = 1;
    strcpy(s_main.name, "main");
}

// Leaves the current thread for `to`. Returns once something switches back to the current thread.
void switch_to(Thread* to)
{
    Thread* from = s_current;
    if (from == &s_main)
        s_main.cm = webby_cm_thread_index();
    from->sp = webby_coop_get_sp();
    uint32_t limits[2];
    webby_coop_get_limits(limits);
    from->base = limits[0];
    from->limit = limits[1];
    s_current = to;
    if (to->sp < to->limit || to->sp > to->base) {
        fprintf(stderr, "webby-coop: bad switch from %llu (%s) to %llu (%s) state %d started %d sp %x [%x, %x] main sp %x [%x, %x]\n",
            (unsigned long long)from->id, from->name, (unsigned long long)to->id, to->name, int(to->state), int(to->started),
            to->sp, to->limit, to->base, s_main.sp, s_main.limit, s_main.base);
    }
    to->started = true;
    webby_coop_set_stack(to->sp, to->base, to->limit);
    webby_cm_switch_to(to->cm);
}

void make_ready(Thread* t)
{
    t->state = State::Ready;
    t->wait_cond = nullptr;
    t->wait_mutex = nullptr;
    t->wait_join = nullptr;
    t->deadline_ns = -1;
}

void wake_timed_out(int64_t now)
{
    for (size_t i = 0; i < s_thread_count; ++i) {
        auto* t = s_threads[i];
        if (t->state == State::Blocked && t->deadline_ns >= 0 && now >= t->deadline_ns) {
            make_ready(t);
            t->timed_out = true;
        }
    }
    if (s_main.state == State::Blocked && s_main.deadline_ns >= 0 && now >= s_main.deadline_ns) {
        make_ready(&s_main);
        s_main.timed_out = true;
    }
}

void free_thread(Thread* t)
{
    for (size_t i = 0; i < s_thread_count; ++i) {
        if (s_threads[i] == t) {
            s_threads[i] = s_threads[--s_thread_count];
            break;
        }
    }
    free(t->stack);
    delete t;
}

void reap_detached()
{
    for (size_t i = 0; i < s_thread_count;) {
        auto* t = s_threads[i];
        if (t->state == State::Done && t->detached)
            free_thread(t);
        else
            ++i;
    }
}

// On the main thread: runs ready workers, one switch each, round robin. Returns whether one ran.
bool run_one_round()
{
    wake_timed_out(now_ns());
    bool ran = false;
    for (size_t n = 0; n < s_thread_count; ++n) {
        if (s_next_to_run >= s_thread_count)
            s_next_to_run = 0;
        auto* t = s_threads[s_next_to_run++];
        if (t->state != State::Ready)
            continue;
        switch_to(t);
        ran = true;
    }
    reap_detached();
    return ran;
}

int64_t next_deadline_ns()
{
    int64_t next = -1;
    for (size_t i = 0; i < s_thread_count; ++i) {
        auto* t = s_threads[i];
        if (t->state == State::Blocked && t->deadline_ns >= 0 && (next < 0 || t->deadline_ns < next))
            next = t->deadline_ns;
    }
    return next;
}

bool any_ready()
{
    for (size_t i = 0; i < s_thread_count; ++i) {
        if (s_threads[i]->state == State::Ready)
            return true;
    }
    return false;
}

// The current thread waits until make_ready() is called on it (or its deadline passes).
void block_current()
{
    Thread* self = s_current;
    self->state = State::Blocked;
    self->timed_out = false;
    if (self != &s_main) {
        switch_to(&s_main);
        return;
    }
    // The main thread runs the workers until one of them (or a deadline) readies it.
    while (s_main.state == State::Blocked) {
        if (run_one_round())
            continue;
        wake_timed_out(now_ns());
        if (s_main.state != State::Blocked)
            break;
        // Nothing can run: sleep until the next deadline (at most 1 ms, so a wake from elsewhere is noticed).
        int64_t wait = 1'000'000;
        int64_t next = next_deadline_ns();
        if (s_main.deadline_ns >= 0 && (next < 0 || s_main.deadline_ns < next))
            next = s_main.deadline_ns;
        if (next >= 0) {
            int64_t until = next - now_ns();
            if (until < wait)
                wait = until > 0 ? until : 0;
        }
        if (wait > 0) {
            timespec ts { time_t(wait / 1'000'000'000), long(wait % 1'000'000'000) };
            clock_nanosleep(CLOCK_MONOTONIC, 0, &ts, nullptr);
        }
    }
}

// --- mutexes ---

struct MutexImpl {
    uint64_t owner;
    int32_t count;
    int32_t type;
};
static_assert(sizeof(MutexImpl) <= sizeof(pthread_mutex_t));

MutexImpl* mutex_impl(pthread_mutex_t* m) { return reinterpret_cast<MutexImpl*>(m); }

void wake_one_waiting_on_mutex(void const* m)
{
    for (size_t i = 0; i < s_thread_count; ++i) {
        auto* t = s_threads[i];
        if (t->state == State::Blocked && t->wait_mutex == m) {
            make_ready(t);
            return;
        }
    }
    if (s_main.state == State::Blocked && s_main.wait_mutex == m)
        make_ready(&s_main);
}

void wake_waiting_on_cond(void const* c, bool all)
{
    for (size_t i = 0; i < s_thread_count; ++i) {
        auto* t = s_threads[i];
        if (t->state == State::Blocked && t->wait_cond == c) {
            make_ready(t);
            if (!all)
                return;
        }
    }
    if (s_main.state == State::Blocked && s_main.wait_cond == c)
        make_ready(&s_main);
}

}

extern "C" {

// Present only in programs that link this file: LibThreading and AK check it (a weak reference) to choose
// between these threads and running a thread's body inline.
int webby_coop_available() { return 1; }

uint64_t webby_coop_current_thread_id()
{
    initialize();
    return s_current->id;
}

int webby_coop_is_main_thread() { return s_current == &s_main; }

// Called by LibCore's event loop on the main thread whenever it waits for events: runs ready workers for up to
// `budget_ms`. Returns how many milliseconds until a worker's timed wait ends (-1: none; 0: a worker is ready).
int webby_coop_run(int budget_ms)
{
    initialize();
    if (s_current != &s_main || s_thread_count == 0)
        return -1;
    int64_t until = now_ns() + int64_t(budget_ms) * 1'000'000;
    do {
        if (!run_one_round())
            break;
    } while (now_ns() < until);
    if (any_ready())
        return 0;
    int64_t next = next_deadline_ns();
    if (next < 0)
        return -1;
    int64_t ms = (next - now_ns() + 999'999) / 1'000'000;
    return ms < 0 ? 0 : int(ms);
}

int webby_coop_thread_body(int context)
{
    auto* t = reinterpret_cast<Thread*>(context);
    t->result = t->start(t->arg);
    return context;
}

// After a thread's body: it is done, the threads waiting to join it may go on, and the main thread runs next.
// Returns the main thread's saved stack, which webby_coop_entry switches to before the thread ends.
int webby_coop_thread_finish(int context)
{
    auto* t = reinterpret_cast<Thread*>(context);
    t->state = State::Done;
    for (size_t i = 0; i < s_thread_count; ++i) {
        if (s_threads[i]->state == State::Blocked && s_threads[i]->wait_join == t)
            make_ready(s_threads[i]);
    }
    if (s_main.state == State::Blocked && s_main.wait_join == t)
        make_ready(&s_main);
    s_current = &s_main;
    webby_cm_resume_later(s_main.cm);
    return reinterpret_cast<int>(&s_main);
}

int pthread_create(pthread_t* out, pthread_attr_t const* attr, void* (*start)(void*), void* arg)
{
    initialize();
    size_t stack_size = DEFAULT_STACK_SIZE;
    if (attr) {
        size_t requested = 0;
        if (pthread_attr_getstacksize(attr, &requested) == 0 && requested > stack_size)
            stack_size = requested;
    }
    auto* t = new (std::nothrow) Thread;
    if (!t)
        return EAGAIN;
    t->stack = aligned_alloc(16, stack_size);
    if (!t->stack) {
        delete t;
        return EAGAIN;
    }
    t->id = s_next_id++;
    t->start = start;
    t->arg = arg;
    t->limit = reinterpret_cast<uint32_t>(t->stack);
    t->base = t->limit + stack_size;
    t->sp = t->base;
    t->cm = webby_cm_thread_new(webby_coop_entry, reinterpret_cast<int>(t));
    if (s_thread_count == s_thread_capacity) {
        size_t capacity = s_thread_capacity ? s_thread_capacity * 2 : 16;
        auto** grown = static_cast<Thread**>(realloc(s_threads, capacity * sizeof(Thread*)));
        if (!grown) {
            free(t->stack);
            delete t;
            return EAGAIN;
        }
        s_threads = grown;
        s_thread_capacity = capacity;
    }
    s_threads[s_thread_count++] = t;
    *out = reinterpret_cast<pthread_t>(t);
    return 0;
}

int pthread_join(pthread_t thread, void** result)
{
    auto* t = reinterpret_cast<Thread*>(thread);
    if (t == s_current)
        return EDEADLK;
    while (t->state != State::Done) {
        s_current->wait_join = t;
        block_current();
    }
    if (result)
        *result = t->result;
    free_thread(t);
    return 0;
}

int pthread_detach(pthread_t thread)
{
    auto* t = reinterpret_cast<Thread*>(thread);
    t->detached = true;
    if (t->state == State::Done && s_current == &s_main)
        free_thread(t);
    return 0;
}

pthread_t pthread_self()
{
    initialize();
    return reinterpret_cast<pthread_t>(s_current);
}

// pthread_setname_np and pthread_getname_np stay webby_wasi_compat's (names are not kept).

int sched_yield()
{
    if (s_current == &s_main) {
        run_one_round();
        return 0;
    }
    // Ready at once: the main thread switches back here on its next round.
    s_current->state = State::Ready;
    switch_to(&s_main);
    return 0;
}

int pthread_mutex_init(pthread_mutex_t* m, pthread_mutexattr_t const* attr)
{
    auto* impl = mutex_impl(m);
    memset(m, 0, sizeof(*m));
    int type = PTHREAD_MUTEX_NORMAL;
    if (attr)
        pthread_mutexattr_gettype(attr, &type);
    impl->type = type;
    return 0;
}

int pthread_mutex_destroy(pthread_mutex_t*) { return 0; }

int pthread_mutex_trylock(pthread_mutex_t* m)
{
    initialize();
    auto* impl = mutex_impl(m);
    if (impl->owner == 0) {
        impl->owner = s_current->id;
        impl->count = 1;
        return 0;
    }
    if (impl->owner == s_current->id && impl->type == PTHREAD_MUTEX_RECURSIVE) {
        ++impl->count;
        return 0;
    }
    return EBUSY;
}

int pthread_mutex_lock(pthread_mutex_t* m)
{
    initialize();
    auto* impl = mutex_impl(m);
    if (impl->owner == s_current->id) {
        if (impl->type == PTHREAD_MUTEX_RECURSIVE) {
            ++impl->count;
            return 0;
        }
        return EDEADLK;
    }
    while (impl->owner != 0) {
        s_current->wait_mutex = m;
        block_current();
    }
    impl->owner = s_current->id;
    impl->count = 1;
    return 0;
}

int pthread_mutex_unlock(pthread_mutex_t* m)
{
    auto* impl = mutex_impl(m);
    if (impl->owner != s_current->id)
        return EPERM;
    if (--impl->count > 0)
        return 0;
    impl->owner = 0;
    wake_one_waiting_on_mutex(m);
    return 0;
}

int pthread_cond_init(pthread_cond_t* c, pthread_condattr_t const*)
{
    memset(c, 0, sizeof(*c));
    return 0;
}

int pthread_cond_destroy(pthread_cond_t*) { return 0; }

static int cond_wait(pthread_cond_t* c, pthread_mutex_t* m, int64_t deadline_ns)
{
    initialize();
    auto* impl = mutex_impl(m);
    if (impl->owner != s_current->id)
        return EPERM;
    // A recursive mutex is released entirely while waiting, as glibc's is when locked once.
    int count = impl->count;
    impl->count = 1;
    pthread_mutex_unlock(m);
    Thread* self = s_current;
    self->wait_cond = c;
    self->deadline_ns = deadline_ns;
    block_current();
    bool timed_out = self->timed_out;
    self->timed_out = false;
    pthread_mutex_lock(m);
    impl->count = count;
    return timed_out ? ETIMEDOUT : 0;
}

int pthread_cond_wait(pthread_cond_t* c, pthread_mutex_t* m)
{
    return cond_wait(c, m, -1);
}

int pthread_cond_timedwait(pthread_cond_t* __restrict c, pthread_mutex_t* __restrict m, timespec const* __restrict abstime)
{
    int64_t deadline = to_ns(abstime);
    if (deadline <= now_ns()) {
        // Still a point where other threads may run, as a real wait would let them.
        if (s_current != &s_main)
            sched_yield();
        return ETIMEDOUT;
    }
    return cond_wait(c, m, deadline);
}

int pthread_cond_signal(pthread_cond_t* c)
{
    wake_waiting_on_cond(c, false);
    return 0;
}

int pthread_cond_broadcast(pthread_cond_t* c)
{
    wake_waiting_on_cond(c, true);
    return 0;
}

}
