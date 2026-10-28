# go-mtpx

A Go library for MTP (Media Transfer Protocol) operations, providing a high-level API for file transfer with Android devices and other MTP-compatible devices.

## Features

- **Multi-device support**: Connect to and manage multiple MTP devices simultaneously
- **File operations**: Upload, download, delete, and rename files
- **Directory operations**: Create directories, walk directory trees
- **Progress tracking**: Real-time progress callbacks for file transfers
- **Error handling**: Comprehensive error types for different failure scenarios

## Multi-Device Support

go-mtpx supports connecting to multiple MTP devices simultaneously. You can list all connected devices, connect to a specific device by its unique ID, and perform operations on different devices independently.

### Listing Connected Devices

```go
devices, err := mtpx.ListDevices()
if err != nil {
    log.Fatal(err)
}

for _, device := range devices {
    fmt.Printf("Device: %s %s\n", device.Manufacturer, device.Model)
    fmt.Printf("  Vendor: 0x%04x, Product: 0x%04x\n", device.VendorId, device.ProductId)
    fmt.Printf("  Serial: %s\n", device.SerialNumber)
}
}
```

### Connecting to a Specific Device

```go
// List available devices
devices, err := mtpx.ListDevices()
if err != nil {
    log.Fatal(err)
}

if len(devices) == 0 {
    log.Fatal("No MTP devices found")
}

// Connect to a specific device by vendor ID, product ID, and serial number
dev, err := mtpx.InitializeByDeviceId(
    devices[0].VendorId,
    devices[0].ProductId,
    devices[0].SerialNumber, // Pass empty string "" to match any device with same vendor/product
    mtpx.Init{DebugMode: false},
)
if err != nil {
    log.Fatal(err)
}
defer mtpx.Dispose(dev)

// Perform operations...
info, _ := mtpx.FetchDeviceInfo(dev)
fmt.Printf("Connected to: %s\n", info.Model)
```

### Getting Device Identifiers

After connecting to a device, you can retrieve its identifiers for later reconnection:

```go
vendorId, productId, serialNumber, err := mtpx.GetDeviceIdentifiers(dev)
if err != nil {
    log.Fatal(err)
}
fmt.Printf("Device: Vendor=0x%04x, Product=0x%04x, Serial=%s\n", vendorId, productId, serialNumber)
```

## Basic Usage

### Single Device (Legacy API)

For simple use cases with a single device, you can use the original `Initialize` function:

```go
dev, err := mtpx.Initialize(mtpx.Init{DebugMode: false})
if err != nil {
    log.Fatal(err)
}
defer mtpx.Dispose(dev)
```

### File Operations

```go
// Get storages
storages, err := mtpx.FetchStorages(dev)
storageId := storages[0].Sid

// Walk directory
mtpx.Walk(dev, storageId, "/DCIM", true, true, false, func(objectId uint32, fi *mtpx.FileInfo, err error) error {
    fmt.Printf("%s - %d bytes\n", fi.FullPath, fi.Size)
    return nil
})

// Upload files
mtpx.UploadFiles(dev, storageId, []string{"/local/path/file.jpg"}, "/DCIM/Camera", true,
    func(fi *mtpx.ProgressInfo, err error) error {
        fmt.Printf("Progress: %.2f%%\n", fi.BulkFileSize.Progress)
        return nil
    })

// Download files
mtpx.DownloadFiles(dev, storageId, []string{"/DCIM/Camera/photo.jpg"}, "/local/destination", true,
    func(fi *mtpx.ProgressInfo, err error) error {
        fmt.Printf("Progress: %.2f%%\n", fi.BulkFileSize.Progress)
        return nil
    })
```

## macOS setup

```shell script
xcode-select --install
```

### Before running the tests:

- Open `tests/README.md`
- Follow the instructions to copy the `mtp-test-files` to phone

### Install and setup libusb

```shell
brew install pkg-config
brew install libusb
```

### Test go-mtpx

- Connect android device via usb and Choose File transfer

```shell script
go test
```

##### Upgrade a package

```shell
# example:
go get github.com/ganeshrvel/go-mtpfs@<git-commit-hash>
```
