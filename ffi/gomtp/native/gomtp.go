package main

/*
	#include "stdint.h"
	typedef void (* on_cb_result_t)(char*);
*/
import "C"

import (
	"fmt"
	"os"

	"gomtp/send_to_js"

	"github.com/ganeshrvel/go-mtpx"
	jsoniter "github.com/json-iterator/go"
)

func unmarshalInput(ptr *C.char, name string, v interface{}) error {
	if ptr == nil {
		return fmt.Errorf("empty %s input", name)
	}

	if err := jsoniter.ConfigFastest.UnmarshalFromString(C.GoString(ptr), v); err != nil {
		return fmt.Errorf("error occured while Unmarshalling %s input data %+v", name, err)
	}

	return nil
}

// releaseAndSend frees the device lock before delivering the final callback.
// Swift chains the next operation from inside it (Initialize -> FetchStorages),
// so holding the lock across the callback would reject that call with
// ErrorMtpLockExists.
func releaseAndSend(finish func(), send func()) {
	finish()
	send()
}

//export FetchAvailableDevices
func FetchAvailableDevices(onDonePtr *C.on_cb_result_t) {
	sendToJsOnDonePtr := (*send_to_js.SendCbResult)(onDonePtr)

	devices, err := _fetchAvailableDevices()
	if err != nil {
		send_to_js.SendError(sendToJsOnDonePtr, err)

		return
	}

	send_to_js.SendAvailableDevices(sendToJsOnDonePtr, devices)
}

//export Initialize
func Initialize(initInputJson *C.char, onDonePtr *C.on_cb_result_t) {
	sendToJsOnDonePtr := (*send_to_js.SendCbResult)(onDonePtr)

	i := InitInput{}
	if err := unmarshalInput(initInputJson, "Initialize", &i); err != nil {
		send_to_js.SendError(sendToJsOnDonePtr, err)

		return
	}

	finish, err := beginExclusive()
	if err != nil {
		send_to_js.SendError(sendToJsOnDonePtr, err)

		return
	}
	defer finish()

	// A previous session might still be open (e.g. after a failed reconnect).
	_ = _dispose()

	d, err := _initialize(i)
	if err != nil {
		releaseAndSend(finish, func() { send_to_js.SendError(sendToJsOnDonePtr, err) })

		return
	}

	dInfo, err := _fetchDeviceInfo()
	if err != nil {
		releaseAndSend(finish, func() { send_to_js.SendError(sendToJsOnDonePtr, err) })

		return
	}

	usbDesc, err := d.GetUsbInfo()
	if err != nil {
		releaseAndSend(finish, func() { send_to_js.SendError(sendToJsOnDonePtr, err) })

		return
	}

	cachedUsbInfo.Store(usbDesc)

	releaseAndSend(finish, func() {
		send_to_js.SendInitialize(sendToJsOnDonePtr, dInfo, usbDesc)
	})
}

//export FetchDeviceInfo
func FetchDeviceInfo(deviceInputJson *C.char, onDonePtr *C.on_cb_result_t) {
	sendToJsOnDonePtr := (*send_to_js.SendCbResult)(onDonePtr)

	finish, err := beginExclusive()
	if err != nil {
		send_to_js.SendError(sendToJsOnDonePtr, err)

		return
	}
	defer finish()

	dInfo, err := _fetchDeviceInfo()
	if err != nil {
		releaseAndSend(finish, func() { send_to_js.SendError(sendToJsOnDonePtr, err) })

		return
	}

	usbDesc, err := container.dev.GetUsbInfo()
	if err != nil {
		releaseAndSend(finish, func() { send_to_js.SendError(sendToJsOnDonePtr, err) })

		return
	}

	releaseAndSend(finish, func() {
		send_to_js.SendDeviceInfo(sendToJsOnDonePtr, dInfo, usbDesc)
	})
}

//export FetchStorages
func FetchStorages(deviceInputJson *C.char, onDonePtr *C.on_cb_result_t) {
	sendToJsOnDonePtr := (*send_to_js.SendCbResult)(onDonePtr)

	finish, err := beginExclusive()
	if err != nil {
		send_to_js.SendError(sendToJsOnDonePtr, err)

		return
	}
	defer finish()

	storages, err := _fetchStorages()
	if err != nil {
		if container.dev != nil && container.deviceInfo != nil {
			// this is done to prevent samsung devices from returning usb timeouts
			_ = _dispose()
		}

		releaseAndSend(finish, func() { send_to_js.SendError(sendToJsOnDonePtr, err) })

		return
	}

	releaseAndSend(finish, func() {
		send_to_js.SendStorages(sendToJsOnDonePtr, storages)
	})
}

//export MakeDirectory
func MakeDirectory(makeDirectoryInputJson *C.char, onDonePtr *C.on_cb_result_t) {
	sendToJsOnDonePtr := (*send_to_js.SendCbResult)(onDonePtr)

	i := MakeDirectoryInput{}
	if err := unmarshalInput(makeDirectoryInputJson, "MakeDirectory", &i); err != nil {
		send_to_js.SendError(sendToJsOnDonePtr, err)

		return
	}

	finish, err := beginExclusive()
	if err != nil {
		send_to_js.SendError(sendToJsOnDonePtr, err)

		return
	}
	defer finish()

	if err := _makeDirectory(i.StorageId, i.FullPath); err != nil {
		releaseAndSend(finish, func() { send_to_js.SendError(sendToJsOnDonePtr, err) })

		return
	}

	releaseAndSend(finish, func() { send_to_js.SendMakeDirectory(sendToJsOnDonePtr) })
}

//export FileExists
func FileExists(fileExistsInputJson *C.char, onDonePtr *C.on_cb_result_t) {
	sendToJsOnDonePtr := (*send_to_js.SendCbResult)(onDonePtr)

	i := FileExistsInput{}
	if err := unmarshalInput(fileExistsInputJson, "FileExists", &i); err != nil {
		send_to_js.SendError(sendToJsOnDonePtr, err)

		return
	}

	finish, err := beginExclusive()
	if err != nil {
		send_to_js.SendError(sendToJsOnDonePtr, err)

		return
	}
	defer finish()

	var fProps []mtpx.FileProp
	for _, f := range i.Files {
		fProps = append(fProps, mtpx.FileProp{FullPath: f})
	}

	fc, err := _fileExists(i.StorageId, fProps)
	if err != nil {
		releaseAndSend(finish, func() { send_to_js.SendError(sendToJsOnDonePtr, err) })

		return
	}

	releaseAndSend(finish, func() {
		send_to_js.SendFileExists(sendToJsOnDonePtr, fc, i.Files)
	})
}

//export DeleteFile
func DeleteFile(deleteFileInputJson *C.char, onDonePtr *C.on_cb_result_t) {
	sendToJsOnDonePtr := (*send_to_js.SendCbResult)(onDonePtr)

	i := DeleteFileInput{}
	if err := unmarshalInput(deleteFileInputJson, "DeleteFile", &i); err != nil {
		send_to_js.SendError(sendToJsOnDonePtr, err)

		return
	}

	finish, err := beginExclusive()
	if err != nil {
		send_to_js.SendError(sendToJsOnDonePtr, err)

		return
	}
	defer finish()

	var fProps []mtpx.FileProp
	for _, f := range i.Files {
		fProps = append(fProps, mtpx.FileProp{FullPath: f})
	}

	if err := _deleteFile(i.StorageId, fProps); err != nil {
		releaseAndSend(finish, func() { send_to_js.SendError(sendToJsOnDonePtr, err) })

		return
	}

	releaseAndSend(finish, func() { send_to_js.SendDeleteFile(sendToJsOnDonePtr) })
}

//export RenameFile
func RenameFile(renameFileInputJson *C.char, onDonePtr *C.on_cb_result_t) {
	sendToJsOnDonePtr := (*send_to_js.SendCbResult)(onDonePtr)

	i := RenameFileInput{}
	if err := unmarshalInput(renameFileInputJson, "RenameFile", &i); err != nil {
		send_to_js.SendError(sendToJsOnDonePtr, err)

		return
	}

	finish, err := beginExclusive()
	if err != nil {
		send_to_js.SendError(sendToJsOnDonePtr, err)

		return
	}
	defer finish()

	fProp := mtpx.FileProp{FullPath: i.FullPath}

	if err := _renameFile(i.StorageId, fProp, i.NewFileName); err != nil {
		releaseAndSend(finish, func() { send_to_js.SendError(sendToJsOnDonePtr, err) })

		return
	}

	releaseAndSend(finish, func() { send_to_js.SendRenameFile(sendToJsOnDonePtr) })
}

//export Walk
func Walk(walkInputJson *C.char, onDonePtr *C.on_cb_result_t) {
	sendToJsOnDonePtr := (*send_to_js.SendCbResult)(onDonePtr)

	i := WalkInput{}
	if err := unmarshalInput(walkInputJson, "Walk", &i); err != nil {
		send_to_js.SendError(sendToJsOnDonePtr, err)

		return
	}

	gen, finish, superseded, err := beginWalk()
	if err != nil {
		send_to_js.SendError(sendToJsOnDonePtr, err)

		return
	}
	if superseded {
		send_to_js.SendWalkCancelled(sendToJsOnDonePtr)

		return
	}
	defer finish()

	files, err := _walk(gen, i.StorageId, i.FullPath, i.Recursive, i.SkipDisallowedFiles, i.SkipHiddenFiles)
	if err != nil {
		if walkSuperseded(gen) {
			releaseAndSend(finish, func() { send_to_js.SendWalkCancelled(sendToJsOnDonePtr) })
		} else {
			releaseAndSend(finish, func() { send_to_js.SendError(sendToJsOnDonePtr, err) })
		}

		return
	}

	// A newer listing took over while this one was finishing; its result wins.
	if walkSuperseded(gen) {
		releaseAndSend(finish, func() { send_to_js.SendWalkCancelled(sendToJsOnDonePtr) })

		return
	}

	releaseAndSend(finish, func() {
		send_to_js.SendWalk(sendToJsOnDonePtr, files)
	})
}

//export UploadFiles
func UploadFiles(uploadFilesInputJson *C.char, onPreprocessPtr, onProgressPtr, onDonePtr *C.on_cb_result_t) {
	sendToJsOnPreprocessPtr := (*send_to_js.SendCbResult)(onPreprocessPtr)
	sendToJsOnProgressPtr := (*send_to_js.SendCbResult)(onProgressPtr)
	sendToJsOnDonePtr := (*send_to_js.SendCbResult)(onDonePtr)

	i := UploadFilesInput{}
	if err := unmarshalInput(uploadFilesInputJson, "UploadFiles", &i); err != nil {
		send_to_js.SendError(sendToJsOnDonePtr, err)

		return
	}

	finish, err := beginExclusive()
	if err != nil {
		send_to_js.SendError(sendToJsOnDonePtr, err)

		return
	}
	defer finish()

	transferCancelled.Store(false)

	err = _uploadFiles(i.StorageId, i.Sources, i.Destination, i.PreprocessFiles,
		func(fi *os.FileInfo, fullPath string, err error) error {
			if err != nil {
				return err
			}

			if transferCancelled.Load() {
				return errTransferCancelled
			}

			send_to_js.SendUploadFilesPreprocess(sendToJsOnPreprocessPtr, fi, fullPath)

			return nil
		},
		func(p *mtpx.ProgressInfo, err error) error {
			if err != nil {
				return err
			}

			if transferCancelled.Load() {
				return errTransferCancelled
			}

			send_to_js.SendTransferFilesProgress(sendToJsOnProgressPtr, p)

			return nil
		})
	if err != nil {
		if isTransferCancelled(err) {
			releaseAndSend(finish, func() { send_to_js.SendTransferCancelled(sendToJsOnDonePtr) })
		} else {
			releaseAndSend(finish, func() { send_to_js.SendError(sendToJsOnDonePtr, err) })
		}

		return
	}

	releaseAndSend(finish, func() { send_to_js.SendTransferFilesDone(sendToJsOnDonePtr) })
}

//export DownloadFiles
func DownloadFiles(downloadFilesInputJson *C.char, onPreprocessPtr, onProgressPtr, onDonePtr *C.on_cb_result_t) {
	sendToJsOnPreprocessPtr := (*send_to_js.SendCbResult)(onPreprocessPtr)
	sendToJsOnProgressPtr := (*send_to_js.SendCbResult)(onProgressPtr)
	sendToJsOnDonePtr := (*send_to_js.SendCbResult)(onDonePtr)

	i := DownloadFilesInput{}
	if err := unmarshalInput(downloadFilesInputJson, "DownloadFiles", &i); err != nil {
		send_to_js.SendError(sendToJsOnDonePtr, err)

		return
	}

	finish, err := beginExclusive()
	if err != nil {
		send_to_js.SendError(sendToJsOnDonePtr, err)

		return
	}
	defer finish()

	transferCancelled.Store(false)

	err = _downloadFiles(i.StorageId, i.Sources, i.Destination, i.PreprocessFiles,
		func(fi *mtpx.FileInfo, err error) error {
			if err != nil {
				return err
			}

			if transferCancelled.Load() {
				return errTransferCancelled
			}

			send_to_js.SendDownloadFilesPreprocess(sendToJsOnPreprocessPtr, fi)

			return nil
		},
		func(p *mtpx.ProgressInfo, err error) error {
			if err != nil {
				return err
			}

			if transferCancelled.Load() {
				return errTransferCancelled
			}

			send_to_js.SendTransferFilesProgress(sendToJsOnProgressPtr, p)

			return nil
		})
	if err != nil {
		if isTransferCancelled(err) {
			releaseAndSend(finish, func() { send_to_js.SendTransferCancelled(sendToJsOnDonePtr) })
		} else {
			releaseAndSend(finish, func() { send_to_js.SendError(sendToJsOnDonePtr, err) })
		}

		return
	}

	releaseAndSend(finish, func() { send_to_js.SendTransferFilesDone(sendToJsOnDonePtr) })
}

//export CancelTransfer
func CancelTransfer(cancelTransferInputJson *C.char, onDonePtr *C.on_cb_result_t) {
	sendToJsOnDonePtr := (*send_to_js.SendCbResult)(onDonePtr)

	transferCancelled.Store(true)

	send_to_js.SendCancelTransfer(sendToJsOnDonePtr)
}

//export Dispose
func Dispose(deviceInputJson *C.char, onDonePtr *C.on_cb_result_t) {
	sendToJsOnDonePtr := (*send_to_js.SendCbResult)(onDonePtr)

	finish, err := beginExclusive()
	if err != nil {
		send_to_js.SendError(sendToJsOnDonePtr, err)

		return
	}
	defer finish()

	if err := _dispose(); err != nil {
		releaseAndSend(finish, func() { send_to_js.SendError(sendToJsOnDonePtr, err) })

		return
	}

	transferCancelled.Store(false)

	releaseAndSend(finish, func() { send_to_js.SendDispose(sendToJsOnDonePtr) })
}

func main() {}
