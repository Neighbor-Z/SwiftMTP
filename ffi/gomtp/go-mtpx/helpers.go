package mtpx

import (
	"errors"
	"fmt"
	"github.com/ganeshrvel/go-mtpfs/mtp"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// GetFileSize - fetch the file size of the object
func GetFileSize(dev *mtp.Device, obj *mtp.ObjectInfo, objectId uint32, isDir bool) (int64, error) {
	if isDir {
		return 0, nil
	}

	var size int64
	if obj.CompressedSize == 0xffffffff {
		var val mtp.Uint64Value
		if err := dev.GetObjectPropValue(objectId, mtp.OPC_ObjectSize, &val); err != nil {
			// Some devices report an unspecified CompressedSize and also reject
			// GetObjectPropValue. Keep the object visible with an unknown size
			// instead of failing the whole listing for it.
			return 0, nil
		}

		size = int64(val.Value)
	} else {
		size = int64(obj.CompressedSize)
	}

	return size, nil
}

// fetch an object using [objectId]
// [parentPath] is required to keep track of the [fullPath] of the object
func GetObjectFromObjectId(dev *mtp.Device, objectId uint32, parentPath string) (*FileInfo, error) {
	obj := mtp.ObjectInfo{}

	// if the [objectId] is root then return the basic root directory information
	if objectId == ParentObjectId {
		return &FileInfo{
			Size:     0,
			IsDir:    true,
			FullPath: "/",
			ObjectId: ParentObjectId,
			Info:     &mtp.ObjectInfo{},
		}, nil
	}

	if err := dev.GetObjectInfo(objectId, &obj); err != nil {
		return nil, FileObjectError{error: err}
	}

	isDir := isObjectADir(&obj)
	size, err := GetFileSize(dev, &obj, objectId, isDir)
	if err != nil {
		return nil, FileObjectError{error: err}
	}

	filename := obj.Filename
	_parentPath := fixSlash(parentPath)
	fullPath := getFullPath(_parentPath, filename)

	return &FileInfo{
		Info:       &obj,
		Size:       size,
		IsDir:      isDir,
		ModTime:    obj.ModificationDate,
		Name:       obj.Filename,
		FullPath:   fullPath,
		ParentPath: _parentPath,
		Extension:  extension(obj.Filename, isDir),
		ParentId:   obj.ParentObject,
		ObjectId:   objectId,
	}, nil
}

// fetch the object using [parentId] and [filename]
// it matches the [filename] to the list of files in the directory
// Since the [parentPath] is unavailable here the [fullPath] property of the resulting object [FileInfo] may not be valid.
func GetObjectFromParentIdAndFilename(dev *mtp.Device, storageId uint32, parentId uint32, filename string) (*FileInfo, error) {
	handles := mtp.Uint32Array{}
	if err := dev.GetObjectHandles(storageId, mtp.GOH_ALL_ASSOCS, parentId, &handles); err != nil {
		return nil, FileObjectError{error: err}
	}

	// Some devices (Android based media players) reject GetObjectPropValue for
	// every object with DevicePropNotSupported. Probe it once and fall back to
	// GetObjectInfo based name matching when the device refuses it.
	usePropValue := len(handles.Values) > 0

	for _, objectId := range handles.Values {
		propName := ""

		if usePropValue {
			var val mtp.StringValue
			if err := dev.GetObjectPropValue(objectId, mtp.OPC_ObjectFileName, &val); err != nil {
				usePropValue = false
			} else {
				propName = val.Value
			}
		}

		if usePropValue && !strings.EqualFold(propName, filename) {
			// this will avoid fetching the whole object properties and improve the performance a bit.
			continue
		}

		fi, err := GetObjectFromObjectId(dev, objectId, "")
		if err != nil {
			// a single unreadable handle must not abort the whole path resolution
			continue
		}

		// return the current objectId if the filename == fi.Name
		if strings.EqualFold(fi.Name, filename) {
			return fi, nil
		}
	}

	return nil, FileNotFoundError{error: fmt.Errorf("file not found: %s", filename)}
}

// fetch the object information using [fullPath]
// Since the [parentPath] is unavailable here the [fullPath] property of the resulting object [FileInfo] may not be valid.
func GetObjectFromPath(dev *mtp.Device, storageId uint32, fullPath string) (fInfo *FileInfo, err error) {
	if fullPath == "" {
		return nil, InvalidPathError{error: fmt.Errorf("path does not Exists. path: %s", fullPath)}
	}

	_filePath := fixSlash(fullPath)

	if _filePath == PathSep {
		return GetObjectFromObjectId(dev, ParentObjectId, "")
	}

	splittedFilePath := strings.Split(_filePath, PathSep)

	var objectId = uint32(ParentObjectId)
	var resultCount = 0
	var fi *FileInfo
	const skipIndex = 1

	for i, fName := range splittedFilePath[skipIndex:] {
		_fi, err := GetObjectFromParentIdAndFilename(dev, storageId, objectId, fName)

		if err != nil {
			switch err.(type) {
			case FileNotFoundError:
				return nil, InvalidPathError{
					error: fmt.Errorf("path not found: %s\nreason: %v", fullPath, err.Error()),
				}

			default:
				return nil, err
			}
		}

		if !_fi.IsDir && indexExists(splittedFilePath, i+1+skipIndex) {
			return nil, InvalidPathError{error: fmt.Errorf("path not found: %s", fullPath)}
		}

		// updating [fi] to current [_fi]
		fi = _fi

		// updating the [objectId] to follow the nested directory
		objectId = _fi.ObjectId

		// keeping a tab on total results
		resultCount += 1
	}

	if resultCount < 1 || fi == nil {
		return nil, InvalidPathError{error: fmt.Errorf("file not found: %s", fullPath)}
	}

	fi.FullPath = _filePath

	return fi, nil
}

// fetch an object using [objectId] and/or [fullPath]
// Since the [parentPath] is unavailable here the [fullPath] property of the resulting object [FileInfo] may not be valid.
func GetObjectFromObjectIdOrPath(dev *mtp.Device, storageId uint32, fileProp FileProp) (fInfo *FileInfo, err error) {
	objectId := fileProp.ObjectId
	fullPath := fileProp.FullPath

	if objectId == 0 && fullPath == "" {
		return nil, InvalidPathError{error: fmt.Errorf("invalid path: %s. both objectId and fullPath cannot be empty", fullPath)}
	}

	// if objectId is not available then fetch the objectId from fullPath
	if objectId == 0 {
		fp, err := GetObjectFromPath(dev, storageId, fullPath)

		if err != nil {
			return nil, err
		}

		return fp, nil
	}

	fo, err := GetObjectFromObjectId(dev, objectId, fullPath)
	if err != nil {
		return nil, err
	}

	return fo, nil
}

// check if the object is a directory
func isObjectADir(obj *mtp.ObjectInfo) bool {
	return obj.ObjectFormat == mtp.OFC_Association
}

// helper function to create a directory
func handleMakeDirectory(dev *mtp.Device, storageId, parentId uint32, filename string) (objectId uint32, err error) {
	send := mtp.ObjectInfo{
		StorageID:        storageId,
		ObjectFormat:     mtp.OFC_Association,
		ParentObject:     parentId,
		Filename:         filename,
		CompressedSize:   0,
		ModificationDate: time.Now(),
	}

	// create a new object handle
	_, _, objId, err := dev.SendObjectInfo(storageId, parentId, &send)
	if err != nil {
		return 0, SendObjectError{error: err}
	}

	return objId, nil
}

// helper function to create a device file
func handleMakeFile(dev *mtp.Device, storageId uint32, obj *mtp.ObjectInfo, fInfo *os.FileInfo, fileBuf *os.File, overwriteExisting bool, progressCb SizeProgressCb) (objectId uint32, err error) {
	fi, err := GetObjectFromParentIdAndFilename(dev, storageId, obj.ParentObject, obj.Filename)

	// file Exists
	if err == nil {
		// if [overwriteExisting] is false then just return existing [objectId] of the exisiting file
		if !overwriteExisting {
			return fi.ObjectId, nil
		}

		fileProp := FileProp{fi.ObjectId, ""}
		// if [overwriteExisting] is true then delete the existing file
		if err := DeleteFile(dev, storageId, []FileProp{fileProp}); err != nil {
			return 0, err
		}
	} else {
		switch err.(type) {
		// if the file does not Exists then do nothing
		case FileNotFoundError:

		default:
			return 0, err
		}
	}

	// create a new object handle
	_, _, objId, err := dev.SendObjectInfo(storageId, obj.ParentObject, obj)
	if err != nil {
		return objId, SendObjectError{error: err}
	}

	size := (*fInfo).Size()
	// send the bytes data to the newly create object handle
	err = dev.SendObject(fileBuf, size, func(sent int64) error {
		if err := progressCb(size, sent, objId, nil); err != nil {
			return err
		}

		return nil
	})
	if err != nil {
		return objId, SendObjectError{error: err}
	}

	return objId, nil
}

// helper function to create a local file
func handleMakeLocalFile(dev *mtp.Device, fi *FileInfo, destination string, progressCb SizeProgressCb) error {
	f, err := os.Create(destination)
	if err != nil {
		return err
	}
	defer f.Close()

	var totalSent int64 = 0
	err = dev.GetObject(fi.ObjectId, f, func(sent int64) error {
		if err := progressCb(fi.Size, sent, fi.ObjectId, err); err != nil {
			return err
		}

		totalSent = sent

		return nil
	})
	if err != nil {
		return err
	}

	// fix the incorrect sent size
	if totalSent < fi.Size {
		if err := progressCb(fi.Size, fi.Size, fi.ObjectId, err); err != nil {
			return err
		}
	}

	return restoreLocalFileTimestamp(destination, fi.ModTime)
}

// helper function to fetch the contents inside a directory
// use [recursive] to fetch the whole nested tree
// [objectId] and [fullPath] are optional parameters
// if [objectId] is not available then [fullPath] will be used to fetch the [objectId]
// dont leave both [objectId] and [fullPath] empty
// Tips: use [objectId] whenever possible to avoid traversing down the whole file tree to process and find the [objectId]
// if [skipDisallowedFiles] is true then files matching the [disallowedFiles] list will be ignored
// if [skipHiddenFiles] is true then hidden files (unix style) will be ignored
// return:
// [totalFiles]: total number of files
// [totalDirectories]: total number of directories
func proccessWalk(dev *mtp.Device, storageId uint32, fileProp FileProp, recursive, skipDisallowedFiles, skipHiddenFiles bool, cb WalkCb) (totalFiles, totalDirectories int64, err error) {
	fi, err := GetObjectFromObjectIdOrPath(dev, storageId, FileProp{fileProp.ObjectId, fileProp.FullPath})

	if err != nil {
		return totalFiles, totalDirectories, err
	}

	handles := mtp.Uint32Array{}
	if err := dev.GetObjectHandles(storageId, mtp.GOH_ALL_ASSOCS, fi.ObjectId, &handles); err != nil {
		return totalFiles, totalDirectories, ListDirectoryError{error: err}
	}

	totalFiles = 0

	for _, objId := range handles.Values {
		fi, err := GetObjectFromObjectId(dev, objId, fileProp.FullPath)
		if err != nil {
			continue
		}

		fName := (*fi).Name

		// skip the object if it's a hidden file
		if skipHiddenFiles && isHiddenFile(fName) {
			continue
		}

		// if the object file name matches [disallowedFiles] list then ignore it
		if skipDisallowedFiles && isDisallowedFiles(fName) {
			continue
		}

		if fi.IsDir {
			totalDirectories += 1
		} else {
			totalFiles += 1
		}

		err = cb(objId, fi, nil)
		if err != nil {
			return totalFiles, totalDirectories, err
		}

		// don't traverse down the tree if [recursive] is false
		if !recursive {
			continue
		}

		// don't traverse down the tree if the object is not a directory
		if !fi.IsDir {
			continue
		}

		_totalFiles, _totalDirectories, err := proccessWalk(
			dev, storageId, FileProp{objId, fi.FullPath}, recursive, skipDisallowedFiles, skipHiddenFiles, cb,
		)
		if err != nil {
			return totalFiles, totalDirectories, err
		}

		totalFiles += _totalFiles
		totalDirectories += _totalDirectories
	}

	return totalFiles, totalDirectories, nil
}

// create a local directory
func makeLocalDirectory(filename string, modTime time.Time) error {
	err := os.MkdirAll(filename, os.FileMode(newLocalDirectoryMode))
	if err != nil {
		switch err.(type) {
		case *os.PathError:
			if errors.Is(err, os.ErrPermission) {
				return FilePermissionError{error: err}
			}

			return LocalFileError{error: err}

		default:
			return err
		}
	}

	return restoreLocalFileTimestamp(filename, modTime)
}

// walks through the local files
func walkLocalFiles(sources []string, cb LocalWalkCb) (totalFiles, totalDirectories, totalSize int64, err error) {
	totalFiles = 0
	totalDirectories = 0
	totalSize = 0

	for _, source := range sources {
		// walk through the source
		err := filepath.Walk(source,
			func(fullPath string, fInfo os.FileInfo, err error) error {
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

				if err := cb(&fInfo, fullPath, nil); err != nil {
					return err
				}

				if !fInfo.IsDir() {
					totalFiles += 1
					totalSize += fInfo.Size()
				} else {
					totalDirectories += 1
				}

				return nil
			})

		if err != nil {
			switch err.(type) {
			case *os.PathError:
				if errors.Is(err, os.ErrPermission) {
					return totalFiles, totalDirectories, totalSize, FilePermissionError{error: err}
				}

				return totalFiles, totalDirectories, totalSize, LocalFileError{error: err}

			default:
				return totalFiles, totalDirectories, totalSize, err
			}
		}
	}

	return totalFiles, totalDirectories, totalSize, nil
}

func processDownloadFiles(dev *mtp.Device, pInfo *ProgressInfo, fi *FileInfo, progressCb ProgressCb, dfProps *processDownloadFilesProps) (err error) {

	// filter out disallowed files
	if isDisallowedFiles(fi.Name) {
		return nil
	}

	// if the object is a directory then create a local directory
	if fi.IsDir {
		// since the object is a directory we pass down it's modification time
		err := makeLocalDirectory(dfProps.destinationFilePath, fi.ModTime)
		if err != nil {
			return err
		}

		return nil
	}

	/// if the object is a file then create one
	// if the local parent directory does not Exists then create one
	if !fileExistsLocal(dfProps.destinationFileParentPath) {
		// since the object is a file and we are creating the parent directory without it's original meta information
		// we are just passing down the current time as modification time
		err := makeLocalDirectory(dfProps.destinationFileParentPath, time.Now())
		if err != nil {
			return err
		}
	}

	// keep track of [bulkFilesSent]
	dfProps.bulkFilesSent += 1

	pInfo.LatestSentTime = time.Now()
	pInfo.FileInfo = fi

	// create the local file
	var prevSentSize int64 = 0
	err = handleMakeLocalFile(dev, fi, dfProps.destinationFilePath,
		func(total, sent int64, _ uint32, err error) error {
			if err != nil {
				return err
			}

			pInfo.ActiveFileSize.Total = total
			pInfo.ActiveFileSize.Sent = sent
			pInfo.ActiveFileSize.Progress = Percent(float32(sent), float32(total))

			chunkSize := sent - prevSentSize
			dfProps.bulkSizeSent += chunkSize

			pInfo.BulkFileSize.Sent = dfProps.bulkSizeSent
			pInfo.BulkFileSize.Progress = Percent(float32(dfProps.bulkSizeSent), float32(dfProps.totalSize))

			pInfo.Speed = transferRate(chunkSize, pInfo.LatestSentTime)
			if err = progressCb(pInfo, nil); err != nil {
				return err
			}

			pInfo.LatestSentTime = time.Now()
			prevSentSize = sent

			return nil
		})
	if err != nil {
		return err
	}

	pInfo.FilesSent = dfProps.bulkFilesSent
	pInfo.FilesSentProgress = Percent(float32(dfProps.bulkFilesSent), float32(dfProps.totalFiles))

	return nil
}

func processDownloadFilesError(dfProps *processDownloadFilesProps, err error) (bulkFilesSent, bulkSizeSent int64, error error) {
	if err != nil {
		switch err.(type) {
		case InvalidPathError:
			return dfProps.bulkFilesSent, dfProps.bulkSizeSent, err

		case *os.PathError:
			if errors.Is(err, os.ErrPermission) {
				return dfProps.bulkFilesSent, dfProps.bulkSizeSent, FilePermissionError{error: err}
			}

			if errors.Is(err, os.ErrNotExist) {
				return dfProps.bulkFilesSent, dfProps.bulkSizeSent, InvalidPathError{error: err}
			}

			return dfProps.bulkFilesSent, dfProps.bulkSizeSent, LocalFileError{error: err}
		default:
			return dfProps.bulkFilesSent, dfProps.bulkSizeSent,
				FileTransferError{error: fmt.Errorf("an error occured while downloading the files. %+v", err.Error())}
		}
	}

	return bulkFilesSent, bulkSizeSent, err
}

//Restore modified timestamp of the file
func restoreLocalFileTimestamp(destination string, modTime time.Time) (err error) {
	currentTime := time.Now().Local()

	err = os.Chtimes(destination, currentTime, modTime.Local())
	if err != nil {
		return err
	}

	return err
}
