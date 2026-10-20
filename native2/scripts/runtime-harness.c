// Loads a libDesktopTools.dylib the way the menu bar app does and drives start, status and stop, printing each
// status. Unsigned, it should report the signing error and serve nothing; run it against native/'s and native2's
// dylibs and compare.
//
//   clang -framework CoreFoundation native2/scripts/runtime-harness.c -o /tmp/runtime-harness
//   /tmp/runtime-harness native2/.build/release/libDesktopTools.dylib /tmp/harness.sock
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>

typedef void (*start_fn)(const char *, const char *);
typedef char *(*status_fn)(void);
typedef void (*void_fn)(void);
typedef void (*free_fn)(void *);

static void *symbol(void *handle, const char *name) {
	void *pointer = dlsym(handle, name);
	if (!pointer) {
		fprintf(stderr, "missing %s\n", name);
		exit(1);
	}
	return pointer;
}

// The runtime does its work on the main queue, so the harness turns the main run loop while it waits.
static void turn(double seconds, status_fn status, free_fn release, const char *label) {
	CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, false);
	char *json = status();
	printf("%s %s\n", label, json);
	release(json);
}

int main(int argc, char **argv) {
	if (argc < 3) {
		fprintf(stderr, "usage: %s <libDesktopTools.dylib> <socket>\n", argv[0]);
		return 2;
	}
	void *handle = dlopen(argv[1], RTLD_NOW);
	if (!handle) {
		fprintf(stderr, "%s\n", dlerror());
		return 1;
	}
	start_fn start = (start_fn)symbol(handle, "desktop_tools_start");
	status_fn status = (status_fn)symbol(handle, "desktop_tools_status");
	void_fn stop = (void_fn)symbol(handle, "desktop_tools_stop");
	free_fn release = (free_fn)symbol(handle, "desktop_tools_free");
	char *activity = ((status_fn)symbol(handle, "desktop_tools_activity"))();
	printf("activity %s\n", activity);
	release(activity);

	turn(0, status, release, "before");
	start(argv[2], "dev.githubnext.desktop-tools.harness-client");
	turn(1.5, status, release, "started");
	struct stat info;
	printf("socket %s\n", lstat(argv[2], &info) == 0 ? "exists" : "absent");
	stop();
	turn(1, status, release, "stopped");
	return 0;
}
