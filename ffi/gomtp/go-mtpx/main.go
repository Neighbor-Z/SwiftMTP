package mtpx

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/ganeshrvel/go-mtpfs/mtp"
	"github.com/ganeshrvel/usb"
)

// todo: work on documentations
// todo: hotplug

// initialize the mtp device
// returns mtp device
func Initialize(init Init, c ...*usb.Context) (*mtp.Device, error) {
	var ctx *usb.Context
	if len(c) > 0 {
		ctx = c[0]
	}

	if ctx == nil {
		ctx = usb.NewContext()
	}

	devs, err := mtp.FindDevices(ctx)
	if err != nil {
		return nil, MtpDetectFailedError{error: err}
	}
	if len(devs) == 0 {
		return nil, MtpDetectFailedError{error: fmt.Errorf("no MTP devices found")}
	}
	dev := devs[0]
	// Close other devices
	for i := 1; i < len(devs); i++ {
		devs[i].Done()
	}

	if err != nil {
		return nil, MtpDetectFailedError{error: err}
	}

	dev.MTPDebug = init.DebugMode
	dev.DataDebug = init.DebugMode
	dev.USBDebug = init.DebugMode

	dev.Timeout = devTimeout

	if err = dev.Configure(); err != nil {
		return nil, ConfigureError{error: err}
	}

	return dev, nil
}

// ListDevices returns information about all connected MTP devices.
// Each device is opened briefly to retrieve its information (manufacturer, product, serial),
// then closed. The returned MtpDeviceInfo contains VendorId, ProductId, and SerialNumber
// which can be used with InitializeByDeviceId to connect to a specific device.
func ListDevices(c ...*usb.Context) ([]MtpDeviceInfo, error) {
	var ctx *usb.Context
	if len(c) > 0 {
		ctx = c[0]
	}
	
	if ctx == nil {
		ctx = usb.NewContext()
		defer ctx.Exit()
	}

	devs, err := mtp.FindDevices(ctx)
	if err != nil {
		return nil, DeviceListError{error: err}
	}

	var result []MtpDeviceInfo

	for _, d := range devs {
		// Open the device to get its info
		if err := d.Open(); err != nil {
			d.Done()
			continue
		}

		// Get USB info (requires device to be open)
		usbInfo, err := d.GetUsbInfo()
		if err != nil {
			d.Close()
			d.Done()
			continue
		}

		info := MtpDeviceInfo{
			VendorId:     usbInfo.IdVendor,
			ProductId:    usbInfo.IdProduct,
			Manufacturer: usbInfo.Manufacturer,
			Model:        usbInfo.Product,
			SerialNumber: usbInfo.SerialNumber,
		}

		result = append(result, info)

		// Close and release the device
		d.Close()
		d.Done()
	}

	return result, nil
}

// InitializeByDeviceId opens a specific MTP device by vendor ID, product ID, and optional serial number.
// This enables connecting to a specific device when multiple MTP devices are connected.
//
// Parameters:
//   - vendorId: USB-IF vendor ID (e.g., 0x04e8 for Samsung)
//   - productId: USB-IF product ID (e.g., 0x6860)
//   - serialNumber: Optional device serial number. Pass empty string to match any device
//     with the given vendorId and productId. When empty and multiple devices match,
//     the first matching device will be selected.
//   - init: Initialization options including debug mode
//   - c: USB context
//
// Returns the opened device or an error if the device is not found or cannot be opened.
func InitializeByDeviceId(vendorId, productId uint16, serialNumber string, init Init, c ...*usb.Context) (*mtp.Device, error) {
	var ctx *usb.Context
	if len(c) > 0 {
		ctx = c[0]
	}

	if ctx == nil {
		ctx = usb.NewContext()
	}

	devs, err := mtp.FindDevices(ctx)
	if err != nil {
		return nil, MtpDetectFailedError{error: err}
	}

	if len(devs) == 0 {
		return nil, MtpDetectFailedError{error: fmt.Errorf("no MTP devices found")}
	}

	for _, d := range devs {
		// Open the device to get its info
		if err := d.Open(); err != nil {
			d.Done()
			continue
		}

		// Get USB info
		usbInfo, err := d.GetUsbInfo()
		if err != nil {
			d.Close()
			d.Done()
			continue
		}

		// Check if vendor and product IDs match
		if usbInfo.IdVendor != vendorId || usbInfo.IdProduct != productId {
			d.Close()
			d.Done()
			continue
		}

		// If serial number is specified, check if it matches
		if serialNumber != "" && usbInfo.SerialNumber != serialNumber {
			d.Close()
			d.Done()
			continue
		}

		// Found a matching device - close other candidates first
		for _, other := range devs {
			if other != d {
				other.Done()
			}
		}

		d.MTPDebug = init.DebugMode
		d.DataDebug = init.DebugMode
		d.USBDebug = init.DebugMode
		d.Timeout = devTimeout

		if err = d.Configure(); err != nil {
			d.Close()
			d.Done()
			return nil, ConfigureError{error: err}
		}

		return d, nil
	}

	if serialNumber != "" {
		return nil, DeviceNotFoundError{error: fmt.Errorf("device with vendorId=0x%04x, productId=0x%04x, serialNumber=%s not found", vendorId, productId, serialNumber)}
	}
	return nil, DeviceNotFoundError{error: fmt.Errorf("device with vendorId=0x%04x, productId=0x%04x not found", vendorId, productId)}
}

// GetDeviceIdentifiers returns the vendor ID, product ID, and serial number for an opened MTP device.
// These identifiers can be used to reconnect to the same device via InitializeByDeviceId.
func GetDeviceIdentifiers(dev *mtp.Device) (vendorId uint16, productId uint16, serialNumber string, err error) {
	usbInfo, err := dev.GetUsbInfo()
	if err != nil {
		return 0, 0, "", DeviceInfoError{error: err}
	}

	return usbInfo.IdVendor, usbInfo.IdProduct, usbInfo.SerialNumber, nil
}

// Dispose - close the mtp device
func Dispose(dev *mtp.Device) {
	dev.Close()
}

// FetchDeviceInfo - fetch device Info
func FetchDeviceInfo(dev *mtp.Device) (*mtp.DeviceInfo, error) {
	info := mtp.DeviceInfo{}
	err := dev.GetDeviceInfo(&info)

	if err != nil {
		return nil, DeviceInfoError{error: err}
	}

	return &info, nil
}

// FetchStorages - fetch storages
func FetchStorages(dev *mtp.Device) ([]StorageData, error) {
	sids := mtp.Uint32Array{}
	if err := dev.GetStorageIDs(&sids); err != nil {
		return nil, StorageInfoError{error: err}
	}

	if len(sids.Values) < 1 {
		return nil, NoStorageError{error: fmt.Errorf("no storage found")}
	}

	var result []StorageData

	for _, sid := range sids.Values {
		var info mtp.StorageInfo
		if err := dev.GetStorageInfo(sid, &info); err != nil {
			return nil, StorageInfoError{error: err}
		}

		result = append(result, StorageData{
			Sid:  sid,
			Info: info,
		})
	}

	return result, nil
}

// MakeDirectory - create a new directory recursively using [fullPath]
// The path will be created if it does not Exists
func MakeDirectory(dev *mtp.Device, storageId uint32, fullPath string) (objectId uint32, err error) {
	_fullPath := fixSlash(fullPath)

	if _fullPath == PathSep {
		return ParentObjectId, nil
	}
	splittedFullPath := strings.Split(_fullPath, PathSep)

	objectId = uint32(ParentObjectId)
	const skipIndex = 1

	for _, fName := range splittedFullPath[skipIndex:] {
		// fetch the parent object and
		fi, err := GetObjectFromParentIdAndFilename(dev, storageId, objectId, fName)

		if err != nil {
			switch err.(type) {
			case FileNotFoundError:
				// if object does not Exists then create a new directory
				_newObjectId, err := handleMakeDirectory(dev, storageId, objectId, fName)
				if err != nil {
					return 0, err
				}

				objectId = _newObjectId

				continue
			default:
				return 0, err
			}
		}

		// if the object Exists but if it's a file then throw an error
		if !fi.IsDir {
			return 0, InvalidPathError{error: fmt.Errorf("invalid path: %s. The object is not a directory", fName)}
		}

		objectId = fi.ObjectId
	}

	return objectId, nil
}

// List the contents in a directory
// use [recursive] to fetch the whole nested tree
// Tip: use [objectId] whenever possible to avoid traversing down the whole file tree to process and find the [objectId]
// if [skipDisallowedFiles] is true then files matching the [disallowedFiles] list will be ignored
// if [skipHiddenFiles] is true then hidden files (unix style) will be ignored
// return:
// [objectId]: objectId of the file/diectory
// [totalFiles]: total number of files
// [totalDirectories]: total number of directories
func Walk(dev *mtp.Device, storageId uint32, fullPath string, recursive, skipDisallowedFiles,
	skipHiddenFiles bool, cb WalkCb) (objectId uint32, totalFiles, totalDirectories int64, err error) {
	// fetch the objectId from [objectId] and/or [fullPath] parameters
	fi, err := GetObjectFromPath(dev, storageId, fullPath)
	if err != nil {
		return 0, totalFiles, totalDirectories, err
	}

	// if the object file name matches [disallowedFiles] list then return an error
	if skipDisallowedFiles {
		fName := (*fi).Name
		if ok := isDisallowedFiles(fName); ok {
			return 0, totalFiles, totalDirectories, InvalidPathError{error: fmt.Errorf("disallowed file %v", fName)}
		}
	}

	// if the object is a file then return objectId
	if !fi.IsDir {
		err := cb(fi.ObjectId, fi, nil)
		if err != nil {
			return 0, totalFiles, totalDirectories, err
		}

		totalFiles += 1

		return fi.ObjectId, 1, totalDirectories, nil
	}

	totalFiles, totalDirectories, err = proccessWalk(dev, storageId, FileProp{fi.ObjectId, fullPath}, recursive, skipDisallowedFiles, skipHiddenFiles, cb)
	if err != nil {
		return 0, totalFiles, totalDirectories, err
	}

	return fi.ObjectId, totalFiles, totalDirectories, nil
}

// check if a file Exists
// returns Exists: bool, isDir: bool, objectId: uint32
// Since the [parentPath] is unavailable here the [fullPath] property of the resulting object [FileInfo] may not be valid.
func FileExists(dev *mtp.Device, storageId uint32, fileProps []FileProp) (fc []FileExistsContainer, err error) {
	for _, fileProp := range fileProps {
		fi, err := GetObjectFromObjectIdOrPath(dev, storageId, fileProp)

		c := FileExistsContainer{}
		if err != nil {
			switch v := err.(type) {
			case InvalidPathError:
				c.Exists = false

			case FileObjectError:
				switch v1 := v.error.(type) {
				case mtp.RCError:
					if v1 == 0x2009 {
						c.Exists = false
					}
				}

			default:
				return []FileExistsContainer{}, nil
			}

		} else {
			c.Exists = true
			c.FileInfo = fi
		}

		fc = append(fc, c)
	}

	return fc, nil
}

// Delete a file/directory
// [objectId] and [fullPath] are optional parameters
// if [objectId] is not available then [fullPath] will be used to fetch the [objectId]
// dont leave both [objectId] and [fullPath] empty
// Tip: use [objectId] whenever possible to avoid traversing down the whole file tree to process and find the [objectId]
func DeleteFile(dev *mtp.Device, storageId uint32, fileProps []FileProp) error {
	for _, fileProp := range fileProps {
		fc, err := FileExists(dev, storageId, []FileProp{fileProp})
		if err != nil {
			return nil
		}

		if !fc[0].Exists {
			return nil
		}

		if err := dev.DeleteObject(fc[0].FileInfo.ObjectId); err != nil {
			return FileObjectError{error: err}
		}
	}

	return nil
}

// Rename a file/directory
// [objectId] and [fullPath] are optional parameters
// if [objectId] is not available then [fullPath] will be used to fetch the [objectId]
// dont leave both [objectId] and [fullPath] empty
// Tip: use [objectId] whenever possible to avoid traversing down the whole file tree to process and find the [objectId]
// return
// [objectId]: objectId of the file/diectory
func RenameFile(dev *mtp.Device, storageId uint32, fileProp FileProp, newFileName string) (objectId uint32, err error) {
	fc, err := FileExists(dev, storageId, []FileProp{fileProp})
	if err != nil {
		return 0, err
	}

	if !fc[0].Exists {
		return 0, InvalidPathError{error: fmt.Errorf("file not found: %s", fileProp.FullPath)}
	}

	fi := fc[0].FileInfo

	if err := dev.SetObjectPropValue(fi.ObjectId, mtp.OPC_ObjectFileName, &mtp.StringValue{Value: newFileName}); err != nil {
		switch v := err.(type) {
		case mtp.RCError:
			if v == 0x2002 {
				return fi.ObjectId, nil
			}
		}

		return 0, FileObjectError{error: err}
	}

	return fi.ObjectId, nil
}

// Transfer files from the local disk to the device
// sources: can be the list of files/directories that are to be sent to the device
// destination: fullPath to the destination directory
// preprocessFiles: if enabled, will fetch the total file size and count of the source. Use this will caution as it may take a few seconds to minutes to procress the files.
// return:
// [destinationObjectId]: objectId of [destination] directory
// [bulkFilesSent]: total transferred files (directory count not included)
// [bulkSizeSent]: total size of the uploaded files
func UploadFiles(dev *mtp.Device, storageId uint32, sources []string, destination string, preprocessFiles bool, preprocessCb LocalPreprocessCb, progressCb ProgressCb) (destinationObjectId uint32, bulkFilesSent int64, bulkSizeSent int64, err error) {
	_destination := fixSlash(destination)

	pInfo := ProgressInfo{
		FileInfo:          &FileInfo{},
		StartTime:         time.Now(),
		LatestSentTime:    time.Now(),
		Speed:             0,
		TotalFiles:        0,
		TotalDirectories:  0,
		FilesSent:         0,
		FilesSentProgress: 0,
		ActiveFileSize:    &TransferSizeInfo{},
		BulkFileSize:      &TransferSizeInfo{},
		Status:            InProgress,
	}

	// if [preprocessFiles] is true then fetch the total number of files from the file tree
	// total number of files in the current upload session
	// if [preprocessFiles] is false then [totalFiles] is 0
	var totalFiles int64 = 0

	// if [preprocessFiles] is true then fetch the total number of files from the file tree
	// total number of directories in the current upload session
	// if [preprocessFiles] is false then [totalDirectories] is 0
	var totalDirectories int64 = 0

	// if [preprocessFiles] is true then fetch the total number of files from the file tree
	// 	// total size of all the files combined in the current upload session
	// if [preprocessFiles] is false then [totalDirectories] is 0
	var totalSize int64 = 0

	// keep track of [bulkSizeSent]
	bulkSizeSent = 0

	if preprocessFiles {
		_totalFiles, _totalDirectories, _totalSize, err := walkLocalFiles(sources, func(fi *os.FileInfo, fullPath string, err error) error {
			if err != nil {
				return err
			}

			if (*fi).IsDir() {
				return nil
			}

			if err = preprocessCb(fi, fullPath, nil); err != nil {
				return err
			}

			return nil
		})

		if err != nil {
			return 0, bulkFilesSent, bulkSizeSent, err
		}

		totalFiles = _totalFiles
		totalDirectories = _totalDirectories
		totalSize = _totalSize
	}

	destParentId, err := MakeDirectory(dev, storageId, _destination)
	if err != nil {
		return 0, bulkFilesSent, bulkSizeSent, err
	}

	pInfo.TotalFiles = totalFiles
	pInfo.TotalDirectories = totalDirectories
	pInfo.BulkFileSize.Total = totalSize

	for _, source := range sources {
		_source := fixSlash(source)
		sourceParentPath := filepath.Dir(_source)

		destinationFilesDict := map[string]uint32{
			_destination: destParentId,
		}

		// walk through the source
		err = filepath.Walk(_source,
			func(path string, fInfo os.FileInfo, err error) error {
				if err != nil {
					return err
				}

				name := fInfo.Name()

				// don't follow symlinks
				if isSymlinkLocal(fInfo) {
					return nil
				}

				// filter out disallowed files
				if isDisallowedFiles(name) {
					return nil
				}

				sourceFilePath := fixSlash(path)

				// map the local files path to the mtp files path
				destinationParentPath, destinationFilePath := mapSourcePathToDestinationPath(
					sourceFilePath, sourceParentPath, _destination,
				)

				size := fInfo.Size()
				isDir := fInfo.IsDir()

				// if the object is a directory then create a directory using [MakeDirectory] or [MakeDirectory]
				if isDir {
					// if the parent path Exists within the [destinationFilesDict] then fetch the [parentId] (value) and make the destination directory
					if _, ok := destinationFilesDict[destinationParentPath]; ok {
						objId, err := MakeDirectory(dev, storageId, destinationFilePath)
						if err != nil {
							return err
						}

						// append the current objectId to [destinationFilesDict]
						destinationFilesDict[destinationFilePath] = objId

						// if the parent path DOES NOT Exists within the [destinationFilesDict] create a new directory using costlier [MakeDirectory] method
						// this is a fallback situation
					} else {
						objId, err := MakeDirectory(dev, storageId, _destination)
						if err != nil {
							return err
						}

						// append the current objectId to [destinationFilesDict]
						destinationFilesDict[destinationFilePath] = objId
					}

					return nil
				}

				/// if the object is a file then create a file
				var fileParentId uint32

				_parentId, ok := destinationFilesDict[destinationParentPath]
				if ok {
					// if [destinationParentPath] Exists within [destinationFilesDict] then use the value of the [destinationFilesDict] item as [parentId]
					fileParentId = _parentId

				} else {
					// if [destinationParentPath] DOES NOT Exists within [destinationFilesDict] then create the parent directory using [MakeDirectory] and use the resulting objId as [parentId]
					objId, err := MakeDirectory(dev, storageId, destinationParentPath)

					if err != nil {
						return err
					}

					// append the current objectId to [destinationFilesDict]
					destinationFilesDict[destinationFilePath] = objId

					fileParentId = objId
				}

				// read the local file
				fileBuf, err := os.Open(sourceFilePath)
				if err != nil {
					return InvalidPathError{error: err}
				}
				defer fileBuf.Close()

				var compressedSize uint32

				// assign compressedSize of the file
				if size > 0xFFFFFFFF {
					compressedSize = 0xFFFFFFFF
				} else {
					compressedSize = uint32(size)
				}

				fObj := mtp.ObjectInfo{
					StorageID:        storageId,
					ObjectFormat:     mtp.OFC_Undefined,
					ParentObject:     fileParentId,
					Filename:         name,
					CompressedSize:   compressedSize,
					ModificationDate: fInfo.ModTime(),
				}

				// keep track of [bulkFilesSent]
				bulkFilesSent += 1

				pInfo.FileInfo = &FileInfo{
					Info:       &fObj,
					Size:       size,
					IsDir:      isDir,
					ModTime:    fObj.ModificationDate,
					Name:       fObj.Filename,
					FullPath:   destinationFilePath,
					ParentPath: destinationParentPath,
					Extension:  extension(fObj.Filename, isDir),
					ParentId:   fObj.ParentObject,
				}
				pInfo.LatestSentTime = time.Now()

				// create file
				var prevSentSize int64 = 0
				objId, err := handleMakeFile(
					dev, storageId, &fObj, &fInfo, fileBuf,
					true,
					func(total, sent int64, objId uint32, err error) error {
						if err != nil {
							return err
						}

						pInfo.FileInfo.ObjectId = objId
						pInfo.ActiveFileSize.Total = total
						pInfo.ActiveFileSize.Sent = sent
						pInfo.ActiveFileSize.Progress = Percent(float32(sent), float32(total))

						chunkSize := sent - prevSentSize
						bulkSizeSent += chunkSize

						pInfo.BulkFileSize.Sent = bulkSizeSent
						pInfo.BulkFileSize.Progress = Percent(float32(bulkSizeSent), float32(totalSize))

						pInfo.Speed = transferRate(chunkSize, pInfo.LatestSentTime)
						if err = progressCb(&pInfo, nil); err != nil {
							return err
						}

						pInfo.LatestSentTime = time.Now()
						prevSentSize = sent

						return nil
					},
				)

				if err != nil {
					return err
				}

				pInfo.FilesSent = bulkFilesSent
				pInfo.FilesSentProgress = Percent(float32(bulkFilesSent), float32(totalFiles))

				pInfo.FileInfo.ObjectId = objId

				// append the current objectId to [destinationFilesDict]
				destinationFilesDict[destinationFilePath] = objId

				return nil
			},
		)

		if err != nil {
			switch err.(type) {
			case InvalidPathError:
				return destParentId, bulkFilesSent, bulkSizeSent, err

			case *os.PathError:
				if errors.Is(err, os.ErrPermission) {
					return destParentId, bulkFilesSent, bulkSizeSent, FilePermissionError{error: err}
				}

				if errors.Is(err, os.ErrNotExist) {
					return destParentId, bulkFilesSent, bulkSizeSent, InvalidPathError{error: err}
				}

				return destParentId, bulkFilesSent, bulkSizeSent, LocalFileError{error: err}
			default:
				return destParentId, bulkFilesSent, bulkSizeSent,
					FileTransferError{error: fmt.Errorf("an error occured while uploading files. %+v", err.Error())}
			}
		}
	}

	pInfo.Status = Completed
	if err := progressCb(&pInfo, nil); err != nil {
		return destParentId, bulkFilesSent, bulkSizeSent, err
	}

	return destParentId, bulkFilesSent, bulkSizeSent, nil
}

// Transfer files from the device to the local disk
// sources: can be the list of files/directories that are to be sent to the local disk
// destination: fullPath to the destination directory
// return:
// [totalFiles]: total transferred files (directory count not included)
// [totalSize]: total size of the uploaded files
func DownloadFiles(dev *mtp.Device, storageId uint32, sources []string, destination string,
	preprocessFiles bool, preprocessCb MtpPreprocessCb, progressCb ProgressCb) (bulkFilesSent int64, bulkSizeSent int64, err error) {
	_destination := fixSlash(destination)

	pInfo := ProgressInfo{
		FileInfo:          &FileInfo{},
		StartTime:         time.Now(),
		LatestSentTime:    time.Now(),
		Speed:             0,
		TotalFiles:        0,
		TotalDirectories:  0,
		FilesSent:         0,
		FilesSentProgress: 0,
		ActiveFileSize:    &TransferSizeInfo{},
		BulkFileSize:      &TransferSizeInfo{},
		Status:            InProgress,
	}

	// if [preprocessFiles] is true then fetch the total number of files from the file tree
	// total number of files in the current download session
	// if [preprocessFiles] is false then [totalFiles] is 0
	var totalFiles int64 = 0

	// if [preprocessFiles] is true then fetch the total number of files from the file tree
	// total number of directories in the current download session
	// if [preprocessFiles] is false then [totalDirectories] is 0
	var totalDirectories int64 = 0

	// if [preprocessFiles] is true then fetch the total number of files from the file tree
	// 	// total size of all the files combined in the current download session
	// if [preprocessFiles] is false then [totalDirectories] is 0
	var totalSize int64 = 0

	var cache = downloadFilesObjectCache{}
	if preprocessFiles {
		for _, source := range sources {
			_source := fixSlash(source)

			_, _totalFiles, _totalDirectories, err := Walk(dev, storageId, _source, true, true, false,
				func(objectId uint32, fi *FileInfo, err error) error {
					if err != nil {
						return err
					}

					sourceParentPath := filepath.Dir(_source)
					destinationFileParentPath, destinationFilePath := mapSourcePathToDestinationPath(
						fi.FullPath, sourceParentPath, _destination,
					)

					cache[destinationFilePath] = downloadFilesObjectCacheContainer{
						fileInfo:                  fi,
						sourceParentPath:          sourceParentPath,
						destinationFileParentPath: destinationFileParentPath,
						destinationFilePath:       destinationFilePath,
					}

					if fi.IsDir {
						return nil
					}

					// filter out disallowed files
					if isDisallowedFiles(fi.Name) {
						return nil
					}

					if err = preprocessCb(fi, nil); err != nil {
						return err
					}

					totalSize += fi.Size

					return nil
				})

			if err != nil {
				return bulkFilesSent, bulkSizeSent, err
			}

			totalFiles += _totalFiles
			totalDirectories += _totalDirectories
		}
	}

	pInfo.TotalFiles = totalFiles
	pInfo.TotalDirectories = totalDirectories
	pInfo.BulkFileSize.Total = totalSize

	dfProps := &processDownloadFilesProps{
		bulkFilesSent: bulkFilesSent,
		bulkSizeSent:  bulkSizeSent,
		totalFiles:    totalFiles,
		totalSize:     totalSize,
	}

	if len(cache) > 0 {
		for _, c := range cache {
			dfProps.sourceParentPath = c.sourceParentPath
			dfProps.destinationFileParentPath = c.destinationFileParentPath
			dfProps.destinationFilePath = c.destinationFilePath

			err := processDownloadFiles(dev, &pInfo, c.fileInfo, progressCb, dfProps)

			if err != nil {
				return processDownloadFilesError(dfProps, err)
			}
		}
	} else {
		for _, source := range sources {
			_source := fixSlash(source)

			_, err := GetObjectFromPath(dev, storageId, _source)
			if err != nil {
				return dfProps.bulkFilesSent, dfProps.bulkSizeSent, err
			}

			_, _, _, wErr := Walk(dev, storageId, _source, true, true, false,
				func(objectId uint32, fi *FileInfo, err error) error {
					if err != nil {
						return err
					}

					sourceParentPath := filepath.Dir(_source)
					destinationFileParentPath, destinationFilePath := mapSourcePathToDestinationPath(
						fi.FullPath, sourceParentPath, _destination,
					)
					dfProps.sourceParentPath = sourceParentPath
					dfProps.destinationFileParentPath = destinationFileParentPath
					dfProps.destinationFilePath = destinationFilePath

					return processDownloadFiles(dev, &pInfo, fi, progressCb, dfProps)
				})

			if wErr != nil {
				return processDownloadFilesError(dfProps, wErr)
			}
		}
	}

	pInfo.Status = Completed
	if err := progressCb(&pInfo, nil); err != nil {
		return dfProps.bulkFilesSent, dfProps.bulkSizeSent, err
	}

	return dfProps.bulkFilesSent, dfProps.bulkSizeSent, nil
}

func main() {}
