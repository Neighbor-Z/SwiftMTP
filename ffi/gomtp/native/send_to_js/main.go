package send_to_js

/*
	#include "stdio.h"
	#include "stdlib.h"
	#include "stdbool.h"

	typedef void (* on_cb_result_t)(char*);
	void send_cb_result(on_cb_result_t* ptr, char* json) {
		on_cb_result_t cb = (on_cb_result_t) ptr;

		if(cb != 0 && cb != NULL){
			cb(json);
		}
	}
*/
import "C"

import (
	"os"
	"time"
	"unsafe"

	"github.com/ganeshrvel/go-mtpfs/mtp"
	"github.com/ganeshrvel/go-mtpx"
)

type SendCbResult C.on_cb_result_t

// send serializes [o] and hands it to the caller. The C string is released
// once the callback returns; every consumer copies it synchronously.
func send(onDonePtr *SendCbResult, o interface{}) {
	json := toJson(o)
	cjson := C.CString(json)

	C.send_cb_result((*C.on_cb_result_t)(onDonePtr), cjson)

	C.free(unsafe.Pointer(cjson))
}

func SendError(onDonePtr *SendCbResult, err error) {
	errorType, errorMsg := processError(err)

	send(onDonePtr, ErrorResult{
		ErrorType: errorType,
		Error:     errorMsg,
		Data:      nil,
	})
}

func SendInitialize(onDonePtr *SendCbResult, deviceInfo *mtp.DeviceInfo, usbDesc *mtp.UsbDeviceInfo) {
	send(onDonePtr, InitializeResult{
		Data: DeviceInfo{
			MtpDeviceInfo: deviceInfo,
			UsbDeviceInfo: usbDesc,
		},
	})
}

func SendDeviceInfo(onDonePtr *SendCbResult, deviceInfo *mtp.DeviceInfo, usbDesc *mtp.UsbDeviceInfo) {
	send(onDonePtr, DeviceInfoResult{
		Data: DeviceInfo{
			MtpDeviceInfo: deviceInfo,
			UsbDeviceInfo: usbDesc,
		},
	})
}

func SendAvailableDevices(onDonePtr *SendCbResult, devices []AvailableDevice) {
	send(onDonePtr, AvailableDevicesResult{
		Data: devices,
	})
}

func SendStorages(onDonePtr *SendCbResult, storages []mtpx.StorageData) {
	send(onDonePtr, StoragesResult{
		Data: storages,
	})
}

func SendMakeDirectory(onDonePtr *SendCbResult) {
	send(onDonePtr, MakeDirectoryResult{
		Data: true,
	})
}

func SendFileExists(onDonePtr *SendCbResult, fc []mtpx.FileExistsContainer, inputFiles []string) {
	var fdSlice []FileExistsData

	for i, f := range fc {
		fdSlice = append(fdSlice, FileExistsData{
			Fullpath: inputFiles[i],
			Exists:   f.Exists,
		})
	}

	send(onDonePtr, FileExistsResult{
		Data: fdSlice,
	})
}

func SendDeleteFile(onDonePtr *SendCbResult) {
	send(onDonePtr, DeleteFileResult{
		Data: true,
	})
}

func SendRenameFile(onDonePtr *SendCbResult) {
	send(onDonePtr, RenameFileResult{
		Data: true,
	})
}

func SendWalk(onDonePtr *SendCbResult, files []*mtpx.FileInfo) {
	var outputFiles []FileInfo

	for _, f := range files {
		outputFiles = append(outputFiles, FileInfo{
			Size:       f.Size,
			IsDir:      f.IsDir,
			ModTime:    f.ModTime.Format(DateTimeFormat),
			Name:       f.Name,
			FullPath:   f.FullPath,
			ParentPath: f.ParentPath,
			Extension:  f.Extension,
			ParentId:   f.ParentId,
			ObjectId:   f.ObjectId,
		})
	}

	send(onDonePtr, WalkResult{
		Data: outputFiles,
	})
}

// SendWalkCancelled tells Swift that this listing was superseded by a newer
// one, so its result must be ignored.
func SendWalkCancelled(onDonePtr *SendCbResult) {
	send(onDonePtr, ErrorResult{
		ErrorType: ErrorWalkCancelled,
		Error:     "walk cancelled by a newer request",
		Data:      nil,
	})
}

func SendUploadFilesPreprocess(onDonePtr *SendCbResult, fi *os.FileInfo, fullPath string) {
	send(onDonePtr, UploadFilesPreprocessResult{
		Data: TransferPreprocessData{
			FullPath: fullPath,
			Name:     (*fi).Name(),
			Size:     (*fi).Size(),
		},
	})
}

func SendDownloadFilesPreprocess(onDonePtr *SendCbResult, fi *mtpx.FileInfo) {
	send(onDonePtr, DownloadFilesPreprocessResult{
		Data: TransferPreprocessData{
			FullPath: fi.FullPath,
			Name:     fi.Name,
			Size:     fi.Size,
		},
	})
}

func SendTransferFilesProgress(onDonePtr *SendCbResult, p *mtpx.ProgressInfo) {
	send(onDonePtr, UploadFilesProgressResult{
		Data: TransferProgressInfo{
			FullPath:          p.FileInfo.FullPath,
			Name:              p.FileInfo.Name,
			ElapsedTime:       time.Since(p.StartTime).Milliseconds(),
			Speed:             p.Speed,
			TotalFiles:        p.TotalFiles,
			TotalDirectories:  p.TotalDirectories,
			FilesSent:         p.FilesSent,
			FilesSentProgress: p.FilesSentProgress,
			ActiveFileSize: TransferSizeInfo{
				Total:    p.ActiveFileSize.Total,
				Sent:     p.ActiveFileSize.Sent,
				Progress: p.ActiveFileSize.Progress,
			},
			BulkFileSize: TransferSizeInfo{
				Total:    p.BulkFileSize.Total,
				Sent:     p.BulkFileSize.Sent,
				Progress: p.BulkFileSize.Progress,
			},
			Status: p.Status,
		},
	})
}

func SendTransferFilesDone(onDonePtr *SendCbResult) {
	send(onDonePtr, UploadFilesDoneResult{
		Data: true,
	})
}

// SendTransferCancelled reports a user-initiated cancellation. Swift detects
// the "cancelled" marker and resets the (now corrupt) MTP session.
func SendTransferCancelled(onDonePtr *SendCbResult) {
	send(onDonePtr, ErrorResult{
		ErrorType: ErrorTransferCancelled,
		Error:     "transfer cancelled by user",
		Data:      nil,
	})
}

func SendCancelTransfer(onDonePtr *SendCbResult) {
	send(onDonePtr, CancelTransferResult{
		Data: true,
	})
}

func SendDispose(onDonePtr *SendCbResult) {
	send(onDonePtr, DisposeResult{
		Data: true,
	})
}
