//go:build darwin

package mtp

/*
#cgo LDFLAGS: -framework IOKit -framework CoreFoundation
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

typedef struct {
	int pid;
	char process_name[256];
} USBClientInfo;

// findUSBOccupyingClients iterates the IOService plane recursively (mirroring
// what ioreg does) and looks for entries whose class is
// AppleUSBHostDeviceUserClient or AppleUSBHostInterfaceUserClient.
// For each matching entry it reads the "IOUserClientCreator" property.
// Writes up to maxResults entries into results and sets *outWritten to the
// number actually written. Returns the total number of matches found
// (which may exceed maxResults).
static int findUSBOccupyingClients(USBClientInfo* results, int maxResults, int* outWritten) {
	int total = 0;
	int written = 0;

	io_iterator_t iter;
	// Recursively iterate the IOService plane – this is what ioreg does internally.
	kern_return_t kr = IORegistryCreateIterator(
		0, kIOServicePlane, kIORegistryIterateRecursively, &iter);
	if (kr != KERN_SUCCESS) {
		*outWritten = 0;
		return 0;
	}

	io_object_t entry;
	while ((entry = IOIteratorNext(iter)) != IO_OBJECT_NULL) {
		io_name_t className;
		IOObjectGetClass(entry, className);

		if (strcmp(className, "AppleUSBHostDeviceUserClient") == 0 ||
		    strcmp(className, "AppleUSBHostInterfaceUserClient") == 0) {

			CFTypeRef prop = IORegistryEntryCreateCFProperty(
				entry, CFSTR("IOUserClientCreator"), kCFAllocatorDefault, 0);
			if (prop && CFGetTypeID(prop) == CFStringGetTypeID()) {
				char buf[512];
				if (CFStringGetCString((CFStringRef)prop, buf, sizeof(buf), kCFStringEncodingUTF8)) {
					// The property value looks like: "pid 623, SomeProcess"
					int pid = 0;
					char name[256] = {0};
					if (sscanf(buf, "pid %d, %255s", &pid, name) == 2) {
						total++;
						if (written < maxResults) {
							results[written].pid = pid;
							strncpy(results[written].process_name, name, 255);
							results[written].process_name[255] = '\0';
							written++;
						}
					}
				}
			}
			if (prop) CFRelease(prop);
		}
		IOObjectRelease(entry);
	}
	IOObjectRelease(iter);
	*outWritten = written;
	return total;
}
*/
import "C"

import (
	"fmt"
	"log"
	"strings"
)

// getUSBOccupyingPIDs queries the IORegistry via IOKit to find processes that
// are holding USB host interface/device user clients. It excludes "SwiftMTP"
// and returns a formatted string like " (PID: 623, 829)".
func getUSBOccupyingPIDs() string {
	const maxResults = 64
	var results [maxResults]C.USBClientInfo

	var written C.int
	total := int(C.findUSBOccupyingClients(&results[0], C.int(maxResults), &written))

	if total > int(written) {
		log.Printf("USB diag: found %d matches but buffer only holds %d, PID list may be incomplete", total, written)
	}

	seen := make(map[int]bool)
	var pids []string

	for i := 0; i < int(written); i++ {
		pid := int(results[i].pid)
		procName := C.GoString(&results[i].process_name[0])
		if procName == "SwiftMTP" {
			continue
		}
		if !seen[pid] {
			seen[pid] = true
			pids = append(pids, fmt.Sprintf("%d", pid))
		}
	}

	if len(pids) == 0 {
		return ""
	}

	pidStr := strings.Join(pids, ", ")
	log.Printf("USB diag: device may be occupied by other processes, PID: %s", pidStr)
	return fmt.Sprintf(" (PID: %s)", pidStr)
}
