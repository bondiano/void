/* void/fdwait — "park this fiber until a foreign file descriptor is
 * ready".
 *
 * Janet's ev loop can wait on its own streams, but nothing in `ev/`
 * waits on a descriptor somebody else owns. That is exactly what a
 * non-blocking C library needs from us: libpq (and librdkafka, and
 * every other library with a poll-me API) owns its socket, does its
 * own reading and writing, and only asks to be told when the kernel
 * has something. Reading a byte on its behalf would corrupt the
 * protocol stream.
 *
 * The C API has the two pieces Janet does not expose:
 *
 *   janet_stream(fd, flags, methods)  wraps an arbitrary descriptor
 *   janet_async_start(...)            sleeps the fiber until an event
 *                                     arrives — WITHOUT touching the
 *                                     descriptor itself
 *
 * so the whole shim is a watcher constructor and a wait. Everything
 * above it — the Postgres driver included — is plain Janet over ffi/.
 *
 * Three details are load-bearing, all of them learned from ev.c:
 *
 *   1. The event loop registers a stream by its *flags*, not by the
 *      mode passed to janet_async_start (epoll: `if (flags &
 *      READABLE) events |= EPOLLIN; if (flags & WRITABLE) events |=
 *      EPOLLOUT`, level-triggered; kqueue registers one filter per
 *      flag). A stream carrying both flags is therefore reported
 *      writable almost always, which would turn a *read* wait into a
 *      busy-spin. Hence one watcher, one direction — with :both as
 *      the deliberate exception, for the caller who wants whichever
 *      comes first and can make progress on either (a non-blocking
 *      send that must keep draining the receive side to avoid
 *      deadlocking against a server doing the same thing).
 *
 *   2. Every watcher gets its own dup() of the descriptor. Two
 *      streams over the *same* fd are two EPOLL_CTL_ADD calls on one
 *      key — EEXIST, and janet panics. dup() also decouples the
 *      watcher's lifetime from the library's: closing a watcher never
 *      closes the socket libpq is still using.
 *
 *   3. janet_async_start does not return (JANET_NO_RETURN): it must be
 *      the last thing a cfunction does.
 *
 * The callback keeps no state (NULL is passed for it), so there is
 * nothing to mark for the GC and nothing to free on DEINIT.
 */

#include <janet.h>
#include <string.h>

#ifndef JANET_WINDOWS
#include <unistd.h>
#include <errno.h>
#endif

/* -- the watcher ------------------------------------------------------ */

static JanetStream *fdwait_getstream(Janet *argv, int32_t n) {
    return janet_getabstract(argv, n, &janet_stream_type);
}

static Janet cfun_watch(int32_t argc, Janet *argv) {
    janet_fixarity(argc, 2);
    int32_t fd = janet_getinteger(argv, 0);
    if (fd < 0) {
        janet_panicf("fdwait/watch: %d is not a file descriptor", fd);
    }
    JanetKeyword dir = janet_getkeyword(argv, 1);
    uint32_t flags;
    if (!janet_cstrcmp(dir, "read")) {
        flags = JANET_STREAM_READABLE;
    } else if (!janet_cstrcmp(dir, "write")) {
        flags = JANET_STREAM_WRITABLE;
    } else if (!janet_cstrcmp(dir, "both")) {
        flags = JANET_STREAM_READABLE | JANET_STREAM_WRITABLE;
    } else {
        janet_panicf("fdwait/watch: direction must be :read, :write or :both, got %v",
                     argv[1]);
    }
#ifdef JANET_WINDOWS
    janet_panic("fdwait is not supported on windows");
#else
    int copy = dup((int) fd);
    if (copy < 0) {
        janet_panicf("fdwait/watch: dup(%d) failed: %s", fd, strerror(errno));
    }
    /* JANET_STREAM_SOCKET only decides close() vs closesocket() on
     * windows, and the descriptor may just as well be a pipe or an
     * eventfd — leave it off and let the loop poll what it is given. */
    JanetStream *stream = janet_stream((JanetHandle) copy, flags, NULL);
    /* Level-triggered, explicitly. epoll is level-triggered by default
     * and kqueue is not (EV_CLEAR), and the difference is invisible
     * until the second wait: a socket that was already writable when
     * the first wait armed it never "becomes" writable again, so an
     * edge-triggered watcher parks forever on a descriptor that is
     * ready right now. Level-triggered is also simply the right
     * semantics here — we report a *state*, not an arrival, and the
     * owning library decides how much of it to consume. */
    janet_stream_level_triggered(stream);
    return janet_wrap_abstract(stream);
#endif
}

static Janet cfun_close(int32_t argc, Janet *argv) {
    janet_fixarity(argc, 1);
    janet_stream_close(fdwait_getstream(argv, 0));
    return janet_wrap_nil();
}

static Janet cfun_closed(int32_t argc, Janet *argv) {
    janet_fixarity(argc, 1);
    JanetStream *stream = fdwait_getstream(argv, 0);
    return janet_wrap_boolean(stream->flags & JANET_STREAM_CLOSED);
}

static Janet cfun_direction(int32_t argc, Janet *argv) {
    janet_fixarity(argc, 1);
    JanetStream *stream = fdwait_getstream(argv, 0);
    int r = stream->flags & JANET_STREAM_READABLE;
    int w = stream->flags & JANET_STREAM_WRITABLE;
    return janet_ckeywordv((r && w) ? "both" : (w ? "write" : "read"));
}

/* -- the wait --------------------------------------------------------- */

/* One readiness event, then done. The fiber is scheduled with the
 * outcome and the callback is detached: a watcher is armed per wait,
 * never left listening.
 *
 * A readiness is reported as the direction it arrived in, so a :both
 * watcher can tell its caller which half to work on; for a
 * one-directional watcher the answer is a foregone conclusion but
 * spelling it the same way costs nothing. */
static void fdwait_callback(JanetFiber *fiber, JanetAsyncEvent event) {
    const char *outcome;
    switch (event) {
        default:
            return;
        case JANET_ASYNC_EVENT_READ:
            outcome = "read";
            break;
        case JANET_ASYNC_EVENT_WRITE:
            outcome = "write";
            break;
        /* The peer is gone, or the descriptor broke under us. Both are
         * reported rather than thrown: to libpq a hangup is just the
         * next PQconsumeInput returning an error it can describe far
         * better than we can. */
        case JANET_ASYNC_EVENT_HUP:
            outcome = "hup";
            break;
        case JANET_ASYNC_EVENT_ERR:
            outcome = "err";
            break;
        case JANET_ASYNC_EVENT_CLOSE:
            outcome = "closed";
            break;
    }
    janet_schedule(fiber, janet_ckeywordv(outcome));
    janet_async_end(fiber);
}

static Janet cfun_wait(int32_t argc, Janet *argv) {
    janet_fixarity(argc, 1);
    JanetStream *stream = fdwait_getstream(argv, 0);
    if (stream->flags & JANET_STREAM_CLOSED) {
        janet_panic("fdwait/wait: the watcher is closed");
    }
    int r = stream->flags & JANET_STREAM_READABLE;
    int w = stream->flags & JANET_STREAM_WRITABLE;
    JanetAsyncMode mode = (r && w) ? JANET_ASYNC_LISTEN_BOTH
                          : (w ? JANET_ASYNC_LISTEN_WRITE
                             : JANET_ASYNC_LISTEN_READ);
    /* JANET_NO_RETURN — nothing may follow. */
    janet_async_start(stream, mode, fdwait_callback, NULL);
}

/* -- module ----------------------------------------------------------- */

static const JanetReg cfuns[] = {
    {
        "watch", cfun_watch,
        "(fdwait/watch fd direction)\n\n"
        "Watch a foreign file descriptor for readiness: :read, :write, or "
        ":both for whichever comes first. The descriptor is dup'd, so the "
        "watcher owns its copy and closing it leaves fd alone. Prefer one "
        "direction: the event loop registers interest from the flags of the "
        "stream, so a :both watcher reports writable nearly always — right "
        "for a send loop that can also make progress on input, a busy-spin "
        "for anything else."
    },
    {
        "wait", cfun_wait,
        "(fdwait/wait watcher)\n\n"
        "Park the current fiber until the watched descriptor is ready, "
        "returning the direction it became ready in (:read or :write). "
        "Nothing is read or written — that is the owning library's job. "
        "Returns :hup, :err or :closed instead when the descriptor hangs up, "
        "errors, or the watcher is closed while waiting."
    },
    {
        "close", cfun_close,
        "(fdwait/close watcher)\n\n"
        "Close a watcher's copy of the descriptor. A fiber waiting on it "
        "wakes with :closed. Idempotent."
    },
    {
        "closed?", cfun_closed,
        "(fdwait/closed? watcher)\n\nHas this watcher been closed?"
    },
    {
        "direction", cfun_direction,
        "(fdwait/direction watcher)\n\nThe direction it watches: :read, :write or :both."
    },
    {NULL, NULL, NULL}
};

JANET_MODULE_ENTRY(JanetTable *env) {
    janet_cfuns(env, "fdwait", cfuns);
}
