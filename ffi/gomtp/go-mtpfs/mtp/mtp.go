package mtp

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"io"
	"log"
	"os"
	"strings"
	"time"

	"github.com/ganeshrvel/usb"
)

// An MTP device.
type Device struct {
	h   *usb.DeviceHandle
	dev *usb.Device

	claimed bool

	// split off descriptor?
	devDescr    usb.DeviceDescriptor
	ifaceDescr  usb.InterfaceDescriptor
	sendEP      byte
	fetchEP     byte
	eventEP     byte
	configValue byte

	// In milliseconds. Defaults to 2 seconds.
	Timeout int

	// Print request/response codes.
	MTPDebug bool

	// Print USB calls.
	USBDebug bool

	// Print data as it passes over the USB connection.
	DataDebug bool

	// If set, send header in separate write.
	SeparateHeader bool

	session *sessionData
}

type UsbDeviceInfo struct {
	// USB-IF vendor ID.
	IdVendor uint16
	// USB-IF product ID.
	IdProduct uint16
	// Device release number in binary-coded decimal.
	Device uint16

	// Index of string descriptor describing manufacturer.
	Manufacturer string
	// Index of string descriptor describing product.
	Product string
	// Index of string descriptor containing device serial number.
	SerialNumber string
}

type sessionData struct {
	tid uint32
	sid uint32
}

// RCError are return codes from the Container.Code field.
type RCError uint16

func (e RCError) Error() string {
	n, ok := RC_names[int(e)]
	if ok {
		return n
	}
	return fmt.Sprintf("RetCode %x", uint16(e))
}

func (d *Device) fetchMaxPacketSize() int {
	return d.dev.GetMaxPacketSize(d.fetchEP)
}

func (d *Device) sendMaxPacketSize() int {
	return d.dev.GetMaxPacketSize(d.sendEP)
}

// empty placeholder function for progress callback
func EmptyProgressFunc(_ int64) error {
	return nil
}

// Close releases the interface, and closes the device.
func (d *Device) Close() error {
	if d.h == nil {
		return nil // or error?
	}

	if d.session != nil {
		var req, rep Container
		req.Code = OC_CloseSession
		// RunTransaction runs close, so can't use CloseSession().

		if err := d.runTransaction(&req, &rep, nil, nil, 0, EmptyProgressFunc); err != nil {
			err := d.h.Reset()
			if d.USBDebug {
				log.Printf("USB: Reset, err: %v", err)
			}
		}
	}

	if d.claimed {
		err := d.h.ReleaseInterface(d.ifaceDescr.InterfaceNumber)
		if d.USBDebug {
			log.Printf("USB: ReleaseInterface 0x%x, err: %v", d.ifaceDescr.InterfaceNumber, err)
		}
	}
	err := d.h.Close()
	d.h = nil

	if d.USBDebug {
		log.Printf("USB: Close, err: %v", err)
	}
	return err
}

// Done releases the libusb device reference.
func (d *Device) Done() {
	d.dev.Unref()
	d.dev = nil
}

// Claims the USB interface of the device.
func (d *Device) claim() error {
	if d.h == nil {
		return fmt.Errorf("mtp: claim: device not open")
	}

	err := d.h.ClaimInterface(d.ifaceDescr.InterfaceNumber)
	if d.USBDebug {
		log.Printf("USB: ClaimInterface 0x%x, err: %v", d.ifaceDescr.InterfaceNumber, err)
	}
	if err == nil {
		d.claimed = true
	}

	return err
}

// Open opens an MTP device.
func (d *Device) Open() error {
	if d.Timeout == 0 {
		d.Timeout = 2000
	}

	if d.h != nil {
		return fmt.Errorf("already open")
	}

	var err error
	d.h, err = d.dev.Open()
	if d.USBDebug {
		log.Printf("USB: Open, err: %v", err)
	}
	if err != nil {
		return err
	}

	d.claim()

	if d.ifaceDescr.InterfaceStringIndex == 0 {
		// Some devices have no interface field, so we'll hardcode ones
		// that we know about. If this list gets too unwieldy, we may
		// need to look into a more generic solution.
		info := DeviceInfo{}
		d.GetDeviceInfo(&info)

		if !strings.Contains(info.MTPExtension, "microsoft/WindowsPhone") &&
			!strings.Contains(info.MTPExtension, "fujifilm.co.jp") {
			d.Close()
			return fmt.Errorf("mtp: no MTP extensions in %s", info.MTPExtension)
		}
	} else {
		iface, err := d.h.GetStringDescriptorASCII(d.ifaceDescr.InterfaceStringIndex)
		if err != nil {
			d.Close()
			return err
		}

		if d.USBDebug {
			log.Printf("USB: interface: %s", iface)
		}

		// support for older samsung phones
		if !strings.Contains(iface, "MTP") && !strings.Contains(iface, "CDC") && !strings.Contains(iface, "ACM") {
			d.Close()
			return fmt.Errorf("has no MTP in interface string")
		}
	}

	return nil
}

// ID is the manufacturer + product + serial
func (d *Device) ID() (string, error) {
	if d.h == nil {
		return "", fmt.Errorf("mtp: ID: device not open")
	}

	var ids []string
	for _, b := range []byte{
		d.devDescr.Manufacturer,
		d.devDescr.Product,
		d.devDescr.SerialNumber} {
		var descriptor string
		if b == 0 {
			// All three of the descriptors are optional.
			// Index of 0 means the string is not available.
			descriptor = ""
		} else {
			s, err := d.h.GetStringDescriptorASCII(b)
			if err != nil {
				if d.USBDebug {
					log.Printf("USB: GetStringDescriptorASCII, err: %v", err)
				}
				return "", err
			}
			descriptor = s
		}

		ids = append(ids, descriptor)
	}

	return strings.Join(ids, " "), nil
}

func (d *Device) GetUsbInfo() (*UsbDeviceInfo, error) {
	if d.h == nil {
		return nil, fmt.Errorf("mtp: ID: device not open")
	}

	ui := UsbDeviceInfo{
		IdVendor:  d.devDescr.IdVendor,
		IdProduct: d.devDescr.IdProduct,
		Device:    d.devDescr.Device,
	}

	if d.devDescr.Manufacturer != 0 {
		manufacturer, err := d.h.GetStringDescriptorASCII(d.devDescr.Manufacturer)
		if err != nil {
			if d.USBDebug {
				log.Printf("USB: GetStringDescriptorASCII, err: %v", err)
			}
			return nil, err
		}
		ui.Manufacturer = manufacturer
	} else {
		ui.Manufacturer = ""
	}

	if d.devDescr.SerialNumber != 0 {
		serialNumber, err := d.h.GetStringDescriptorASCII(d.devDescr.SerialNumber)
		if err != nil {
			if d.USBDebug {
				log.Printf("USB: GetStringDescriptorASCII, err: %v", err)
			}
			return nil, err
		}
		ui.SerialNumber = serialNumber
	} else {
		ui.SerialNumber = ""
	}

	if d.devDescr.Product != 0 {
		product, err := d.h.GetStringDescriptorASCII(d.devDescr.Product)
		if err != nil {
			if d.USBDebug {
				log.Printf("USB: GetStringDescriptorASCII, err: %v", err)
			}
			return nil, err
		}
		ui.Product = product
	} else {
		ui.Product = ""
	}

	return &ui, nil
}

func (d *Device) sendReq(req *Container) error {
	c := usbBulkContainer{
		usbBulkHeader: usbBulkHeader{
			Length:        uint32(usbHdrLen + 4*len(req.Param)),
			Type:          USB_CONTAINER_COMMAND,
			Code:          req.Code,
			TransactionID: req.TransactionID,
		},
	}
	for i := range req.Param {
		c.Param[i] = req.Param[i]
	}

	var wData [usbBulkLen]byte
	buf := bytes.NewBuffer(wData[:0])

	binary.Write(buf, binary.LittleEndian, c.usbBulkHeader)
	if err := binary.Write(buf, binary.LittleEndian, c.Param[:len(req.Param)]); err != nil {
		return err
	}

	d.dataPrint(d.sendEP, buf.Bytes())
	_, err := d.h.BulkTransfer(d.sendEP, buf.Bytes(), d.Timeout)
	if err != nil {
		return err
	}
	return nil
}

// Fetches one USB packet. The header is split off, and the remainder is returned.
// dest should be at least 512bytes.
func (d *Device) fetchPacket(dest []byte, header *usbBulkHeader) (rest []byte, bytesRead int, err error) {
	n, err := d.h.BulkTransfer(d.fetchEP, dest[:d.fetchMaxPacketSize()], d.Timeout)
	if n > 0 {
		d.dataPrint(d.fetchEP, dest[:n])
	}

	if err != nil {
		return nil, n, err
	}

	buf := bytes.NewBuffer(dest[:n])
	if err = binary.Read(buf, binary.LittleEndian, header); err != nil {
		return nil, n, err
	}
	return buf.Bytes(), n, nil
}

func (d *Device) decodeRep(h *usbBulkHeader, rest []byte, rep *Container) error {
	if h.Type != USB_CONTAINER_RESPONSE {
		return SyncError(fmt.Sprintf("got type %d (%s) in response, want CONTAINER_RESPONSE.", h.Type, USB_names[int(h.Type)]))
	}

	rep.Code = h.Code
	rep.TransactionID = h.TransactionID

	restLen := int(h.Length) - usbHdrLen
	if restLen > len(rest) {
		return fmt.Errorf("header specified 0x%x bytes, but have 0x%x",
			restLen, len(rest))
	}
	nParam := restLen / 4
	for i := 0; i < nParam; i++ {
		rep.Param = append(rep.Param, byteOrder.Uint32(rest[4*i:]))
	}

	if rep.Code != RC_OK {
		return RCError(rep.Code)
	}
	return nil
}

// SyncError is an error type that indicates lost transaction
// synchronization in the protocol.
type SyncError string

func (s SyncError) Error() string {
	return string(s)
}

// Runs a single MTP transaction. dest and src cannot be specified at
// the same time.  The request should fill out Code and Param as
// necessary. The response is provided here, but usually only the
// return code is of interest.  If the return code is an error, this
// function will return an RCError instance.
//
// Errors that are likely to affect future transactions lead to
// closing the connection. Such errors include: invalid transaction
// IDs, USB errors (BUSY, IO, ACCESS etc.), and receiving data for
// operations that expect no data.
func (d *Device) RunTransaction(req *Container, rep *Container,
	dest io.Writer, src io.Reader, writeSize int64, progressCb ProgressFunc) error {
	if d.h == nil {
		return fmt.Errorf("mtp: cannot run operation %v, device is not open",
			OC_names[int(req.Code)])
	}
	if err := d.runTransaction(req, rep, dest, src, writeSize, progressCb); err != nil {
		_, ok2 := err.(SyncError)
		_, ok1 := err.(usb.Error)
		if ok1 || ok2 {
			log.Printf("fatal error %v; closing connection.", err)
			d.Close()
		}
		return err
	}
	return nil
}

// runTransaction is like RunTransaction, but without sanity checking
// before and after the call.
func (d *Device) runTransaction(req *Container, rep *Container,
	dest io.Writer, src io.Reader, writeSize int64, progressCb ProgressFunc) error {
	var finalPacket []byte
	if d.session != nil {
		req.SessionID = d.session.sid
		req.TransactionID = d.session.tid
		d.session.tid++
	}

	if d.MTPDebug {
		log.Printf("MTP request %s %v\n", OC_names[int(req.Code)], req.Param)
	}

	if err := d.sendReq(req); err != nil {
		if d.MTPDebug {
			log.Printf("MTP sendreq failed: %v\n", err)
		}
		return err
	}

	if src != nil {
		hdr := usbBulkHeader{
			Type:          USB_CONTAINER_DATA,
			Code:          req.Code,
			Length:        uint32(writeSize),
			TransactionID: req.TransactionID,
		}

		_, err := d.bulkWrite(&hdr, src, writeSize, req, progressCb)
		if err != nil {
			return err
		}
	}
	fetchPacketSize := d.fetchMaxPacketSize()
	data := make([]byte, fetchPacketSize)
	h := &usbBulkHeader{}
	rest, n, err := d.fetchPacket(data[:], h)
	if err != nil {
		return err
	}
	var unexpectedData bool
	if h.Type == USB_CONTAINER_DATA {
		if dest == nil {
			dest = &NullWriter{}
			unexpectedData = true
			if d.MTPDebug {
				log.Printf("MTP discarding unexpected data 0x%x bytes", h.Length)
			}
		}
		if d.MTPDebug {
			log.Printf("MTP data 0x%x bytes", h.Length)
		}

		dest.Write(rest)

		if len(rest)+usbHdrLen == fetchPacketSize || uint32(n) < h.Length {
			// Special case: From appendix H in the MTP 1.1 spec, the
			// device can send a 12-byte packet followed by the rest of the
			// data in a separate packet. After that point, both parties must
			// follow the same rule.
			// To detect this, if this is the first packet of a larger container
			// data packet AND it's 12 bytes, set SeparateHeader to TRUE so we
			// correctly send data back to the receiver.
			if n == usbHdrLen && len(rest) == 0 && uint32(n) < h.Length {
				d.SeparateHeader = true
				if d.MTPDebug {
					log.Printf("Device appears to have split header/data. Switched to separate header mode.")
				}
			}

			// If this was a full packet, or if the packet wasn't full but
			// the device said it was sending more data than we received,
			// continue reading until we have a read less than a full packet.
			_, finalPacket, err = d.bulkRead(dest, progressCb)
			if err != nil {
				return err
			}
		}

		h = &usbBulkHeader{}
		if len(finalPacket) > 0 {
			if d.MTPDebug {
				log.Printf("Reusing final packet")
			}
			rest = finalPacket
			finalBuf := bytes.NewBuffer(finalPacket[:len(finalPacket)])
			err = binary.Read(finalBuf, binary.LittleEndian, h)
		} else {
			rest, _, err = d.fetchPacket(data[:], h)
		}
	}

	err = d.decodeRep(h, rest, rep)
	if d.MTPDebug {
		log.Printf("MTP response %s %v", getName(RC_names, int(rep.Code)), rep.Param)
	}
	if unexpectedData {
		return SyncError(fmt.Sprintf("unexpected data for code %s", getName(RC_names, int(req.Code))))
	}

	if err != nil {
		return err
	}
	if d.session != nil && rep.TransactionID != req.TransactionID {
		return SyncError(fmt.Sprintf("transaction ID mismatch got %x want %x",
			rep.TransactionID, req.TransactionID))
	}
	rep.SessionID = req.SessionID
	return nil
}

// Prints data going over the USB connection.
func (d *Device) dataPrint(ep byte, data []byte) {
	if !d.DataDebug {
		return
	}
	dir := "send"
	if 0 != ep&usb.ENDPOINT_IN {
		dir = "recv"
	}
	fmt.Fprintf(os.Stderr, "%s: 0x%x bytes with ep 0x%x:\n", dir, len(data), ep)
	hexDump(data)
}

// The linux usb stack can send 16kb per call, according to libusb.
const rwBufSize = 0x4000

// bulkWrite returns the number of non-header bytes written.
func (d *Device) bulkWrite(hdr *usbBulkHeader, r io.Reader, size int64, req *Container, progressCb ProgressFunc) (n int64, err error) {
	totalSize := size
	packetSize := d.sendMaxPacketSize()
	if hdr != nil {
		if size+usbHdrLen > 0xFFFFFFFF {
			hdr.Length = 0xFFFFFFFF
		} else {
			hdr.Length = uint32(size + usbHdrLen)
		}

		packetArr := make([]byte, packetSize)
		var packet []byte
		if d.SeparateHeader {
			packet = packetArr[:usbHdrLen]
		} else {
			packet = packetArr[:]
		}

		buf := bytes.NewBuffer(packet[:0])
		binary.Write(buf, byteOrder, hdr)
		cpSize := int64(len(packet) - usbHdrLen)
		if cpSize > size {
			cpSize = size
		}

		_, err = io.CopyN(buf, r, cpSize)
		d.dataPrint(d.sendEP, buf.Bytes())
		_, err = d.h.BulkTransfer(d.sendEP, buf.Bytes(), d.Timeout)
		if err != nil {
			return cpSize, err
		}
		size -= cpSize
		n += cpSize

		if err = progressCb(totalSize - size); err != nil {
			return cpSize, err
		}
	}

	var buf [rwBufSize]byte
	var lastTransfer int

	for size > 0 {
		var m int
		toread := buf[:]
		if int64(len(toread)) > size {
			toread = buf[:int(size)]
		}

		m, err = r.Read(toread)
		if err != nil {
			break
		}
		size -= int64(m)

		d.dataPrint(d.sendEP, buf[:m])
		lastTransfer, err = d.h.BulkTransfer(d.sendEP, buf[:m], d.Timeout)
		n += int64(lastTransfer)

		if err != nil || lastTransfer == 0 {
			break
		}

		if err = progressCb(totalSize - size); err != nil {
			return size, err
		}
	}

	if lastTransfer%packetSize == 0 {
		// write a short packet just to be sure.
		d.h.BulkTransfer(d.sendEP, buf[:0], 250)
	}

	return n, err
}

func (d *Device) bulkRead(w io.Writer, progressCb ProgressFunc) (n int64, lastPacket []byte, err error) {
	var buf [rwBufSize]byte
	var lastRead int

	for {
		toread := buf[:]
		lastRead, err = d.h.BulkTransfer(d.fetchEP, toread, d.Timeout)
		if err != nil {
			break
		}

		if lastRead > 0 {
			d.dataPrint(d.fetchEP, buf[:lastRead])

			w, err := w.Write(buf[:lastRead])
			n += int64(w)
			if err != nil {
				break
			}
		}

		if err = progressCb(n); err != nil {
			break
		}

		if d.MTPDebug {
			log.Printf("MTP bulk read 0x%x bytes.", lastRead)
		}
		if lastRead < len(toread) {
			// short read.
			break
		}
	}
	packetSize := d.fetchMaxPacketSize()
	if lastRead%packetSize == 0 {
		// This should be a null packet, but on Linux + XHCI it's actually
		// CONTAINER_OK instead. To be liberal with the XHCI behavior, return
		// the final packet and inspect it in the calling function.
		var nullReadSize int
		nullReadSize, err = d.h.BulkTransfer(d.fetchEP, buf[:], d.Timeout)
		if d.MTPDebug {
			log.Printf("Expected null packet, read %d bytes", nullReadSize)
		}

		if err = progressCb(n); err != nil {
			return n, buf[:nullReadSize], err
		}

		return n, buf[:nullReadSize], err
	}

	return n, buf[:0], err
}

// Configure is a robust version of OpenSession. On failure, it resets
// the device and reopens the device and the session.
func (d *Device) Configure() error {
	if d.h == nil {
		if err := d.Open(); err != nil {
			return err
		}
	}

	err := d.OpenSession()
	if err == RCError(RC_SessionAlreadyOpened) {
		// It's open, so close the session. Fortunately, this
		// even works without a transaction ID, at least on Android.
		d.CloseSession()
		err = d.OpenSession()
	}

	if err != nil {
		log.Printf("OpenSession failed: %v; attempting reset", err)
		if d.h != nil {
			d.h.Reset()
		}
		d.Close()

		// Give the device some rest.
		time.Sleep(1000 * time.Millisecond)
		if err := d.Open(); err != nil {
			return fmt.Errorf("opening after reset: %v", err)
		}
		if err := d.OpenSession(); err != nil {
			occupyingInfo := getUSBOccupyingPIDs()
			return fmt.Errorf("OpenSession after reset: %v%s", err, occupyingInfo)
		}
	}
	return nil
}
