#include "threading.h"
#include <stdlib.h>
#include <stdio.h>
#include <errno.h>
#include <time.h>

#define ERROR_LOG(msg,...) printf("threading ERROR: " msg "\n" , ##__VA_ARGS__)

static bool sleep_ms(int milliseconds)
{
    struct timespec remaining = {
        .tv_sec = milliseconds / 1000,
        .tv_nsec = (long)(milliseconds % 1000) * 1000000L
    };

    while (nanosleep(&remaining, &remaining) == -1) {
        if (errno != EINTR) {
            ERROR_LOG("nanosleep failed");
            return false;
        }
    }

    return true;
}

void* threadfunc(void* thread_param)
{
    struct thread_data* thread_func_args = (struct thread_data *) thread_param;

    if (thread_func_args == NULL) {
        return NULL;
    }

    thread_func_args->thread_complete_success = false;
    if (!sleep_ms(thread_func_args->wait_to_obtain_ms)) {
        return thread_func_args;
    }

    int result = pthread_mutex_lock(thread_func_args->mutex);
    if (result != 0) {
        ERROR_LOG("pthread_mutex_lock failed: %d", result);
        return thread_func_args;
    }

    bool release_wait_succeeded = sleep_ms(thread_func_args->wait_to_release_ms);
    result = pthread_mutex_unlock(thread_func_args->mutex);
    if (result != 0) {
        ERROR_LOG("pthread_mutex_unlock failed: %d", result);
        return thread_func_args;
    }

    thread_func_args->thread_complete_success = release_wait_succeeded;
    return thread_func_args;
}

bool start_thread_obtaining_mutex(pthread_t *thread, pthread_mutex_t *mutex,int wait_to_obtain_ms, int wait_to_release_ms)
{
    if (thread == NULL || mutex == NULL || wait_to_obtain_ms < 0 ||
        wait_to_release_ms < 0) {
        ERROR_LOG("invalid thread arguments");
        return false;
    }

    struct thread_data* thread_func_args = malloc(sizeof(*thread_func_args));
    if (thread_func_args == NULL) {
        ERROR_LOG("failed to allocate thread data");
        return false;
    }

    thread_func_args->mutex = mutex;
    thread_func_args->wait_to_obtain_ms = wait_to_obtain_ms;
    thread_func_args->wait_to_release_ms = wait_to_release_ms;
    thread_func_args->thread_complete_success = false;

    int result = pthread_create(thread, NULL, threadfunc, thread_func_args);
    if (result != 0) {
        ERROR_LOG("pthread_create failed: %d", result);
        free(thread_func_args);
        return false;
    }

    return true;
}
