package main

import (
	"fmt"
	"strconv"
	"strings"
	"sync/atomic"

	"gomtp/send_to_js"

	"github.com/ganeshrvel/go-mtpfs/mtp"
	"github.com/ganeshrvel/go-mtpx"
	"github.com/ganeshrvel/usb"
)

var container deviceContainer

var cachedUsbInfo atomic.Pointer[mtp.UsbDeviceInfo]

func verifyMtpSession(c verifyMtpSessionMode) error {
	if container.dev == nil {
		return fmt.Errorf("ErrorMtpDetectFailed")
	}

	if !c.skipDeviceChangeCheck && container.deviceInfo != nil {
		dInfo, err := mtpx.FetchDeviceInfo(container.dev)
		if err != nil {
			container.deviceInfo = nil

			_ = _dispose()

			return err
		}

		if container.deviceInfo.SerialNumber != dInfo.SerialNumber {
			container.deviceInfo = dInfo

			return fmt.Errorf("ErrorDeviceChanged")
		}
	}

	return nil
}

func parseDeviceId(deviceId string) (vendorId uint16, productId uint16, serialNumber string, ok bool) {
	parts := strings.SplitN(deviceId, "|", 3)
	if len(parts) != 3 {
		return 0, 0, "", false
	}

	vid, err := strconv.ParseUint(parts[0], 10, 16)
	if err != nil {
		return 0, 0, "", false
	}

	pid, err := strconv.ParseUint(parts[1], 10, 16)
	if err != nil {
		return 0, 0, "", false
	}

	return uint16(vid), uint16(pid), parts[2], true
}

func _initialize(input InitInput) (*mtp.Device, error) {
	var (
		d   *mtp.Device
		err error
	)

	if vid, pid, serial, ok := parseDeviceId(input.DeviceId); ok {
		d, err = mtpx.InitializeByDeviceId(vid, pid, serial, mtpx.Init{DebugMode: false})
	} else {
		d, err = mtpx.Initialize(mtpx.Init{DebugMode: false})
	}

	if err != nil {
		return nil, err
	}

	container.dev = d

	return d, nil
}

// _fetchAvailableDevices enumerates USB devices without claiming the interface,
// so it is safe to call while an MTP session is open.
func _fetchAvailableDevices() ([]send_to_js.AvailableDevice, error) {
	ctx := usb.NewContext()
	defer ctx.Exit()

	list, err := ctx.GetDeviceList()
	if err != nil {
		return nil, err
	}
	defer list.Done()

	var result []send_to_js.AvailableDevice

	for _, d := range list {
		dd, err := d.GetDeviceDescriptor()
		if err != nil {
			continue
		}

		if !isMtpCandidate(d) {
			continue
		}

		di := send_to_js.AvailableDevice{
			VendorId:  dd.IdVendor,
			ProductId: dd.IdProduct,
		}

		h, err := d.Open()
		if err != nil {
			// The device we hold a session for may refuse a second open.
			// Fall back to the identifiers cached at initialization time.
			if cached := cachedUsbInfo.Load(); cached != nil &&
				cached.IdVendor == dd.IdVendor && cached.IdProduct == dd.IdProduct {
				di.Manufacturer = cached.Manufacturer
				di.Model = cached.Product
				di.SerialNumber = cached.SerialNumber
				result = append(result, di)
			}

			continue
		}

		if dd.Manufacturer != 0 {
			di.Manufacturer, _ = h.GetStringDescriptorASCII(dd.Manufacturer)
		}
		if dd.Product != 0 {
			di.Model, _ = h.GetStringDescriptorASCII(dd.Product)
		}
		if dd.SerialNumber != 0 {
			di.SerialNumber, _ = h.GetStringDescriptorASCII(dd.SerialNumber)
		}

		_ = h.Close()

		result = append(result, di)
	}

	return result, nil
}

// isMtpCandidate mirrors mtp.candidateFromDeviceDescriptor: an interface
// alternate setting declaring bulk IN, bulk OUT and interrupt IN endpoints.
func isMtpCandidate(d *usb.Device) bool {
	dd, err := d.GetDeviceDescriptor()
	if err != nil {
		return false
	}

	for i := byte(0); i < dd.NumConfigurations; i++ {
		cdec, err := d.GetConfigDescriptor(i)
		if err != nil {
			continue
		}

		for _, iface := range cdec.Interfaces {
			for _, alt := range iface.AltSetting {
				if len(alt.EndPoints) != 3 {
					continue
				}

				var bulkIn, bulkOut, interruptIn bool
				for _, ep := range alt.EndPoints {
					switch {
					case ep.Direction() == usb.ENDPOINT_IN && ep.TransferType() == usb.TRANSFER_TYPE_INTERRUPT:
						interruptIn = true
					case ep.Direction() == usb.ENDPOINT_IN && ep.TransferType() == usb.TRANSFER_TYPE_BULK:
						bulkIn = true
					case ep.Direction() == usb.ENDPOINT_OUT && ep.TransferType() == usb.TRANSFER_TYPE_BULK:
						bulkOut = true
					}
				}

				if bulkIn && bulkOut && interruptIn {
					return true
				}
			}
		}
	}

	return false
}

func _fetchDeviceInfo() (*mtp.DeviceInfo, error) {
	v := verifyMtpSessionMode{skipDeviceChangeCheck: true}

	if err := verifyMtpSession(v); err != nil {
		return nil, err
	}

	dInfo, err := mtpx.FetchDeviceInfo(container.dev)
	if err != nil {
		container.deviceInfo = nil

		return nil, err
	}

	container.deviceInfo = dInfo

	return dInfo, nil
}

func _fetchStorages() ([]mtpx.StorageData, error) {
	if err := verifyMtpSession(verifyMtpSessionMode{}); err != nil {
		return nil, err
	}

	storages, err := mtpx.FetchStorages(container.dev)
	if err != nil {
		return nil, err
	}

	return storages, nil
}

func _makeDirectory(storageId uint32, fullPath string) error {
	if err := verifyMtpSession(verifyMtpSessionMode{}); err != nil {
		return err
	}

	_, err := mtpx.MakeDirectory(container.dev, storageId, fullPath)
	if err != nil {
		return err
	}

	return nil
}

func _fileExists(storageId uint32, fileProps []mtpx.FileProp) ([]mtpx.FileExistsContainer, error) {
	if err := verifyMtpSession(verifyMtpSessionMode{}); err != nil {
		return []mtpx.FileExistsContainer{}, err
	}

	exists, err := mtpx.FileExists(container.dev, storageId, fileProps)
	if err != nil {
		return exists, err
	}

	return exists, nil
}

func _deleteFile(storageId uint32, fileProps []mtpx.FileProp) error {
	if err := verifyMtpSession(verifyMtpSessionMode{}); err != nil {
		return err
	}

	err := mtpx.DeleteFile(container.dev, storageId, fileProps)
	if err != nil {
		return err
	}

	return nil
}

func _renameFile(storageId uint32, fileProp mtpx.FileProp, newFileName string) error {
	if err := verifyMtpSession(verifyMtpSessionMode{}); err != nil {
		return err
	}

	_, err := mtpx.RenameFile(container.dev, storageId, fileProp, newFileName)
	if err != nil {
		return err
	}

	return nil
}

func _walk(gen uint64, storageId uint32, fullPath string, recursive, skipDisallowedFiles, skipHiddenFiles bool) ([]*mtpx.FileInfo, error) {
	if err := verifyMtpSession(verifyMtpSessionMode{}); err != nil {
		return []*mtpx.FileInfo{}, err
	}

	var files []*mtpx.FileInfo

	_, _, _, err := mtpx.Walk(container.dev, storageId, fullPath, recursive, skipDisallowedFiles, skipHiddenFiles,
		func(objectId uint32, fi *mtpx.FileInfo, err error) error {
			if err != nil {
				return err
			}

			if walkSuperseded(gen) {
				return errWalkSuperseded
			}

			files = append(files, fi)

			return nil
		})
	if err != nil {
		return []*mtpx.FileInfo{}, err
	}

	return files, nil
}

func _uploadFiles(storageId uint32, sources []string, destination string, preprocessFiles bool, preprocessCb mtpx.LocalPreprocessCb, progressCb mtpx.ProgressCb) error {
	if err := verifyMtpSession(verifyMtpSessionMode{}); err != nil {
		return err
	}

	_, _, _, err := mtpx.UploadFiles(container.dev, storageId, sources, destination, preprocessFiles, preprocessCb, progressCb)
	if err != nil {
		return err
	}

	return nil
}

func _downloadFiles(storageId uint32, sources []string, destination string, preprocessFiles bool, preprocessCb mtpx.MtpPreprocessCb, progressCb mtpx.ProgressCb) error {
	if err := verifyMtpSession(verifyMtpSessionMode{}); err != nil {
		return err
	}

	_, _, err := mtpx.DownloadFiles(container.dev, storageId, sources, destination, preprocessFiles, preprocessCb, progressCb)
	if err != nil {
		return err
	}

	return nil
}

func _dispose() error {
	if container.dev == nil {
		return nil
	}

	mtpx.Dispose(container.dev)

	container.dev = nil
	container.deviceInfo = nil
	cachedUsbInfo.Store(nil)

	return nil
}
