//go:build !darwin

package mtp

// getUSBOccupyingPIDs is a no-op on non-macOS platforms.
func getUSBOccupyingPIDs() string {
	return ""
}
