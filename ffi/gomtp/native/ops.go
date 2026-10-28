package main

import (
	"fmt"
	"strings"
	"sync"
	"sync/atomic"
)

const (
	opNone int32 = iota
	opWalk
	opExclusive
)

var errMtpBusy = fmt.Errorf("ErrorMtpLockExists")

var ops = struct {
	mu      sync.Mutex
	active  int32
	done    chan struct{}
	walkGen uint64
}{}

// beginWalk registers a new walk generation and waits until the device is free.
// A newer walk supersedes an older one, which aborts between two objects.
func beginWalk() (gen uint64, finish func(), superseded bool, err error) {
	ops.mu.Lock()
	ops.walkGen++
	gen = ops.walkGen

	for {
		if gen != ops.walkGen {
			ops.mu.Unlock()

			return gen, nil, true, nil
		}

		switch ops.active {
		case opNone:
			ops.active = opWalk
			done := make(chan struct{})
			ops.done = done
			ops.mu.Unlock()

			return gen, func() { releaseOp(done) }, false, nil

		case opWalk:
			ch := ops.done
			ops.mu.Unlock()
			<-ch
			ops.mu.Lock()

		default:
			ops.mu.Unlock()

			return gen, nil, false, errMtpBusy
		}
	}
}

// beginExclusive waits for the device. A running walk is asked to stop so that
// a transfer/delete/etc. does not fail with ErrorMtpLockExists just because a
// directory listing is still in flight.
func beginExclusive() (finish func(), err error) {
	ops.mu.Lock()
	ops.walkGen++

	for {
		switch ops.active {
		case opNone:
			ops.active = opExclusive
			done := make(chan struct{})
			ops.done = done
			ops.mu.Unlock()

			return func() { releaseOp(done) }, nil

		case opWalk:
			ch := ops.done
			ops.mu.Unlock()
			<-ch
			ops.mu.Lock()

		default:
			ops.mu.Unlock()

			return nil, errMtpBusy
		}
	}
}

func releaseOp(done chan struct{}) {
	ops.mu.Lock()
	defer ops.mu.Unlock()

	if ops.done != done {
		return
	}

	ops.active = opNone
	ops.done = nil
	close(done)
}

func walkSuperseded(gen uint64) bool {
	ops.mu.Lock()
	defer ops.mu.Unlock()

	return gen != ops.walkGen
}

var transferCancelled atomic.Bool

var errTransferCancelled = fmt.Errorf("transfer cancelled by user")

var errWalkSuperseded = fmt.Errorf("walk superseded by a newer request")

func isTransferCancelled(err error) bool {
	return err != nil && strings.Contains(err.Error(), "transfer cancelled by user")
}
