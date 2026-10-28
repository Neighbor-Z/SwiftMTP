package main

import (
	"github.com/ganeshrvel/go-mtpfs/mtp"
)

type deviceContainer struct {
	dev        *mtp.Device
	deviceInfo *mtp.DeviceInfo
	usbInfo    *mtp.UsbDeviceInfo
}

type verifyMtpSessionMode struct {
	skipDeviceChangeCheck bool
}

type InitInput struct {
	DeviceId string `json:"deviceId"`
}

type DeviceInput struct {
	DeviceId string `json:"deviceId"`
}

type MakeDirectoryInput struct {
	DeviceId  string `json:"deviceId"`
	StorageId uint32 `json:"storageId"`
	FullPath  string `json:"fullPath"`
}

type FileExistsInput struct {
	DeviceId  string   `json:"deviceId"`
	StorageId uint32   `json:"storageId"`
	Files     []string `json:"files"`
}

type DeleteFileInput struct {
	DeviceId  string   `json:"deviceId"`
	StorageId uint32   `json:"storageId"`
	Files     []string `json:"files"`
}

type RenameFileInput struct {
	DeviceId    string `json:"deviceId"`
	StorageId   uint32 `json:"storageId"`
	FullPath    string `json:"fullPath"`
	NewFileName string `json:"newFileName"`
}

type WalkInput struct {
	DeviceId            string `json:"deviceId"`
	StorageId           uint32 `json:"storageId"`
	FullPath            string `json:"fullPath"`
	Recursive           bool   `json:"recursive"`
	SkipDisallowedFiles bool   `json:"skipDisallowedFiles"`
	SkipHiddenFiles     bool   `json:"skipHiddenFiles"`
}

type UploadFilesInput struct {
	DeviceId        string   `json:"deviceId"`
	StorageId       uint32   `json:"storageId"`
	Sources         []string `json:"sources"`
	Destination     string   `json:"destination"`
	PreprocessFiles bool     `json:"preprocessFiles"`
}

type DownloadFilesInput struct {
	DeviceId        string   `json:"deviceId"`
	StorageId       uint32   `json:"storageId"`
	Sources         []string `json:"sources"`
	Destination     string   `json:"destination"`
	PreprocessFiles bool     `json:"preprocessFiles"`
}
